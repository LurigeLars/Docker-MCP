//! Host maintenance-runner protocol over the /control mount, mirroring server.py
//! (`_write_job`, `_read_job`, `_runner_request`, `_compact_runner_request`,
//! `runtime_supervisor_status`, `_runner_heartbeat`).

use std::{
    fs,
    path::{Path, PathBuf},
    sync::LazyLock,
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};

use regex::Regex;
use serde_json::{Map, Value, json};

use crate::text::redact;

static JOB_ID: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"^[a-f0-9]{32}$").unwrap());
static ALIAS: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$").unwrap());
const OUTPUT_KEEP_CHARS: usize = 16_000;

pub fn control_dir() -> PathBuf {
    PathBuf::from(std::env::var("DOCKERLOCAL_CONTROL_DIR").unwrap_or_else(|_| "/control".into()))
}

pub fn alias(value: String) -> Result<String, String> {
    if ALIAS.is_match(&value) { Ok(value) } else { Err("Invalid maintenance alias".into()) }
}

fn now_unix() -> i64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |d| d.as_secs() as i64)
}

/// Python `int(x or 0)` for the timestamp fields the runner writes.
fn py_int_or_zero(v: Option<&Value>) -> Result<i64, String> {
    match v {
        None | Some(Value::Null) => Ok(0),
        Some(Value::Bool(b)) => Ok(*b as i64),
        Some(Value::Number(n)) => n
            .as_i64()
            .or_else(|| n.as_f64().filter(|f| f.is_finite()).map(|f| f.trunc() as i64))
            .ok_or_else(|| "invalid integer".into()),
        Some(Value::String(s)) if s.is_empty() => Ok(0),
        Some(Value::String(s)) => s.trim().parse::<i64>().map_err(|e| e.to_string()),
        Some(Value::Array(a)) if a.is_empty() => Ok(0),
        Some(Value::Object(o)) if o.is_empty() => Ok(0),
        Some(_) => Err("invalid integer".into()),
    }
}

/// Python `str(x or "")`-style status read.
fn str_field<'a>(map: &'a Map<String, Value>, key: &str) -> &'a str {
    map.get(key).and_then(Value::as_str).unwrap_or("")
}

/// Python str.splitlines() boundaries (not just \n).
fn py_splitlines(text: &str) -> Vec<&str> {
    let mut lines = Vec::new();
    let mut start = 0;
    let mut chars = text.char_indices().peekable();
    while let Some((i, c)) = chars.next() {
        let is_break = matches!(c, '\n' | '\r' | '\x0b' | '\x0c' | '\x1c' | '\x1d' | '\x1e' | '\u{85}' | '\u{2028}' | '\u{2029}');
        if is_break {
            lines.push(&text[start..i]);
            let mut end = i + c.len_utf8();
            if c == '\r' {
                if let Some(&(j, '\n')) = chars.peek() {
                    chars.next();
                    end = j + 1;
                }
            }
            start = end;
        }
    }
    if start < text.len() {
        lines.push(&text[start..]);
    }
    lines
}

fn strip_bom(bytes: &[u8]) -> &[u8] {
    bytes.strip_prefix(b"\xEF\xBB\xBF").unwrap_or(bytes)
}

pub fn write_job(dir: &Path, payload: Map<String, Value>) -> Result<String, String> {
    let job_id = uuid::Uuid::new_v4().simple().to_string();
    let requests = dir.join("requests");
    fs::create_dir_all(&requests).map_err(|e| e.to_string())?;
    let mut body = Map::new();
    body.insert("job_id".into(), json!(job_id));
    body.insert("created_unix".into(), json!(now_unix()));
    body.extend(payload);
    let temp = requests.join(format!(".{job_id}.tmp"));
    fs::write(&temp, Value::Object(body).to_string()).map_err(|e| e.to_string())?;
    fs::rename(&temp, requests.join(format!("{job_id}.json"))).map_err(|e| e.to_string())?;
    Ok(job_id)
}

pub fn read_job(dir: &Path, job_id: &str) -> Result<Value, String> {
    if !JOB_ID.is_match(job_id) {
        return Err("Invalid job id".into());
    }
    let result = dir.join("results").join(format!("{job_id}.json"));
    if result.exists() {
        let text = fs::read_to_string(&result).map_err(|e| e.to_string())?;
        let mut data: Value = serde_json::from_str(&text).map_err(|e| e.to_string())?;
        if let Some(map) = data.as_object_mut() {
            if let Some(Value::String(out)) = map.get("output") {
                let n = out.chars().count();
                if n > OUTPUT_KEEP_CHARS {
                    let tail: String = out.chars().skip(n - OUTPUT_KEEP_CHARS).collect();
                    map.insert("output".into(), json!(tail));
                    map.insert("output_truncated".into(), json!(true));
                }
            }
        }
        return Ok(data);
    }
    let status = if dir.join("processing").join(format!("{job_id}.json")).exists() {
        "running"
    } else if dir.join("requests").join(format!("{job_id}.json")).exists() {
        "queued"
    } else {
        "unknown"
    };
    Ok(json!({ "job_id": job_id, "status": status }))
}

fn runner_request(dir: &Path, payload: Map<String, Value>, timeout: Duration) -> Result<Value, String> {
    let job_id = write_job(dir, payload)?;
    let deadline = Instant::now() + timeout;
    while Instant::now() < deadline {
        let result = read_job(dir, &job_id)?;
        if matches!(result.get("status").and_then(Value::as_str), Some("succeeded" | "failed")) {
            return Ok(result);
        }
        std::thread::sleep(Duration::from_millis(100));
    }
    Ok(json!({ "job_id": job_id, "status": "timeout" }))
}

/// Mirrors `_compact_runner_request`: status, the whitelisted fields, error, timeout job id.
pub fn compact_request(
    dir: &Path,
    payload: Value,
    fields: &[&str],
    timeout_seconds: f64,
) -> Result<String, String> {
    let Value::Object(payload) = payload else { unreachable!() };
    let raw = runner_request(dir, payload, Duration::from_secs_f64(timeout_seconds))?;
    Ok(compact(&raw, fields).to_string())
}

fn compact(raw: &Value, fields: &[&str]) -> Value {
    let empty = Map::new();
    let raw = raw.as_object().unwrap_or(&empty);
    let mut out = Map::new();
    out.insert("status".into(), raw.get("status").cloned().unwrap_or(json!("unknown")));
    for field in fields {
        if let Some(v) = raw.get(*field) {
            out.insert((*field).into(), v.clone());
        }
    }
    if let Some(err) = raw.get("error").filter(|e| py_truthy(e)) {
        out.insert("error".into(), json!(py_str(err)));
    }
    if out.get("status") == Some(&json!("timeout")) {
        if let Some(id) = raw.get("job_id").filter(|v| py_truthy(v)) {
            out.insert("job_id".into(), id.clone());
        }
    }
    Value::Object(out)
}

fn py_truthy(v: &Value) -> bool {
    match v {
        Value::Null => false,
        Value::Bool(b) => *b,
        Value::Number(n) => n.as_f64() != Some(0.0),
        Value::String(s) => !s.is_empty(),
        Value::Array(a) => !a.is_empty(),
        Value::Object(o) => !o.is_empty(),
    }
}

/// Runner errors are strings; any other type is rendered as JSON (Python would use repr).
fn py_str(v: &Value) -> String {
    match v {
        Value::String(s) => s.clone(),
        other => other.to_string(),
    }
}

pub fn runtime_supervisor_status(dir: &Path, log_tail: i64) -> String {
    let log_tail = log_tail.clamp(1, 200) as usize;
    let mut payload = Map::new();
    payload.insert("status".into(), json!("missing"));
    payload.insert("state".into(), Value::Null);
    payload.insert("log_tail".into(), json!([]));

    let state_path = dir.join("runtime-supervisor-state.json");
    if state_path.exists() {
        let parsed = fs::read(&state_path)
            .map_err(|e| e.to_string())
            .and_then(|b| String::from_utf8(strip_bom(&b).to_vec()).map_err(|e| e.to_string()))
            .and_then(|t| serde_json::from_str::<Value>(&t).map_err(|e| e.to_string()))
            .and_then(|state| {
                let map = state.as_object().ok_or("state is not an object")?;
                let updated = py_int_or_zero(map.get("updated_unix"))?;
                let status = str_field(map, "status").to_string();
                Ok((state, updated, status))
            });
        match parsed {
            Ok((state, updated, status)) => {
                let age = (updated != 0).then(|| (now_unix() - updated).max(0));
                payload.insert("state".into(), state);
                payload.insert("age_seconds".into(), json!(age));
                let running = age.is_some_and(|a| a <= 30) && !matches!(status.as_str(), "stopped" | "failed");
                payload.insert("status".into(), json!(if running { "running" } else { "stale" }));
            }
            Err(e) => {
                payload.insert("status".into(), json!("invalid"));
                payload.insert("state_error".into(), json!(e));
            }
        }
    }

    let log_path = dir.join("runtime-supervisor.log");
    if log_path.exists() {
        match fs::read(&log_path) {
            Ok(bytes) => {
                let text = String::from_utf8_lossy(strip_bom(&bytes));
                let lines = py_splitlines(&text);
                let tail: Vec<Value> = lines[lines.len().saturating_sub(log_tail)..]
                    .iter()
                    .map(|l| json!(redact(l)))
                    .collect();
                payload.insert("log_tail".into(), Value::Array(tail));
            }
            Err(e) => {
                payload.insert("log_error".into(), json!(e.to_string()));
            }
        }
    }
    Value::Object(payload).to_string()
}

pub fn runner_heartbeat(dir: &Path) -> Value {
    let path = dir.join("runner-heartbeat.json");
    if !path.exists() {
        return json!({ "status": "missing" });
    }
    // Python reads strict UTF-8 here (no BOM stripping), so a BOM is invalid.
    let parsed = fs::read_to_string(&path)
        .map_err(|e| e.to_string())
        .and_then(|t| serde_json::from_str::<Value>(&t).map_err(|e| e.to_string()))
        .and_then(|data| {
            let map = data.as_object().ok_or("heartbeat is not an object")?;
            let updated = py_int_or_zero(map.get("updated_unix"))?;
            Ok((data, updated))
        });
    let Ok((data, updated)) = parsed else { return json!({ "status": "invalid" }) };
    let map = data.as_object().cloned().unwrap_or_default();
    let age = (updated != 0).then(|| (now_unix() - updated).max(0));
    let raw_status = str_field(&map, "status");
    let job_id = str_field(&map, "job_id");
    let processing = !job_id.is_empty()
        && JOB_ID.is_match(job_id)
        && dir.join("processing").join(format!("{job_id}.json")).exists();
    let status = if raw_status == "busy" && processing && age.is_some_and(|a| a <= 3600) {
        "busy"
    } else if raw_status == "running" && age.is_some_and(|a| a <= 10) {
        "running"
    } else {
        "stale"
    };
    let mut payload = Map::new();
    payload.insert("status".into(), json!(status));
    payload.insert("age_seconds".into(), json!(age));
    payload.insert("pid".into(), map.get("pid").cloned().unwrap_or(Value::Null));
    if status == "busy" {
        payload.insert("job_id".into(), json!(job_id));
        payload.insert("project".into(), map.get("project").cloned().unwrap_or(Value::Null));
    }
    Value::Object(payload)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tempdir(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("dl-control-{name}-{}", uuid::Uuid::new_v4().simple()));
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn splitlines_matches_python() {
        assert_eq!(py_splitlines("a\r\nb\rc\nd\u{2028}e\x0cf"), vec!["a", "b", "c", "d", "e", "f"]);
        assert_eq!(py_splitlines("x\n"), vec!["x"]);
        assert_eq!(py_splitlines(""), Vec::<&str>::new());
        assert_eq!(py_splitlines("\n\n"), vec!["", ""]);
    }

    #[test]
    fn py_int_rules() {
        assert_eq!(py_int_or_zero(None), Ok(0));
        assert_eq!(py_int_or_zero(Some(&json!(""))), Ok(0));
        assert_eq!(py_int_or_zero(Some(&json!(12.9))), Ok(12));
        assert_eq!(py_int_or_zero(Some(&json!(" 42 "))), Ok(42));
        assert!(py_int_or_zero(Some(&json!("4.2"))).is_err());
    }

    #[test]
    fn job_files_round_trip_and_truncate() {
        let dir = tempdir("jobs");
        let mut payload = Map::new();
        payload.insert("action".into(), json!("repo_status"));
        let id = write_job(&dir, payload).unwrap();
        let written: Value = serde_json::from_str(&fs::read_to_string(dir.join("requests").join(format!("{id}.json"))).unwrap()).unwrap();
        assert_eq!(written["job_id"], json!(id));
        assert_eq!(written["action"], json!("repo_status"));
        assert!(written["created_unix"].as_i64().unwrap() > 0);
        assert_eq!(read_job(&dir, &id).unwrap()["status"], "queued");
        assert!(read_job(&dir, "../etc").is_err());

        fs::create_dir_all(dir.join("results")).unwrap();
        let long = "é".repeat(OUTPUT_KEEP_CHARS + 5);
        fs::write(dir.join("results").join(format!("{id}.json")), json!({"status": "succeeded", "output": long}).to_string()).unwrap();
        let done = read_job(&dir, &id).unwrap();
        assert_eq!(done["output"].as_str().unwrap().chars().count(), OUTPUT_KEEP_CHARS);
        assert_eq!(done["output_truncated"], json!(true));
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn compact_keeps_whitelist_error_and_timeout_id() {
        let raw = json!({"status": "succeeded", "repo": "x", "secret_field": 1, "error": ""});
        assert_eq!(compact(&raw, &["repo"]), json!({"status": "succeeded", "repo": "x"}));
        let raw = json!({"status": "failed", "error": {"code": 2}});
        assert_eq!(compact(&raw, &[]), json!({"status": "failed", "error": "{\"code\":2}"}));
        let raw = json!({"job_id": "abc", "status": "timeout"});
        assert_eq!(compact(&raw, &[]), json!({"status": "timeout", "job_id": "abc"}));
        assert_eq!(compact(&json!({}), &[]), json!({"status": "unknown"}));
    }

    #[test]
    fn heartbeat_states() {
        let dir = tempdir("hb");
        assert_eq!(runner_heartbeat(&dir), json!({"status": "missing"}));
        fs::write(dir.join("runner-heartbeat.json"), "\u{feff}{}").unwrap();
        assert_eq!(runner_heartbeat(&dir), json!({"status": "invalid"}));
        fs::write(dir.join("runner-heartbeat.json"), "[1]").unwrap();
        assert_eq!(runner_heartbeat(&dir), json!({"status": "invalid"}));
        fs::write(dir.join("runner-heartbeat.json"), json!({"status": "running", "updated_unix": now_unix(), "pid": 7}).to_string()).unwrap();
        assert_eq!(runner_heartbeat(&dir)["status"], "running");
        fs::write(dir.join("runner-heartbeat.json"), json!({"status": "running", "updated_unix": now_unix() - 60}).to_string()).unwrap();
        assert_eq!(runner_heartbeat(&dir)["status"], "stale");
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn supervisor_status_reads_and_redacts() {
        let dir = tempdir("sup");
        assert_eq!(serde_json::from_str::<Value>(&runtime_supervisor_status(&dir, 40)).unwrap(),
                   json!({"status": "missing", "state": null, "log_tail": []}));
        fs::write(dir.join("runtime-supervisor-state.json"), format!("\u{feff}{}", json!({"status": "ok", "updated_unix": now_unix()}))).unwrap();
        fs::write(dir.join("runtime-supervisor.log"), "one\r\ntoken=abc\nthree\n").unwrap();
        let v: Value = serde_json::from_str(&runtime_supervisor_status(&dir, 2)).unwrap();
        assert_eq!(v["status"], "running");
        assert_eq!(v["log_tail"], json!(["token=[REDACTED]", "three"]));
        fs::write(dir.join("runtime-supervisor-state.json"), "{not json").unwrap();
        let v: Value = serde_json::from_str(&runtime_supervisor_status(&dir, 2)).unwrap();
        assert_eq!(v["status"], "invalid");
        assert!(v["state"].is_null() && v.get("state_error").is_some());
        fs::remove_dir_all(dir).unwrap();
    }
}
