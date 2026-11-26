//! DockerLocal MCP in Rust, ported tool by tool from server.py with parity checks.
//! Batches 1-4: Docker API reads, host runner/control-file tools, audits and proxy writes.
//! Not wired into any deployment yet.

mod audit;
mod control;
mod docker;
mod text;
mod writes;

use rmcp::{
    ServiceExt,
    handler::server::wrapper::{Json, Parameters},
    model::{CallToolResult, ContentBlock},
    schemars, tool, tool_router,
};
use serde::Deserialize;
use serde_json::{Map, Value, json};

use docker::{
    COMPOSE_PROJECT, CONTAINER_REF, IMAGE_REF, api_json, api_post_json, api_post_raw, api_raw, blocking, get, num, obj, quote,
    round2, valid,
};
use text::{bytes_human, decode_logs, redact};

#[derive(Deserialize, schemars::JsonSchema)]
struct ListArgs {
    #[serde(default = "yes")]
    include_stopped: bool,
}
fn yes() -> bool {
    true
}
#[derive(Deserialize, schemars::JsonSchema)]
struct ContainerArg {
    container: String,
}
#[derive(Deserialize, schemars::JsonSchema)]
struct LogsArgs {
    container: String,
    #[serde(default = "default_tail")]
    tail: i64,
}
fn default_tail() -> i64 {
    200
}
#[derive(Deserialize, schemars::JsonSchema)]
struct ProjectArg {
    #[serde(default)]
    project: Option<String>,
}
#[derive(Deserialize, schemars::JsonSchema)]
struct ImageArg {
    image: String,
}

/// FastMCP's list contract: text is the bare array, structured content wraps it in "result".
fn list_result(rows: Vec<Value>) -> CallToolResult {
    let text = Value::Array(rows.clone()).to_string();
    let mut result = CallToolResult::structured(json!({ "result": rows }));
    result.content = vec![ContentBlock::text(text)];
    result
}

#[derive(Deserialize, schemars::JsonSchema)]
struct RepoArg {
    repo: String,
}
#[derive(Deserialize, schemars::JsonSchema)]
struct TaskArg {
    task: String,
}
#[derive(Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "lowercase")]
enum TaskOperation {
    Start,
    Stop,
    Restart,
}
#[derive(Deserialize, schemars::JsonSchema)]
struct TaskControlArgs {
    task: String,
    operation: TaskOperation,
}
#[derive(Deserialize, schemars::JsonSchema)]
struct JobArg {
    job_id: String,
}
#[derive(Deserialize, schemars::JsonSchema)]
struct SupervisorArgs {
    #[serde(default = "default_log_tail")]
    log_tail: i64,
}
fn default_log_tail() -> i64 {
    40
}
#[derive(Deserialize, schemars::JsonSchema)]
struct RunnerStatusArgs {
    #[serde(default)]
    include_host_checks: bool,
}

/// Tools that return a pre-serialized JSON string: FastMCP sends it as plain text only.
fn text_result(text: String) -> CallToolResult {
    CallToolResult::success(vec![ContentBlock::text(text)])
}

/// One `_compact_runner_request` round trip on a blocking thread.
async fn runner(payload: Value, fields: &'static [&'static str], timeout: f64) -> Result<CallToolResult, String> {
    let text = blocking(move || control::compact_request(&control::control_dir(), payload, fields, timeout)).await?;
    Ok(text_result(text))
}

const REPO_STATUS_FIELDS: &[&str] = &["repo", "branch", "head", "clean", "conflicts", "origin_ok", "eligible_for_pull"];
const REPO_PULL_FIELDS: &[&str] = &["action", "repo", "branch", "before_head", "after_head", "changed", "clean"];
const PORT_FIELDS: &[&str] = &["version", "range_start", "range_end", "services", "docker_reserved_ports", "unregistered_listeners"];
const TASK_STATUS_FIELDS: &[&str] = &["task", "state", "principal", "run_level", "last_run_time", "last_task_result"];
const TASK_CONTROL_FIELDS: &[&str] = &["action", "task", "operation", "before_state", "after_state", "last_task_result"];
const DISK_FIELDS: &[&str] = &["measurement_status", "measured_unix", "drives"];

#[derive(Deserialize, schemars::JsonSchema)]
struct DeploymentAuditArgs {
    #[serde(default)]
    include_image_usage: bool,
}

#[derive(Deserialize, schemars::JsonSchema)]
struct CleanupArgs {
    image_refs: Vec<String>,
}
#[derive(Deserialize, serde::Serialize, schemars::JsonSchema, Default)]
#[serde(rename_all = "snake_case")]
enum RedeployOperation {
    RedeployCurrent,
    #[default]
    RebuildAndRedeploy,
    SyncUpstream,
    BuildOnly,
    DeployStaged,
    UpdateStateless,
}
#[derive(Deserialize, schemars::JsonSchema)]
struct RedeployArgs {
    project: String,
    #[serde(default)]
    services: Option<Vec<String>>,
    #[serde(default)]
    operation: RedeployOperation,
}
#[derive(Deserialize, schemars::JsonSchema)]
struct StaleArgs {
    #[serde(default = "default_stale_minutes")]
    min_age_minutes: i64,
}
fn default_stale_minutes() -> i64 {
    15
}
#[derive(Deserialize, schemars::JsonSchema)]
struct RestartArgs {
    container: String,
    #[serde(default = "default_restart_timeout")]
    timeout_seconds: i64,
}
fn default_restart_timeout() -> i64 {
    10
}

/// Python `_json(...) or {}`.
fn or_empty(v: Value) -> Value {
    if control::py_truthy(&v) { v } else { json!({}) }
}

#[derive(Clone)]
struct DockerLocal;

#[tool_router(server_handler)]
impl DockerLocal {
    #[tool(description = "List local Docker containers without modifying them.",
           annotations(read_only_hint = true, destructive_hint = false, idempotent_hint = true, open_world_hint = false))]
    async fn containers_list(&self, Parameters(a): Parameters<ListArgs>) -> Result<CallToolResult, String> {
        let all = if a.include_stopped { "1" } else { "0" };
        let rows = blocking(move || api_json(&format!("/containers/json?all={all}"))).await?;
        let out = rows.as_array().into_iter().flatten().map(|r| json!({
            "id": get(r, "Id"), "names": get(r, "Names"), "image": get(r, "Image"),
            "image_id": get(r, "ImageID"), "state": get(r, "State"), "status": get(r, "Status"),
            "ports": get(r, "Ports"),
            "networks": obj(get(get(r, "NetworkSettings"), "Networks")).keys().collect::<Vec<_>>(),
        })).collect();
        Ok(list_result(out))
    }

    #[tool(description = "Inspect one container while omitting environment variables, command arguments and labels.",
           annotations(read_only_hint = true, destructive_hint = false, idempotent_hint = true, open_world_hint = false))]
    async fn container_inspect(&self, Parameters(a): Parameters<ContainerArg>) -> Result<Json<Value>, String> {
        let c = valid(&CONTAINER_REF, a.container, "Invalid container name or ID")?;
        let raw = blocking(move || api_json(&format!("/containers/{}/json", quote(&c)))).await?;
        let (state, config, host, net) = (get(&raw, "State"), get(&raw, "Config"), get(&raw, "HostConfig"), get(&raw, "NetworkSettings"));
        let networks: Map<String, Value> = obj(get(net, "Networks")).iter().map(|(k, v)| {
            (k.clone(), json!({"ip_address": get(v, "IPAddress"), "gateway": get(v, "Gateway"), "aliases": get(v, "Aliases")}))
        }).collect();
        let mounts: Vec<Value> = get(&raw, "Mounts").as_array().into_iter().flatten().map(|m| json!({
            "type": get(m, "Type"), "name": get(m, "Name"), "source": get(m, "Source"),
            "destination": get(m, "Destination"), "rw": get(m, "RW"),
        })).collect();
        Ok(Json(json!({
            "id": get(&raw, "Id"),
            "name": get(&raw, "Name").as_str().unwrap_or("").trim_start_matches('/'),
            "image": get(config, "Image"), "image_id": get(&raw, "Image"),
            "created": get(&raw, "Created"), "platform": get(&raw, "Platform"),
            "configured_user": get(config, "User").as_str().unwrap_or(""),
            "restart_count": get(&raw, "RestartCount"),
            "state": {
                "status": get(state, "Status"), "running": get(state, "Running"), "paused": get(state, "Paused"),
                "restarting": get(state, "Restarting"), "started_at": get(state, "StartedAt"),
                "finished_at": get(state, "FinishedAt"), "exit_code": get(state, "ExitCode"),
                "health": get(get(state, "Health"), "Status"),
            },
            "restart_policy": get(get(host, "RestartPolicy"), "Name"),
            "ports": get(net, "Ports"), "networks": networks, "mounts": mounts,
        })))
    }

    #[tool(description = "Read up to 1000 recent log lines from one container with basic secret redaction.",
           annotations(read_only_hint = true, destructive_hint = false, idempotent_hint = true, open_world_hint = false))]
    async fn container_logs(&self, Parameters(a): Parameters<LogsArgs>) -> Result<Json<Value>, String> {
        let c = valid(&CONTAINER_REF, a.container, "Invalid container name or ID")?;
        let tail = a.tail.clamp(1, 1000);
        let q = quote(&c);
        let body = blocking(move || {
            api_raw(&format!("/containers/{q}/logs?stdout=1&stderr=1&timestamps=1&tail={tail}"))
        }).await?;
        Ok(Json(json!({ "container": c, "tail": tail, "logs": redact(&decode_logs(&body)) })))
    }

    #[tool(description = "Return one non-streaming CPU, memory, network and PID snapshot.",
           annotations(read_only_hint = true, destructive_hint = false, idempotent_hint = true, open_world_hint = false))]
    async fn container_stats(&self, Parameters(a): Parameters<ContainerArg>) -> Result<Json<Value>, String> {
        let c = valid(&CONTAINER_REF, a.container, "Invalid container name or ID")?;
        let q = quote(&c);
        let s = blocking(move || api_json(&format!("/containers/{q}/stats?stream=false"))).await?;
        let (cpu, pre) = (get(&s, "cpu_stats"), get(&s, "precpu_stats"));
        let cpu_delta = num(get(get(cpu, "cpu_usage"), "total_usage")) - num(get(get(pre, "cpu_usage"), "total_usage"));
        let sys_delta = num(get(cpu, "system_cpu_usage")) - num(get(pre, "system_cpu_usage"));
        let percpu = get(get(cpu, "cpu_usage"), "percpu_usage").as_array().map_or(0, Vec::len);
        let cpus = match num(get(cpu, "online_cpus")) { n if n > 0.0 => n, _ if percpu > 0 => percpu as f64, _ => 1.0 };
        let cpu_percent = if cpu_delta > 0.0 && sys_delta > 0.0 { cpu_delta / sys_delta * cpus * 100.0 } else { 0.0 };
        let mem = get(&s, "memory_stats");
        let (usage, limit) = (num(get(mem, "usage")), num(get(mem, "limit")));
        let nets = obj(get(&s, "networks"));
        let rx: f64 = nets.values().map(|v| num(get(v, "rx_bytes"))).sum();
        let tx: f64 = nets.values().map(|v| num(get(v, "tx_bytes"))).sum();
        Ok(Json(json!({
            "container": c, "cpu_percent": round2(cpu_percent),
            "memory": bytes_human(usage), "memory_limit": bytes_human(limit),
            "memory_percent": round2(if limit > 0.0 { usage / limit * 100.0 } else { 0.0 }),
            "network_rx": bytes_human(rx), "network_tx": bytes_human(tx),
            "pids": get(get(&s, "pids_stats"), "current"),
        })))
    }

    #[tool(description = "Summarize Compose projects using Docker labels; no Compose files are opened.",
           annotations(read_only_hint = true, destructive_hint = false, idempotent_hint = true, open_world_hint = false))]
    async fn compose_status(&self, Parameters(a): Parameters<ProjectArg>) -> Result<CallToolResult, String> {
        let project = match a.project {
            Some(p) => Some(valid(&COMPOSE_PROJECT, p, "Invalid Compose project name")?),
            None => None,
        };
        let rows = blocking(|| api_json("/containers/json?all=1")).await?;
        // Insertion order of first occurrence, like the Python dict.
        let mut grouped: Vec<(String, Value)> = Vec::new();
        for row in rows.as_array().into_iter().flatten() {
            let labels = get(row, "Labels");
            let Some(name) = get(labels, "com.docker.compose.project").as_str().filter(|n| !n.is_empty()) else { continue };
            if project.as_deref().is_some_and(|p| p != name) {
                continue;
            }
            let idx = match grouped.iter().position(|(n, _)| n == name) {
                Some(i) => i,
                None => {
                    grouped.push((name.to_string(), json!({
                        "project": name,
                        "config_files": get(labels, "com.docker.compose.project.config_files"),
                        "working_dir": get(labels, "com.docker.compose.project.working_dir"),
                        "containers": [],
                    })));
                    grouped.len() - 1
                }
            };
            let first_name = get(row, "Names").as_array().and_then(|n| n.first()).cloned().unwrap_or(Value::Null);
            grouped[idx].1["containers"].as_array_mut().unwrap().push(json!({
                "name": first_name, "service": get(labels, "com.docker.compose.service"),
                "image": get(row, "Image"), "state": get(row, "State"), "status": get(row, "Status"),
            }));
        }
        Ok(list_result(grouped.into_iter().map(|(_, v)| v).collect()))
    }

    #[tool(description = "List local Docker images.",
           annotations(read_only_hint = true, destructive_hint = false, idempotent_hint = true, open_world_hint = false))]
    async fn images_list(&self) -> Result<CallToolResult, String> {
        let rows = blocking(|| api_json("/images/json?all=0")).await?;
        let out = rows.as_array().into_iter().flatten().map(|r| json!({
            "id": get(r, "Id"), "repo_tags": get(r, "RepoTags"), "repo_digests": get(r, "RepoDigests"),
            "created": get(r, "Created"), "size": bytes_human(num(get(r, "Size"))),
        })).collect();
        Ok(list_result(out))
    }

    #[tool(description = "Inspect local image metadata.",
           annotations(read_only_hint = true, destructive_hint = false, idempotent_hint = true, open_world_hint = false))]
    async fn image_inspect(&self, Parameters(a): Parameters<ImageArg>) -> Result<Json<Value>, String> {
        let i = valid(&IMAGE_REF, a.image, "Invalid image reference")?;
        let raw = blocking(move || api_json(&format!("/images/{}/json", quote(&i)))).await?;
        Ok(Json(json!({
            "id": get(&raw, "Id"), "repo_tags": get(&raw, "RepoTags"), "repo_digests": get(&raw, "RepoDigests"),
            "created": get(&raw, "Created"), "architecture": get(&raw, "Architecture"), "os": get(&raw, "Os"),
            "size": bytes_human(num(get(&raw, "Size"))),
        })))
    }

    #[tool(description = "Read HEAD and pull eligibility for one allowlisted local repository alias.",
           annotations(read_only_hint = true, destructive_hint = false, idempotent_hint = true, open_world_hint = false))]
    async fn repo_status(&self, Parameters(a): Parameters<RepoArg>) -> Result<CallToolResult, String> {
        let repo = control::alias(a.repo)?;
        runner(json!({"action": "repo_status", "repo": repo}), REPO_STATUS_FIELDS, 8.0).await
    }

    #[tool(description = "Fast-forward one allowlisted clean main checkout from its exact allowlisted origin.",
           annotations(read_only_hint = false, destructive_hint = false, idempotent_hint = false, open_world_hint = false))]
    async fn repo_pull_ff(&self, Parameters(a): Parameters<RepoArg>) -> Result<CallToolResult, String> {
        let repo = control::alias(a.repo)?;
        runner(json!({"action": "repo_pull_ff", "repo": repo}), REPO_PULL_FIELDS, 30.0).await
    }

    #[tool(description = "Read the persistent host MCP port registry and current listener ownership.",
           annotations(read_only_hint = true, destructive_hint = false, idempotent_hint = true, open_world_hint = false))]
    async fn port_registry_status(&self) -> Result<CallToolResult, String> {
        runner(json!({"action": "port_registry_status"}), PORT_FIELDS, 12.0).await
    }

    #[tool(description = "Read state and execution principal for one allowlisted Windows Scheduled Task alias.",
           annotations(read_only_hint = true, destructive_hint = false, idempotent_hint = true, open_world_hint = false))]
    async fn scheduled_task_status(&self, Parameters(a): Parameters<TaskArg>) -> Result<CallToolResult, String> {
        let task = control::alias(a.task)?;
        runner(json!({"action": "scheduled_task_status", "task": task}), TASK_STATUS_FIELDS, 12.0).await
    }

    #[tool(description = "Start, stop, or restart one allowlisted Windows Scheduled Task alias.",
           annotations(read_only_hint = false, destructive_hint = false, idempotent_hint = false, open_world_hint = false))]
    async fn scheduled_task_control(&self, Parameters(a): Parameters<TaskControlArgs>) -> Result<CallToolResult, String> {
        let task = control::alias(a.task)?;
        let operation = match a.operation {
            TaskOperation::Start => "start",
            TaskOperation::Stop => "stop",
            TaskOperation::Restart => "restart",
        };
        runner(json!({"action": "scheduled_task_control", "task": task, "operation": operation}), TASK_CONTROL_FIELDS, 20.0).await
    }

    #[tool(description = "Read status and bounded output for a previously queued host maintenance job.",
           annotations(read_only_hint = true, destructive_hint = false, idempotent_hint = true, open_world_hint = false))]
    async fn maintenance_job_status(&self, Parameters(a): Parameters<JobArg>) -> Result<CallToolResult, String> {
        let job = blocking(move || control::read_job(&control::control_dir(), &a.job_id)).await?;
        Ok(text_result(job.to_string()))
    }

    #[tool(description = "Report host runtime-supervisor state and a bounded, redacted log tail.",
           annotations(read_only_hint = true, destructive_hint = false, idempotent_hint = true, open_world_hint = false))]
    async fn runtime_supervisor_status(&self, Parameters(a): Parameters<SupervisorArgs>) -> Result<CallToolResult, String> {
        let text = blocking(move || Ok(control::runtime_supervisor_status(&control::control_dir(), a.log_tail))).await?;
        Ok(text_result(text))
    }

    #[tool(description = "Read fixed-drive capacity and free space from Windows, without shell access or cleanup.",
           annotations(read_only_hint = true, destructive_hint = false, idempotent_hint = true, open_world_hint = false))]
    async fn host_disk_usage(&self) -> Result<CallToolResult, String> {
        runner(json!({"action": "host_disk_usage"}), DISK_FIELDS, 12.0).await
    }

    #[tool(description = "Read runner health and optionally disk capacity and MCP port registry, each with its own status.",
           annotations(read_only_hint = true, destructive_hint = false, idempotent_hint = true, open_world_hint = false))]
    async fn maintenance_runner_status(&self, Parameters(a): Parameters<RunnerStatusArgs>) -> Result<CallToolResult, String> {
        let text = blocking(move || {
            let dir = control::control_dir();
            let mut payload = control::runner_heartbeat(&dir);
            if a.include_host_checks {
                let checks: [(&str, Value, &[&str]); 2] = [
                    ("disk", json!({"action": "host_disk_usage"}), DISK_FIELDS),
                    ("ports", json!({"action": "port_registry_status"}), PORT_FIELDS),
                ];
                for (name, request, fields) in checks {
                    let result = control::compact_request(&dir, request, fields, 12.0)
                        .ok()
                        .and_then(|t| serde_json::from_str::<Value>(&t).ok())
                        .map(|mut v| {
                            if let Some(m) = v.as_object_mut() {
                                m.shift_remove("error");
                            }
                            v
                        })
                        .unwrap_or_else(|| json!({"status": "unavailable"}));
                    payload[name] = result;
                }
            }
            Ok(payload.to_string())
        }).await?;
        Ok(text_result(text))
    }

    #[tool(description = "Audit health, desired Compose config, image drift and runtime source. Optionally include image usage and digests from the same inventory.",
           annotations(read_only_hint = true, destructive_hint = false, idempotent_hint = true, open_world_hint = false))]
    async fn mcp_deployment_audit(&self, Parameters(a): Parameters<DeploymentAuditArgs>) -> Result<CallToolResult, String> {
        let text = blocking(move || {
            let inv = audit::inventory()?;
            let mut payload = audit::deployment_audit(
                &inv, &audit::desired_state(), &audit::source_audit(), &audit::expected_projects(),
                &audit::fetch_image, audit::now(),
            );
            if a.include_image_usage {
                payload["image_usage"] = audit::image_usage_audit(&inv);
                payload["container_inspect_failures"] = Value::Array(inv.failed.clone());
            }
            Ok(payload.to_string())
        }).await?;
        Ok(text_result(text))
    }

    #[tool(description = "Classify local images by container use and report repository-level superseded hints.

Hints are never declared safe for deletion because an unused local image may still
be an active Dockerfile build-stage/base dependency.",
           annotations(read_only_hint = true, destructive_hint = false, idempotent_hint = true, open_world_hint = false))]
    async fn image_usage_audit(&self) -> Result<CallToolResult, String> {
        let text = blocking(|| Ok(audit::image_usage_audit(&audit::inventory()?).to_string())).await?;
        Ok(text_result(text))
    }

    #[tool(description = "Remove only explicitly requested local image refs that no container uses.",
           annotations(read_only_hint = false, destructive_hint = true, idempotent_hint = false, open_world_hint = false))]
    async fn cleanup_superseded_images(&self, Parameters(a): Parameters<CleanupArgs>) -> Result<CallToolResult, String> {
        let target = writes::cleanup_target(&a.image_refs)?;
        let raw = blocking(move || api_post_json(&target, 180)).await?;
        Ok(text_result(or_empty(raw).to_string()))
    }

    #[tool(description = "Queue a reviewed allowlisted project action; no paths, commands or image refs accepted.",
           annotations(read_only_hint = false, destructive_hint = true, idempotent_hint = false, open_world_hint = false))]
    async fn compose_redeploy(&self, Parameters(a): Parameters<RedeployArgs>) -> Result<CallToolResult, String> {
        let operation = serde_json::to_value(&a.operation).map_err(|e| e.to_string())?;
        let operation = operation.as_str().unwrap_or_default().to_string();
        let Value::Object(job) = writes::redeploy_job(&a.project, &a.services.unwrap_or_default(), &operation)? else {
            unreachable!()
        };
        let job_id = blocking(move || control::write_job(&control::control_dir(), job)).await?;
        Ok(text_result(json!({"job_id": job_id, "status": "queued", "operation": operation}).to_string()))
    }

    #[tool(description = "Remove only stale, unmanaged MCP discovery-probe containers proven by their probe log signature.",
           annotations(read_only_hint = false, destructive_hint = true, idempotent_hint = false, open_world_hint = false))]
    async fn cleanup_stale_mcp_containers(&self, Parameters(a): Parameters<StaleArgs>) -> Result<CallToolResult, String> {
        let (target, minutes) = writes::stale_target(a.min_age_minutes);
        let mut raw = or_empty(blocking(move || api_post_json(&target, 90)).await?);
        let map = raw.as_object_mut().ok_or("Unexpected cleanup response")?;
        map.insert("min_age_minutes".into(), json!(minutes));
        Ok(text_result(raw.to_string()))
    }

    #[tool(description = "Pull a public image. Does not recreate running containers.",
           annotations(read_only_hint = false, destructive_hint = false, idempotent_hint = false, open_world_hint = false))]
    async fn image_pull(&self, Parameters(a): Parameters<ImageArg>) -> Result<Json<Value>, String> {
        let image = valid(&IMAGE_REF, a.image, "Invalid image reference")?;
        let target = writes::pull_target(&image);
        let body = blocking(move || api_post_raw(&target, 180)).await?;
        Ok(Json(json!({"image": image, "status": writes::pull_messages(&body)?})))
    }

    #[tool(description = "Restart an existing container without changing its image or configuration.",
           annotations(read_only_hint = false, destructive_hint = false, idempotent_hint = false, open_world_hint = false))]
    async fn container_restart(&self, Parameters(a): Parameters<RestartArgs>) -> Result<Json<Value>, String> {
        let c = valid(&CONTAINER_REF, a.container, "Invalid container name or ID")?;
        let (target, _) = writes::restart_target(&c, a.timeout_seconds);
        blocking(move || api_post_raw(&target, 90)).await?;
        Ok(Json(json!({"container": c, "restarted": true})))
    }

    #[tool(description = "Delete only dangling unused image layers; tagged images are not targeted.",
           annotations(read_only_hint = false, destructive_hint = true, idempotent_hint = false, open_world_hint = false))]
    async fn image_prune_dangling(&self) -> Result<Json<Value>, String> {
        let raw = or_empty(blocking(|| api_post_json(&writes::prune_target(), 90)).await?);
        Ok(Json(json!({
            "images_deleted": if control::py_truthy(get(&raw, "ImagesDeleted")) { get(&raw, "ImagesDeleted").clone() } else { json!([]) },
            "space_reclaimed": bytes_human(num(get(&raw, "SpaceReclaimed"))),
        })))
    }
}

#[tokio::main(flavor = "current_thread")]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let service = DockerLocal.serve(rmcp::transport::stdio()).await?;
    service.waiting().await?;
    Ok(())
}
