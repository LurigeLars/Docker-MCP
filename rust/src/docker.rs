//! Docker Engine API over the read-only socket proxy, mirroring server.py `_api`/`_json`.

use std::{io::Read, sync::LazyLock, time::Duration};

use regex::Regex;
use serde_json::{Map, Value};

const MAX_OUTPUT: u64 = 512_000;
const TRUNCATED: &[u8] = b"\n...[output truncated]";

static API: LazyLock<String> = LazyLock::new(|| {
    std::env::var("DOCKER_API_URL")
        .unwrap_or_else(|_| "http://host.docker.internal:23750".into())
        .trim_end_matches('/')
        .to_string()
});
static AGENT: LazyLock<ureq::Agent> = LazyLock::new(|| {
    ureq::Agent::config_builder()
        .timeout_global(Some(Duration::from_secs(30)))
        .http_status_as_error(false)
        .build()
        .into()
});

pub static CONTAINER_REF: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"^(?:[A-Za-z0-9][A-Za-z0-9_.-]{0,127}|[a-fA-F0-9]{12,64})$").unwrap()
});
pub static IMAGE_REF: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"^[A-Za-z0-9][A-Za-z0-9._/@:-]{0,511}$").unwrap());
pub static COMPOSE_PROJECT: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$").unwrap());

pub fn valid(re: &Regex, value: String, msg: &str) -> Result<String, String> {
    if re.is_match(&value) { Ok(value) } else { Err(msg.into()) }
}

/// urllib.parse.quote(value, safe=""): validated refs only contain [A-Za-z0-9._/@:-].
pub fn quote(value: &str) -> String {
    value.replace('/', "%2F").replace('@', "%40").replace(':', "%3A")
}

/// Raw GET. Like `_api`, an oversized body is cut and marked rather than rejected.
pub fn api_raw(path: &str) -> Result<Vec<u8>, String> {
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
        body.truncate(MAX_OUTPUT as usize);
        body.extend_from_slice(TRUNCATED);
    }
    Ok(body)
}

pub fn api_json(path: &str) -> Result<Value, String> {
    let body = api_raw(path)?;
    if body.is_empty() {
        return Ok(Value::Null);
    }
    serde_json::from_slice(&body).map_err(|e| format!("Invalid Docker API JSON: {e}"))
}

pub async fn blocking<T: Send + 'static>(
    f: impl FnOnce() -> Result<T, String> + Send + 'static,
) -> Result<T, String> {
    tokio::task::spawn_blocking(f).await.map_err(|e| e.to_string())?
}

pub fn obj(v: &Value) -> &Map<String, Value> {
    static EMPTY: LazyLock<Map<String, Value>> = LazyLock::new(Map::new);
    v.as_object().unwrap_or(&EMPTY)
}
pub fn get<'a>(v: &'a Value, key: &str) -> &'a Value {
    obj(v).get(key).unwrap_or(&Value::Null)
}
pub fn num(v: &Value) -> f64 {
    v.as_f64().unwrap_or(0.0)
}
pub fn round2(v: f64) -> f64 {
    (v * 100.0).round() / 100.0
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn refs_and_quoting() {
        assert_eq!(quote("ghcr.io/a/b:1@sha256:x"), "ghcr.io%2Fa%2Fb%3A1%40sha256%3Ax");
        assert!(CONTAINER_REF.is_match("dockerlocal-mcp-http"));
        assert!(!CONTAINER_REF.is_match("../etc"));
        assert!(!IMAGE_REF.is_match("-bad"));
        assert!(COMPOSE_PROJECT.is_match("dockerlocal-public"));
        assert!(!COMPOSE_PROJECT.is_match("a b"));
    }
}
