//! Validation, targets and response parsing for the write tools, mirroring server.py
//! (`cleanup_superseded_images`, `compose_redeploy`, `image_pull`, `container_restart`,
//! `image_prune_dangling`, `cleanup_stale_mcp_containers`). Kept pure so the rules are tested.

use serde_json::{Value, json};

use crate::docker::{COMPOSE_PROJECT, IMAGE_REF, qs, quote};

pub const OPERATIONS: [&str; 6] = [
    "redeploy_current", "rebuild_and_redeploy", "sync_upstream", "build_only", "deploy_staged", "update_stateless",
];
const SCRIPT_OPERATIONS: [&str; 3] = ["sync_upstream", "build_only", "deploy_staged"];
const STATELESS_FIRECRAWL: [&str; 5] =
    ["api", "mcp", "playwright-service", "browser-session-service", "playwright-public-proxy-service"];

/// Explicit tag or digest refs only, deduplicated in order; returns the proxy target.
pub fn cleanup_target(image_refs: &[String]) -> Result<String, String> {
    if !(1..=20).contains(&image_refs.len()) {
        return Err("image_refs must contain 1-20 explicit image references".into());
    }
    let mut clean: Vec<String> = Vec::new();
    for raw in image_refs {
        let r = raw.trim().to_string();
        if !IMAGE_REF.is_match(&r) {
            return Err("Invalid image reference".into());
        }
        let last = r.rsplit('/').next().unwrap_or(&r);
        if !(r.starts_with("sha256:") || r.contains("@sha256:") || last.contains(':')) {
            return Err("Cleanup requires an explicit tag or immutable digest".into());
        }
        if !clean.contains(&r) {
            clean.push(r);
        }
    }
    Ok(format!("/dockerlocal/cleanup-superseded-images?refs={}", qs(&json!(clean).to_string())))
}

/// The queued job payload for `compose_redeploy`, after every reviewed rule.
pub fn redeploy_job(project: &str, services: &[String], operation: &str) -> Result<Value, String> {
    if !COMPOSE_PROJECT.is_match(project) {
        return Err("Invalid Compose project name".into());
    }
    if services.iter().any(|s| !COMPOSE_PROJECT.is_match(s)) {
        return Err("Invalid service name".into());
    }
    if !OPERATIONS.contains(&operation) {
        return Err("Unsupported maintenance operation".into());
    }
    if SCRIPT_OPERATIONS.contains(&operation) && !services.is_empty() {
        return Err("Restricted script-backed operations cannot accept services".into());
    }
    // One operation per explicitly reviewed stateless Firecrawl service.
    if operation == "update_stateless"
        && (project != "firecrawl" || services.len() != 1 || !STATELESS_FIRECRAWL.contains(&services[0].as_str()))
    {
        return Err("Stateful or unreviewed service cannot use update_stateless".into());
    }
    Ok(json!({"action": "compose_redeploy", "project": project, "services": services, "operation": operation}))
}

pub fn pull_target(image: &str) -> String {
    format!("/images/create?fromImage={}", qs(image))
}

pub fn restart_target(container: &str, timeout_seconds: i64) -> (String, i64) {
    let t = timeout_seconds.clamp(0, 60);
    (format!("/containers/{}/restart?t={t}", quote(container)), t)
}

pub fn prune_target() -> String {
    format!("/images/prune?filters={}", qs(r#"{"dangling":["true"]}"#))
}

pub fn stale_target(min_age_minutes: i64) -> (String, i64) {
    let minutes = min_age_minutes.clamp(5, 24 * 60);
    (format!("/dockerlocal/cleanup-stale-mcp-probes?min_age_seconds={}", minutes * 60), minutes)
}

/// `image_pull` stream: skip non-JSON lines, fail on the first error, keep the last 20 statuses.
pub fn pull_messages(body: &[u8]) -> Result<Vec<Value>, String> {
    let text = String::from_utf8_lossy(body);
    let mut messages = Vec::new();
    for line in crate::control::py_splitlines(&text) {
        let Ok(msg) = serde_json::from_str::<Value>(line) else { continue };
        let error = msg.get("error").filter(|e| crate::control::py_truthy(e));
        if let Some(error) = error {
            return Err(crate::control::py_str(error));
        }
        if msg.get("status").is_some_and(crate::control::py_truthy) {
            messages.push(json!({"status": msg["status"], "id": msg.get("id").cloned().unwrap_or(Value::Null)}));
        }
    }
    let skip = messages.len().saturating_sub(20);
    Ok(messages.split_off(skip))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn s(v: &[&str]) -> Vec<String> {
        v.iter().map(|x| x.to_string()).collect()
    }

    #[test]
    fn cleanup_refs_rules_and_python_encoding() {
        // Same target urllib.parse.urlencode builds; proxy.allowed_custom() accepts it.
        let digest = format!("sha256:{}", "a".repeat(64));
        assert_eq!(
            cleanup_target(&s(&["dockerlocal-mcp:rollback-1", &digest, " dockerlocal-mcp:rollback-1 "])).unwrap(),
            format!("/dockerlocal/cleanup-superseded-images?refs=%5B%22dockerlocal-mcp%3Arollback-1%22%2C%22sha256%3A{}%22%5D", "a".repeat(64))
        );
        assert!(cleanup_target(&[]).is_err());
        assert!(cleanup_target(&s(&["x:1"; 21])).is_err());
        assert_eq!(cleanup_target(&s(&["host:5000/app"])).unwrap_err(), "Cleanup requires an explicit tag or immutable digest");
        assert_eq!(cleanup_target(&s(&["../x:1"])).unwrap_err(), "Invalid image reference");
        assert!(cleanup_target(&s(&["app@sha256:ab"])).is_ok());
    }

    #[test]
    fn redeploy_rules() {
        assert_eq!(redeploy_job("firecrawl", &s(&["api"]), "update_stateless").unwrap()["services"], json!(["api"]));
        assert!(redeploy_job("firecrawl", &s(&["redis"]), "update_stateless").is_err());
        assert!(redeploy_job("dockerlocal", &s(&["api"]), "update_stateless").is_err());
        assert!(redeploy_job("firecrawl", &s(&["api", "mcp"]), "update_stateless").is_err());
        assert!(redeploy_job("x", &s(&["svc"]), "build_only").is_err());
        assert!(redeploy_job("x", &[], "build_only").is_ok());
        assert!(redeploy_job("x", &s(&["bad name"]), "redeploy_current").is_err());
        assert!(redeploy_job("bad name", &[], "redeploy_current").is_err());
        assert!(redeploy_job("x", &[], "rm -rf").is_err());
        assert_eq!(redeploy_job("x", &[], "redeploy_current").unwrap(),
            json!({"action": "compose_redeploy", "project": "x", "services": [], "operation": "redeploy_current"}));
    }

    #[test]
    fn targets_match_python() {
        assert_eq!(prune_target(), "/images/prune?filters=%7B%22dangling%22%3A%5B%22true%22%5D%7D");
        assert_eq!(restart_target("dockerlocal-mcp-http", 99), ("/containers/dockerlocal-mcp-http/restart?t=60".into(), 60));
        assert_eq!(restart_target("c", -1).1, 0);
        assert_eq!(stale_target(1), ("/dockerlocal/cleanup-stale-mcp-probes?min_age_seconds=300".into(), 5));
        assert_eq!(stale_target(100_000).1, 1440);
        assert_eq!(pull_target(&format!("ghcr.io/a/b:1@sha256:{}", "b".repeat(64))),
            format!("/images/create?fromImage=ghcr.io%2Fa%2Fb%3A1%40sha256%3A{}", "b".repeat(64)));
    }

    #[test]
    fn pull_stream_parsing() {
        let ok = b"{\"status\":\"Pulling from library/alpine\",\"id\":\"3.20\"}\r\nnot json\n{\"status\":\"Digest: sha256:x\"}\n{\"progress\":\"[=>]\"}\n";
        assert_eq!(pull_messages(ok).unwrap(), vec![
            json!({"status": "Pulling from library/alpine", "id": "3.20"}),
            json!({"status": "Digest: sha256:x", "id": null}),
        ]);
        assert_eq!(pull_messages(b"{\"error\":\"manifest unknown\"}\n").unwrap_err(), "manifest unknown");
        let many: String = (0..25).map(|i| format!("{{\"status\":\"s{i}\"}}\n")).collect();
        let tail = pull_messages(many.as_bytes()).unwrap();
        assert_eq!((tail.len(), tail[0]["status"].clone()), (20, json!("s5")));
    }
}
