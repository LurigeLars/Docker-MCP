//! DockerLocal MCP in Rust, ported tool by tool from server.py with parity checks.
//! Batch 1: read-only Docker API tools. Not wired into any deployment yet.

mod docker;
mod text;

use rmcp::{
    ServiceExt,
    handler::server::wrapper::{Json, Parameters},
    model::{CallToolResult, ContentBlock},
    schemars, tool, tool_router,
};
use serde::Deserialize;
use serde_json::{Map, Value, json};

use docker::{
    COMPOSE_PROJECT, CONTAINER_REF, IMAGE_REF, api_json, api_raw, blocking, get, num, obj, quote,
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
}

#[tokio::main(flavor = "current_thread")]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let service = DockerLocal.serve(rmcp::transport::stdio()).await?;
    service.waiting().await?;
    Ok(())
}
