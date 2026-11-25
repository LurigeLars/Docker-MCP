//! Research prototype: the five representative read-only DockerLocal tools over stdio.
//! Output shapes mirror server.py so a parity script can diff them. Not deployed.

use std::{io::Read, sync::LazyLock, time::Duration};

use regex_lite::Regex;
use rmcp::{
    ServiceExt,
    handler::server::wrapper::{Json, Parameters},
    model::{CallToolResult, ContentBlock},
    schemars, tool, tool_router,
};
use serde::Deserialize;
use serde_json::{Map, Value, json};

const MAX_OUTPUT: u64 = 512_000;
static API: LazyLock<String> = LazyLock::new(|| {
    std::env::var("DOCKER_API_URL")
        .unwrap_or_else(|_| "http://host.docker.internal:23750".into())
        .trim_end_matches('/')
        .to_string()
});
static CONTAINER_REF: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"^(?:[A-Za-z0-9][A-Za-z0-9_.-]{0,127}|[a-fA-F0-9]{12,64})$").unwrap()
});
static IMAGE_REF: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"^[A-Za-z0-9][A-Za-z0-9._/@:-]{0,511}$").unwrap());
static AGENT: LazyLock<ureq::Agent> = LazyLock::new(|| {
    ureq::Agent::config_builder()
        .timeout_global(Some(Duration::from_secs(30)))
        .http_status_as_error(false)
        .build()
        .into()
});

fn quote(value: &str) -> String {
    // Same contract as urllib.parse.quote(value, safe=""): validated refs only contain
    // [A-Za-z0-9._/@:-], so only '/', '@' and ':' need escaping.
    value.replace('/', "%2F").replace('@', "%40").replace(':', "%3A")
}

fn api_json(path: &str) -> Result<Value, String> {
    let url = format!("{}{}", *API, path);
    let mut resp = AGENT
        .get(&url)
        .header("Accept", "application/json")
        .header("User-Agent", "DockerLocal-MCP/1.0")
        .call()
        .map_err(|e| format!("Docker API unavailable: {e}"))?;
    let status = resp.status().as_u16();
    let mut body = Vec::new();
    resp.body_mut()
        .as_reader()
        .take(MAX_OUTPUT + 1)
        .read_to_end(&mut body)
        .map_err(|e| format!("Docker API unavailable: {e}"))?;
    if !(200..300).contains(&status) {
        body.truncate(16_384);
        return Err(format!("Docker API HTTP {status}: {}", String::from_utf8_lossy(&body)));
    }
    if body.len() as u64 > MAX_OUTPUT {
        return Err("Docker API response exceeded the output limit".into());
    }
    if body.is_empty() {
        return Ok(Value::Null);
    }
    serde_json::from_slice(&body).map_err(|e| format!("Invalid Docker API JSON: {e}"))
}

fn bytes_human(value: f64) -> String {
    let units = ["B", "KiB", "MiB", "GiB", "TiB"];
    let mut v = value;
    for (i, unit) in units.iter().enumerate() {
        if v.abs() < 1024.0 || i == units.len() - 1 {
            return format!("{v:.1} {unit}");
        }
        v /= 1024.0;
    }
    unreachable!()
}

fn obj(v: &Value) -> &Map<String, Value> {
    static EMPTY: LazyLock<Map<String, Value>> = LazyLock::new(Map::new);
    v.as_object().unwrap_or(&EMPTY)
}
fn get<'a>(v: &'a Value, key: &str) -> &'a Value {
    obj(v).get(key).unwrap_or(&Value::Null)
}
fn num(v: &Value) -> f64 {
    v.as_f64().unwrap_or(0.0)
}
fn round2(v: f64) -> f64 {
    (v * 100.0).round() / 100.0
}

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
struct ImageArg {
    image: String,
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
        let out: Vec<Value> = rows.as_array().into_iter().flatten().map(|r| {
            json!({
                "id": get(r, "Id"), "names": get(r, "Names"), "image": get(r, "Image"),
                "image_id": get(r, "ImageID"), "state": get(r, "State"), "status": get(r, "Status"),
                "ports": get(r, "Ports"),
                "networks": obj(get(get(r, "NetworkSettings"), "Networks")).keys().collect::<Vec<_>>(),
            })
        }).collect();
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
        let user = get(config, "User").as_str().unwrap_or("");
        Ok(Json(json!({
            "id": get(&raw, "Id"),
            "name": get(&raw, "Name").as_str().unwrap_or("").trim_start_matches('/'),
            "image": get(config, "Image"), "image_id": get(&raw, "Image"),
            "created": get(&raw, "Created"), "platform": get(&raw, "Platform"),
            "configured_user": user, "restart_count": get(&raw, "RestartCount"),
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

    #[tool(description = "List local Docker images.",
           annotations(read_only_hint = true, destructive_hint = false, idempotent_hint = true, open_world_hint = false))]
    async fn images_list(&self) -> Result<CallToolResult, String> {
        let rows = blocking(|| api_json("/images/json?all=0")).await?;
        let out: Vec<Value> = rows.as_array().into_iter().flatten().map(|r| json!({
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

/// FastMCP's list contract: text is the bare array, structured content wraps it in "result".
fn list_result(rows: Vec<Value>) -> CallToolResult {
    let text = Value::Array(rows.clone()).to_string();
    let mut result = CallToolResult::structured(json!({ "result": rows }));
    result.content = vec![ContentBlock::text(text)];
    result
}

fn valid(re: &Regex, value: String, msg: &str) -> Result<String, String> {
    if re.is_match(&value) { Ok(value) } else { Err(msg.into()) }
}

async fn blocking<F: FnOnce() -> Result<Value, String> + Send + 'static>(f: F) -> Result<Value, String> {
    tokio::task::spawn_blocking(f).await.map_err(|e| e.to_string())?
}

#[tokio::main(flavor = "current_thread")]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let service = DockerLocal.serve(rmcp::transport::stdio()).await?;
    service.waiting().await?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn helpers_match_python() {
        assert_eq!(bytes_human(0.0), "0.0 B");
        assert_eq!(bytes_human(1536.0), "1.5 KiB");
        assert_eq!(bytes_human(5.0 * 1024f64.powi(5)), "5120.0 TiB");
        assert_eq!(quote("ghcr.io/a/b:1@sha256:x"), "ghcr.io%2Fa%2Fb%3A1%40sha256%3Ax");
        assert!(CONTAINER_REF.is_match("dockerlocal-mcp-http"));
        assert!(!CONTAINER_REF.is_match("../etc"));
        assert!(!IMAGE_REF.is_match("-bad"));
    }
}
