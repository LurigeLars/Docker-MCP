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

/// urllib.parse.urlencode for one value (quote_plus): only unreserved bytes stay literal.
pub fn qs(value: &str) -> String {
    value
        .bytes()
        .map(|b| match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'_' | b'.' | b'-' | b'~' => (b as char).to_string(),
            b' ' => "+".into(),
            _ => format!("%{b:02X}"),
        })
        .collect()
}

/// Raw GET. Like `_api`, an oversized body is cut and marked rather than rejected.
pub fn api_raw(path: &str) -> Result<Vec<u8>, String> {
    request_at(&API, "GET", path, 30)
}

/// POST with an empty body, as `_api` sends it; the proxy rejects any request body.
pub fn api_post_raw(path: &str, timeout_secs: u64) -> Result<Vec<u8>, String> {
    request_at(&API, "POST", path, timeout_secs)
}

pub fn api_post_json(path: &str, timeout_secs: u64) -> Result<Value, String> {
    parse_json(api_post_raw(path, timeout_secs)?)
}

fn request_at(base: &str, method: &str, path: &str, timeout_secs: u64) -> Result<Vec<u8>, String> {
    let url = format!("{base}{path}");
    let timeout = Some(Duration::from_secs(timeout_secs));
    let sent = if method == "POST" {
        AGENT.post(&url).config().timeout_global(timeout).build()
            .header("Accept", "application/json")
            .header("User-Agent", "DockerLocal-MCP/1.0")
            .send_empty()
    } else {
        AGENT.get(&url).config().timeout_global(timeout).build()
            .header("Accept", "application/json")
            .header("User-Agent", "DockerLocal-MCP/1.0")
            .call()
    };
    let mut resp = sent.map_err(|e| format!("Docker API unavailable: {e}"))?;
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
    parse_json(api_raw(path)?)
}

fn parse_json(body: Vec<u8>) -> Result<Value, String> {
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

    #[test]
    fn qs_matches_python_urlencode() {
        // Expected strings produced by urllib.parse.urlencode and accepted by proxy.allowed().
        assert_eq!(qs(r#"{"dangling":["true"]}"#), "%7B%22dangling%22%3A%5B%22true%22%5D%7D");
        assert_eq!(qs("ghcr.io/a/b:1@sha256:bb"), "ghcr.io%2Fa%2Fb%3A1%40sha256%3Abb");
        assert_eq!(qs("a b~c"), "a+b~c");
    }

    /// One request against a fake proxy: method, target, empty body, no chunked encoding.
    #[test]
    fn post_sends_an_empty_unchunked_body() {
        use std::io::{BufRead, BufReader, Write};
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let base = format!("http://{}", listener.local_addr().unwrap());
        let server = std::thread::spawn(move || {
            let (stream, _) = listener.accept().unwrap();
            let mut reader = BufReader::new(stream.try_clone().unwrap());
            let mut head = Vec::new();
            loop {
                let mut line = String::new();
                reader.read_line(&mut line).unwrap();
                if line == "\r\n" || line.is_empty() { break; }
                head.push(line.trim_end().to_string());
            }
            let body = br#"{"ok":true}"#;
            let mut stream = stream;
            write!(stream, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n", body.len()).unwrap();
            stream.write_all(body).unwrap();
            head
        });
        let body = request_at(&base, "POST", "/images/prune?filters=%7B%7D", 5).unwrap();
        let head = server.join().unwrap();
        assert_eq!(body, br#"{"ok":true}"#);
        assert_eq!(head[0], "POST /images/prune?filters=%7B%7D HTTP/1.1");
        let lower: Vec<String> = head.iter().map(|h| h.to_ascii_lowercase()).collect();
        assert!(!lower.iter().any(|h| h.starts_with("transfer-encoding")));
        assert!(lower.iter().all(|h| !h.starts_with("content-length") || h == "content-length: 0"));
    }
}
