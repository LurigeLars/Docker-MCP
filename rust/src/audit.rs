//! `mcp_deployment_audit` and `image_usage_audit`, mirroring server.py
//! (`_audit_inventory`, `_deployment_audit`, `_image_usage_audit`). The pure
//! functions take the inventory as data so golden tests need no Docker.

use std::{
    collections::{BTreeMap, HashMap, HashSet},
    sync::LazyLock,
    time::{Duration, SystemTime, UNIX_EPOCH},
};

use regex::Regex;
use serde_json::{Map, Value, json};

use crate::control::{py_int_or_zero, py_str, py_truthy, runner_request};
use crate::docker::{api_json, get, num, quote};
use crate::text::bytes_human;

static SHA256_ID: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"^sha256:[0-9a-f]{64}$").unwrap());
static GIT_SHA: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"^[0-9a-f]{40}$").unwrap());
static GITHUB_SOURCE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"^https://github[.]com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$").unwrap());
static PROTECTED_WORDS: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"(?i)(?:^|[-_.])(backup|snapshot|archive|keep|rollback)(?:$|[-_.])").unwrap());

pub struct Inventory {
    pub rows: Vec<Value>,
    pub images: Vec<Value>,
    pub inspections: HashMap<String, Value>,
    pub failed: Vec<Value>,
}

/// Python `x or fallback` for JSON values.
fn or<'a>(v: &'a Value, fallback: &'a Value) -> &'a Value {
    if py_truthy(v) { v } else { fallback }
}

/// Python `str(x or "")`.
fn s(v: &Value) -> String {
    if py_truthy(v) { py_str(v) } else { String::new() }
}

/// Python `x or []` iterated as a list.
fn list(v: &Value) -> &[Value] {
    v.as_array().map_or(&[], Vec::as_slice)
}

/// `((row.get("Names") or [""])[0] or "").lstrip("/")`.
fn first_name(row: &Value) -> String {
    s(list(get(row, "Names")).first().unwrap_or(&Value::Null)).trim_start_matches('/').to_string()
}

/// server.py `_normalize_image_ref`.
pub fn normalize_image_ref(value: &str) -> String {
    let value = value.trim();
    if value.is_empty() || value.contains("@sha256:") {
        return value.to_string();
    }
    let last = value.rsplit('/').next().unwrap_or(value);
    if last.contains(':') { value.to_string() } else { format!("{value}:latest") }
}

/// server.py `_repo_from_tag`.
pub fn repo_from_tag(tag: &str) -> String {
    if let Some((repo, _)) = tag.split_once('@') {
        return repo.to_string();
    }
    match (tag.rfind('/'), tag.rfind(':')) {
        (slash, Some(colon)) if slash.is_none_or(|s| colon > s) => tag[..colon].to_string(),
        _ => tag.to_string(),
    }
}

/// Compare the selected platform manifest, not an OCI index against a config digest.
/// None means the identities cannot be compared safely.
fn image_identity_match(row: &Value, inspect: &Value, image: &Value) -> Option<bool> {
    let image_id = s(get(image, "Id"));
    let running_id = s(or(get(inspect, "Image"), get(row, "ImageID")));
    let descriptor = or(get(inspect, "ImageManifestDescriptor"), get(row, "ImageManifestDescriptor"));
    let manifest = s(get(descriptor, "digest"));
    let manifests = list(get(image, "Manifests"));
    if image_id.is_empty() {
        return None;
    }
    if !manifest.is_empty() {
        if manifest == image_id || manifest == s(get(get(image, "Descriptor"), "digest"))
            || manifests.iter().any(|m| get(m, "ID").as_str() == Some(manifest.as_str()))
        {
            return Some(true);
        }
        return (!manifests.is_empty()).then_some(false);
    }
    if !running_id.is_empty() && running_id == image_id {
        return Some(true);
    }
    let container_id = s(get(row, "Id"));
    if !container_id.is_empty() && manifests.iter().any(|m| {
        list(get(get(m, "ImageData"), "Containers")).iter().any(|id| id.as_str() == Some(container_id.as_str()))
    }) {
        return Some(true);
    }
    if !manifests.is_empty() || running_id.is_empty() {
        return None;
    }
    Some(false)
}

pub fn inventory() -> Result<Inventory, String> {
    let rows = api_json("/containers/json?all=1")?;
    let images = api_json("/images/json?all=0&manifests=1")?;
    let (Value::Array(rows), Value::Array(images)) = (rows, images) else {
        return Err("Docker inventory response is unavailable".into());
    };
    let mut inspections = HashMap::new();
    let mut failed = Vec::new();
    for row in &rows {
        let id = s(get(row, "Id"));
        if id.is_empty() {
            failed.push(Value::Null);
            continue;
        }
        if inspections.contains_key(&id) {
            continue;
        }
        match api_json(&format!("/containers/{}/json", quote(&id))) {
            Ok(inspect) => {
                if !inspect.is_object() || !py_truthy(get(&inspect, "Image")) {
                    failed.push(json!(id));
                }
                if inspect.is_object() {
                    inspections.insert(id, inspect);
                } else if inspect.is_null() {
                    // `_json(...) or {}`: an empty body is stored as an empty dict.
                    inspections.insert(id, json!({}));
                }
            }
            // The inventory still supports list-based fallback for this container.
            Err(_) => failed.push(json!(id)),
        }
    }
    Ok(Inventory { rows, images, inspections, failed })
}

fn now_unix() -> i64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |d| d.as_secs() as i64)
}

pub fn expected_projects() -> Vec<String> {
    std::env::var("DOCKERLOCAL_EXPECTED_MCP_PROJECTS")
        .unwrap_or_else(|_| "dockerlocal-public,dockerlocal".into())
        .split(',')
        .map(str::trim)
        .filter(|p| !p.is_empty())
        .map(String::from)
        .collect()
}

/// `_runner_request({"action": "compose_desired_state"})` normalized as in Python.
pub fn desired_state() -> Value {
    let mut payload = Map::new();
    payload.insert("action".into(), json!("compose_desired_state"));
    match runner_request(&crate::control::control_dir(), payload, Duration::from_secs(8)) {
        Ok(mut state) => {
            if get(&state, "status") != &json!("succeeded") {
                let status = state.get("status").cloned().unwrap_or(json!("unavailable"));
                return json!({"status": status, "projects": {},
                              "errors": [{"error": "maintenance_runner_unavailable"}]});
            }
            if let Some(m) = state.as_object_mut() {
                m.entry("projects").or_insert(json!({}));
                m.entry("errors").or_insert(json!([]));
            }
            state
        }
        Err(_) => json!({"status": "unavailable", "projects": {}, "errors": [{"error": "OSError"}]}),
    }
}

/// `GET /dockerlocal/runtime-source-drift` normalized as in Python; error names match
/// the Python exception types for the common cases.
pub fn source_audit() -> Value {
    let unavailable = |name: &str| {
        json!({"status": "unavailable", "checked_files": 0, "drift": [], "errors": [{"error": name}]})
    };
    match api_json("/dockerlocal/runtime-source-drift") {
        Ok(mut v) if v.is_object() && py_truthy(get(&v, "status")) => {
            let m = v.as_object_mut().unwrap();
            m.entry("checked_files").or_insert(json!(0));
            m.entry("drift").or_insert(json!([]));
            m.entry("errors").or_insert(json!([]));
            v
        }
        Ok(_) => unavailable("ValueError"),
        Err(e) if e.starts_with("Invalid Docker API JSON") => unavailable("JSONDecodeError"),
        Err(_) => unavailable("RuntimeError"),
    }
}

pub fn deployment_audit(
    inv: &Inventory,
    desired_state: &Value,
    source_audit: &Value,
    expected: &[String],
    fetch_image: &dyn Fn(&str) -> Result<Value, String>,
    timestamp: i64,
) -> Value {
    let empty = json!({});
    let mut images_by_ref: HashMap<String, &Value> = HashMap::new();
    for image in &inv.images {
        let id = s(get(image, "Id"));
        if id.is_empty() {
            continue;
        }
        for r in list(get(image, "RepoTags")).iter().chain(list(get(image, "RepoDigests"))) {
            images_by_ref.insert(py_str(r), image);
        }
    }

    let mut projects: BTreeMap<String, Value> = BTreeMap::new();
    let mut unmanaged = Vec::new();
    let mut stopped_or_unhealthy = Vec::new();
    let mut retained_legacy = Vec::new();
    let mut image_drift = Vec::new();
    let mut image_identity_unknown = Vec::new();
    let mut config_drift = Vec::new();
    let mut custom_running_images: BTreeMap<String, String> = BTreeMap::new();

    for row in &inv.rows {
        let labels = get(row, "Labels");
        let name = first_name(row);
        let project = get(labels, "com.docker.compose.project");
        let service = get(labels, "com.docker.compose.service");
        let state = get(row, "State");
        let status = get(row, "Status");
        let container_id = s(get(row, "Id"));

        let inspect = inv.inspections.get(&container_id).unwrap_or(&empty);
        let config = or(get(inspect, "Config"), &empty);
        let inspect_labels = or(get(config, "Labels"), labels);
        let configured_image = s(or(get(config, "Image"), get(row, "Image")));
        let running_image_id = s(or(get(inspect, "Image"), get(row, "ImageID")));
        // Only images built for this local stack, not published third-party images.
        if ["dockerlocal-", "firecrawl-", "influencerresearch-"].iter().any(|p| configured_image.starts_with(p)) {
            custom_running_images.insert(running_image_id.clone(), configured_image.clone());
        }
        let running_config_hash = s(get(inspect_labels, "com.docker.compose.config-hash"));

        let desired_project = get(get(desired_state, "projects"), &s(project));
        let desired_services = get(desired_project, "services");
        let desired_service = get(desired_services, &s(service));
        let desired_image = s(get(desired_service, "image"));
        let desired_config_hash = s(get(desired_service, "config_hash"));

        if py_truthy(project) && py_truthy(service) && py_truthy(desired_service) {
            let image_mismatch = !desired_image.is_empty()
                && normalize_image_ref(&desired_image) != normalize_image_ref(&configured_image);
            let hash_mismatch = !desired_config_hash.is_empty()
                && !running_config_hash.is_empty()
                && desired_config_hash != running_config_hash;
            if image_mismatch || hash_mismatch {
                let none_if_empty = |v: &str| if v.is_empty() { Value::Null } else { json!(v) };
                config_drift.push(json!({
                    "name": name, "project": project, "service": service,
                    "desired_image": none_if_empty(&desired_image),
                    "running_configured_image": none_if_empty(&configured_image),
                    "desired_config_hash": none_if_empty(&desired_config_hash),
                    "running_config_hash": none_if_empty(&running_config_hash),
                    "image_mismatch": image_mismatch,
                    "config_hash_mismatch": hash_mismatch,
                }));
            }
        }

        if py_truthy(project) {
            let key = py_str(project);
            let item = projects.entry(key.clone()).or_insert_with(|| {
                json!({"project": project, "containers": [], "running": 0, "non_running": 0})
            });
            item["containers"].as_array_mut().unwrap().push(json!({
                "name": name, "service": service, "image": configured_image, "state": state, "status": status,
            }));
            let counter = if state == "running" { "running" } else { "non_running" };
            item[counter] = json!(item[counter].as_i64().unwrap() + 1);
        } else {
            unmanaged.push(json!({
                "name": name, "image": configured_image, "state": state, "status": status,
                "created": get(row, "Created"),
            }));
        }

        // Suppress only reviewed, intentionally stopped services after a verified
        // active Rust desired-state receipt. A running legacy service still needs attention.
        let rust_firecrawl = project == "firecrawl" && get(desired_project, "engine_mode") == "rust";
        let legacy_service = ["redis", "rabbitmq", "nuq-postgres"].iter().any(|n| service == *n);
        let in_desired = desired_services.as_object().is_some_and(|m| m.contains_key(&py_str(service)))
            || desired_services.as_array().is_some_and(|a| a.contains(service));
        let retained = rust_firecrawl && legacy_service && !in_desired && state == "exited";
        let exit_code = get(or(get(inspect, "State"), &empty), "ExitCode");
        let completed_init = rust_firecrawl && service == "rust-init" && state == "exited"
            && (exit_code.as_f64() == Some(0.0) || exit_code == &json!(false));
        let unexpected_legacy = rust_firecrawl && legacy_service && state == "running";
        if retained {
            retained_legacy.push(json!({"name": name, "project": project, "service": service, "state": state}));
        }
        if !retained && !completed_init
            && (state != "running" || s(status).to_lowercase().contains("unhealthy") || unexpected_legacy)
        {
            stopped_or_unhealthy.push(json!({
                "name": name, "project": project, "service": service, "state": state, "status": status,
            }));
        }

        let normalized = normalize_image_ref(&configured_image);
        let current = [configured_image.as_str(), normalized.as_str()]
            .into_iter()
            .find_map(|r| images_by_ref.get(r));
        if let Some(current) = current {
            let findings = match image_identity_match(row, inspect, current) {
                Some(true) => None,
                Some(false) => Some(&mut image_drift),
                None => Some(&mut image_identity_unknown),
            };
            if let Some(findings) = findings {
                findings.push(json!({
                    "name": name, "project": project, "service": service,
                    "configured_image": configured_image,
                    "running_image_id": running_image_id,
                    "current_local_image_id": get(current, "Id"),
                }));
            }
        }
    }

    // OCI labels are a recorded build claim, not an attestation; unlabeled stays unknown.
    let mut image_provenance = Vec::new();
    for (image_id, image) in &custom_running_images {
        let mut item = json!({
            "image": image, "image_id": if image_id.is_empty() { Value::Null } else { json!(image_id) },
            "status": "unknown", "source": null, "revision": null,
        });
        if SHA256_ID.is_match(image_id) {
            match fetch_image(image_id) {
                Ok(raw) => {
                    let labels = or(get(or(get(&raw, "Config"), &empty), "Labels"), &empty);
                    let revision = s(get(labels, "org.opencontainers.image.revision"));
                    let source = s(get(labels, "org.opencontainers.image.source"));
                    if GIT_SHA.is_match(&revision) && GITHUB_SOURCE.is_match(&source) {
                        item["status"] = json!("recorded");
                        item["source"] = json!(source);
                        item["revision"] = json!(revision);
                    }
                }
                Err(_) => item["status"] = json!("unavailable"),
            }
        }
        image_provenance.push(item);
    }

    let seen: HashSet<&String> = projects.keys().collect();
    let mut missing: Vec<&String> = expected.iter().collect::<HashSet<_>>().into_iter().filter(|p| !seen.contains(p)).collect();
    missing.sort();
    let drift = or(get(source_audit, "drift"), &json!([])).clone();
    let drift_len = drift.as_array().map_or(0, Vec::len);
    let without_revision = image_provenance.iter().filter(|i| i["status"] != "recorded").count();

    json!({
        "timestamp_unix": timestamp,
        "expected_projects": expected,
        "missing_expected_projects": missing,
        "projects": projects.values().collect::<Vec<_>>(),
        "unmanaged_containers": unmanaged,
        "stopped_or_unhealthy": stopped_or_unhealthy,
        "retained_legacy": retained_legacy,
        "local_image_drift": image_drift,
        "local_image_identity_unknown": image_identity_unknown,
        "image_provenance": image_provenance,
        "compose_desired_state": {
            "status": get(desired_state, "status"),
            "errors": or(get(desired_state, "errors"), &json!([])),
        },
        "compose_config_drift": config_drift,
        "runtime_source_audit": {
            "status": get(source_audit, "status"),
            "checked_files": py_int_or_zero(source_audit.get("checked_files")).unwrap_or(0),
            "errors": or(get(source_audit, "errors"), &json!([])),
        },
        "runtime_source_drift": drift,
        "summary": {
            "compose_projects": projects.len(),
            "unmanaged_containers": unmanaged.len(),
            "stopped_or_unhealthy": stopped_or_unhealthy.len(),
            "retained_legacy": retained_legacy.len(),
            "local_image_drift": image_drift.len(),
            "local_image_identity_unknown": image_identity_unknown.len(),
            "local_images_without_recorded_revision": without_revision,
            "compose_config_drift": config_drift.len(),
            "runtime_source_drift": drift_len,
            "missing_expected_projects": missing.len(),
        },
    })
}

pub fn image_usage_audit(inv: &Inventory) -> Value {
    let empty = json!({});
    // Insertion-ordered like the Python dict: container order per image.
    let mut in_use_by: HashMap<String, Vec<String>> = HashMap::new();
    let mut unknown_by: HashMap<String, Vec<String>> = HashMap::new();
    for image in &inv.images {
        let image_id = s(get(image, "Id"));
        for row in &inv.rows {
            let id = s(get(row, "Id"));
            let inspect = inv.inspections.get(&id).unwrap_or(&empty);
            match image_identity_match(row, inspect, image) {
                Some(true) => in_use_by.entry(image_id.clone()).or_default().push(first_name(row)),
                Some(false) => (),
                None => unknown_by.entry(image_id.clone()).or_default().push(first_name(row)),
            }
        }
    }
    let mut used_repos: HashSet<String> = HashSet::new();
    for image in &inv.images {
        if in_use_by.contains_key(&s(get(image, "Id"))) {
            used_repos.extend(list(get(image, "RepoTags")).iter().map(|t| repo_from_tag(&py_str(t))));
        }
    }

    let mut items = Vec::new();
    let mut candidates = Vec::new();
    for image in &inv.images {
        let id = s(get(image, "Id"));
        let tags: Vec<String> = list(get(image, "RepoTags")).iter().map(py_str).collect();
        let used_by = in_use_by.get(&id).cloned().unwrap_or_default();
        let unknown = unknown_by.get(&id).cloned().unwrap_or_default();
        let repos: HashSet<String> = tags.iter().map(|t| repo_from_tag(t)).collect();
        let protected = tags.iter().any(|t| PROTECTED_WORDS.is_match(t));
        let hint = !tags.is_empty() && used_by.is_empty() && unknown.is_empty() && !repos.is_empty()
            && repos.iter().all(|r| used_repos.contains(r));
        let item = json!({
            "id": id, "tags": tags,
            "repo_digests": or(get(image, "RepoDigests"), &json!([])),
            "created": get(image, "Created"),
            "size": bytes_human(num(get(image, "Size"))),
            "in_use_by": used_by,
            "usage_unknown_by": unknown,
            "protected_name": protected,
            "superseded_repository_hint": hint,
        });
        if hint && !protected {
            candidates.push(item.clone());
        }
        items.push(item);
    }
    let in_use = items.iter().filter(|i| !list(&i["in_use_by"]).is_empty()).count();
    let unknown = items.iter().filter(|i| list(&i["in_use_by"]).is_empty() && !list(&i["usage_unknown_by"]).is_empty()).count();
    json!({
        "images": items,
        // Compatibility field kept; no heuristic-only image is ever called safe.
        "safe_superseded_candidates": [],
        "repository_superseded_hints": candidates,
        "cleanup_requires_explicit_ref": true,
        "summary": {
            "images": items.len(),
            "in_use": in_use,
            "unused": items.len() - in_use - unknown,
            "unknown": unknown,
            "safe_superseded_candidates": 0,
            "repository_superseded_hints": candidates.len(),
        },
    })
}

/// The live image fetch used for provenance.
pub fn fetch_image(image_id: &str) -> Result<Value, String> {
    api_json(&format!("/images/{}/json", quote(image_id))).map(|v| if v.is_null() { json!({}) } else { v })
}

pub fn now() -> i64 {
    now_unix()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ref_helpers_match_python() {
        assert_eq!(normalize_image_ref("redis"), "redis:latest");
        assert_eq!(normalize_image_ref("host:5000/app"), "host:5000/app:latest");
        assert_eq!(normalize_image_ref("app:1"), "app:1");
        assert_eq!(normalize_image_ref("app@sha256:ab"), "app@sha256:ab");
        assert_eq!(normalize_image_ref("  "), "");
        assert_eq!(repo_from_tag("ghcr.io/a/b:1"), "ghcr.io/a/b");
        assert_eq!(repo_from_tag("host:5000/app"), "host:5000/app");
        assert_eq!(repo_from_tag("app@sha256:x"), "app");
        assert_eq!(repo_from_tag("app"), "app");
    }

    fn inv() -> Inventory {
        let rows = vec![
            json!({"Id": "c1", "Names": ["/dockerlocal-mcp-http"], "Image": "dockerlocal-mcp:local", "ImageID": "sha256:old",
                   "State": "running", "Status": "Up 1 hour (unhealthy)",
                   "Labels": {"com.docker.compose.project": "dockerlocal-public", "com.docker.compose.service": "mcp"}}),
            json!({"Id": "c2", "Names": ["/firecrawl-redis-1"], "Image": "redis:8", "ImageID": "sha256:r",
                   "State": "exited", "Status": "Exited (0)",
                   "Labels": {"com.docker.compose.project": "firecrawl", "com.docker.compose.service": "redis"}}),
            json!({"Id": "c3", "Names": ["/firecrawl-rust-init-1"], "Image": "firecrawl-rust:1", "ImageID": "sha256:i",
                   "State": "exited", "Status": "Exited (0)",
                   "Labels": {"com.docker.compose.project": "firecrawl", "com.docker.compose.service": "rust-init"}}),
            json!({"Id": "c4", "Names": [], "Image": "alpine", "ImageID": "sha256:unrelated", "State": "exited", "Status": "Exited (1)",
                   "Labels": {}, "Created": 5}),
        ];
        let images = vec![
            json!({"Id": "sha256:new", "RepoTags": ["dockerlocal-mcp:local"], "RepoDigests": [], "Size": 2048, "Created": 1}),
            json!({"Id": "sha256:old", "RepoTags": ["dockerlocal-mcp:rollback-1"], "Size": 1024, "Created": 0}),
            json!({"Id": "sha256:bk", "RepoTags": ["dockerlocal-mcp:pre-backup"], "Size": 0}),
        ];
        let mut inspections = HashMap::new();
        inspections.insert("c1".into(), json!({"Image": "sha256:old", "Config": {"Image": "dockerlocal-mcp:local",
            "Labels": {"com.docker.compose.config-hash": "h-running"}}}));
        inspections.insert("c3".into(), json!({"Image": "sha256:i", "State": {"ExitCode": 0}}));
        Inventory { rows, images, inspections, failed: vec![] }
    }

    #[test]
    fn deployment_audit_golden() {
        let desired = json!({"status": "succeeded", "projects": {
            "dockerlocal-public": {"services": {"mcp": {"image": "dockerlocal-mcp:local", "config_hash": "h-desired"}}},
            "firecrawl": {"engine_mode": "rust", "services": {"api": {}}},
        }, "errors": []});
        let source = json!({"status": "ok", "checked_files": "3", "drift": [{"file": "x"}]});
        let audit = deployment_audit(&inv(), &desired, &source, &["dockerlocal-public".into(), "dockerlocal".into()],
            &|_| Ok(json!({"Config": {"Labels": {}}})), 7);
        assert_eq!(audit["missing_expected_projects"], json!(["dockerlocal"]));
        assert_eq!(audit["compose_config_drift"][0]["config_hash_mismatch"], json!(true));
        assert_eq!(audit["compose_config_drift"][0]["image_mismatch"], json!(false));
        // Exited legacy redis under the Rust receipt is retained, the clean rust-init is not reported,
        // and the unhealthy running MCP plus the unmanaged exited container are.
        assert_eq!(audit["retained_legacy"][0]["service"], json!("redis"));
        let reported: Vec<&Value> = audit["stopped_or_unhealthy"].as_array().unwrap().iter().map(|r| &r["name"]).collect();
        assert_eq!(reported, vec![&json!("dockerlocal-mcp-http"), &json!("")]);
        assert_eq!(audit["local_image_drift"][0]["current_local_image_id"], json!("sha256:new"));
        assert_eq!(audit["unmanaged_containers"][0]["created"], json!(5));
        assert_eq!(audit["projects"][0]["project"], json!("dockerlocal-public"));
        assert_eq!(audit["runtime_source_audit"]["checked_files"], json!(3));
        assert_eq!(audit["summary"]["runtime_source_drift"], json!(1));
        // sha256:old and sha256:i are custom stack images without labels -> unknown, not "recorded".
        assert_eq!(audit["summary"]["local_images_without_recorded_revision"], json!(2));
    }

    /// Full-structure equality with server.py's own output on the same fixture
    /// (`audit_golden.json`, produced by running the Python functions in the production image).
    #[test]
    fn matches_python_golden_output() {
        let golden: Value = serde_json::from_str(include_str!("audit_golden.json")).unwrap();
        let desired = json!({"status": "succeeded", "projects": {
            "dockerlocal-public": {"services": {"mcp": {"image": "dockerlocal-mcp:local", "config_hash": "h-desired"}}},
            "firecrawl": {"engine_mode": "rust", "services": {"api": {}}},
        }, "errors": []});
        let source = json!({"status": "ok", "checked_files": "3", "drift": [{"file": "x"}]});
        let deploy = deployment_audit(&inv(), &desired, &source, &["dockerlocal-public".into(), "dockerlocal".into()],
            &|_| Ok(json!({"Config": {"Labels": {}}})), 7);
        assert_eq!(deploy, golden["deploy"]);
        assert_eq!(image_usage_audit(&inv()), golden["usage"]);
    }

    #[test]
    fn image_usage_golden() {
        let audit = image_usage_audit(&inv());
        let by_id = |id: &str| audit["images"].as_array().unwrap().iter().find(|i| i["id"] == id).unwrap().clone();
        assert_eq!(by_id("sha256:old")["in_use_by"], json!(["dockerlocal-mcp-http"]));
        assert_eq!(by_id("sha256:new")["superseded_repository_hint"], json!(true));
        assert_eq!(by_id("sha256:bk")["protected_name"], json!(true));
        assert_eq!(audit["repository_superseded_hints"].as_array().unwrap().len(), 1);
        assert_eq!(audit["summary"], json!({"images": 3, "in_use": 1, "unused": 2, "unknown": 0,
            "safe_superseded_candidates": 0, "repository_superseded_hints": 1}));
    }
}
