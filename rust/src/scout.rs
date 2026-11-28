//! Docker Scout tools, mirroring server.py (`_read_runtime_secret`, `_assert_scout_image_size`,
//! `_scout` and the six `scout_*` tools). The static docker-scout binary ships in the same image.

use std::{
    io::Read,
    path::{Path, PathBuf},
    process::{Command, Stdio},
    sync::{LazyLock, Mutex},
    time::{Duration, Instant},
};

use regex::Regex;
use serde_json::Value;

use crate::control::py_int_or_zero;
use crate::docker::{api_json, quote};
use crate::text::bytes_human;

const SCOUT_BIN: &str = "/usr/local/bin/docker-scout";
const MAX_OUTPUT_CHARS: usize = 512_000;
const ERROR_TAIL_CHARS: usize = 12_000;
pub const SEVERITIES: [&str; 5] = ["critical", "high", "medium", "low", "unspecified"];
static PACKAGE_TYPE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"^[A-Za-z0-9_.+-]{1,40}$").unwrap());
// One Scout job at a time keeps peak scratch usage bounded, as in server.py.
static SCOUT_LOCK: Mutex<()> = Mutex::new(());

fn env_flag(name: &str) -> bool {
    matches!(std::env::var(name).unwrap_or_default().trim().to_lowercase().as_str(), "1" | "true" | "yes")
}

fn max_image_bytes() -> i64 {
    let raw = std::env::var("DOCKER_SCOUT_MAX_IMAGE_BYTES").unwrap_or_default();
    raw.trim().parse::<i64>().unwrap_or(0).max(0)
}

fn read_secret(path: &str) -> Option<String> {
    let value = std::fs::read_to_string(path).ok()?.trim().to_string();
    (!value.is_empty()).then_some(value)
}

/// `_assert_scout_image_size`: refuse remote scans of images above the configured limit.
pub fn assert_image_size(image: &str) -> Result<(), String> {
    let limit = max_image_bytes();
    if limit <= 0 {
        return Ok(());
    }
    let raw = api_json(&format!("/images/{}/json", quote(image)))?;
    let size = py_int_or_zero(raw.get("Size")).unwrap_or(0);
    if size > limit {
        return Err(format!(
            "Docker Scout remote scan refused: {image} is {}, above the configured {} limit. \
             Use scout_full_scan for host-based scanning instead.",
            bytes_human(size as f64),
            bytes_human(limit as f64)
        ));
    }
    Ok(())
}

/// The environment for one Scout run: Hub credentials only from tmpfs files, never inherited.
fn scout_env() -> Vec<(String, String)> {
    let mut env: Vec<(String, String)> = std::env::vars()
        .filter(|(k, _)| k != "DOCKER_SCOUT_HUB_USER" && k != "DOCKER_SCOUT_HUB_PASSWORD")
        .collect();
    let file = |name: &str, default: &str| std::env::var(name).unwrap_or_else(|_| default.into());
    if let Some(user) = read_secret(&file("DOCKER_SCOUT_HUB_USER_FILE", "/run/dockerlocal-secrets/scout_hub_user")) {
        env.push(("DOCKER_SCOUT_HUB_USER".into(), user));
    }
    if let Some(password) =
        read_secret(&file("DOCKER_SCOUT_HUB_PASSWORD_FILE", "/run/dockerlocal-secrets/scout_hub_password"))
    {
        env.push(("DOCKER_SCOUT_HUB_PASSWORD".into(), password));
    }
    for (key, value) in [
        ("DOCKER_HOST", "tcp://host.docker.internal:23750"),
        ("DOCKER_SCOUT_NEW_VERSION_WARN", "false"),
        ("NO_COLOR", "1"),
    ] {
        if !env.iter().any(|(k, _)| k == key) {
            env.push((key.into(), value.into()));
        }
    }
    env
}

/// A per-job cache directory removed when dropped (TemporaryDirectory equivalent).
struct TempDir(PathBuf);
impl TempDir {
    fn new(parent: &Path) -> Result<Self, String> {
        let dir = parent.join(format!("docker-scout-{}", uuid::Uuid::new_v4().simple()));
        std::fs::create_dir(&dir).map_err(|e| e.to_string())?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o700)).map_err(|e| e.to_string())?;
        }
        Ok(Self(dir))
    }
}
impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

/// `_scout`: run docker-scout with merged stdout/stderr, a timeout, bounded output and
/// the last 12 000 characters in the error when it fails.
pub fn run(args: &[String], timeout: Duration) -> Result<String, String> {
    run_binary(SCOUT_BIN, args, timeout, scout_env())
}

fn run_binary(bin: &str, args: &[String], timeout: Duration, mut env: Vec<(String, String)>) -> Result<String, String> {
    let _guard = SCOUT_LOCK.lock().unwrap_or_else(|p| p.into_inner());
    let _cache = if env_flag("DOCKER_SCOUT_EPHEMERAL_CACHE") {
        let dir = TempDir::new(Path::new("/tmp"))?;
        env.retain(|(k, _)| k != "DOCKER_SCOUT_CACHE_DIR");
        env.push(("DOCKER_SCOUT_CACHE_DIR".into(), dir.0.to_string_lossy().into_owned()));
        Some(dir)
    } else {
        if !env.iter().any(|(k, _)| k == "DOCKER_SCOUT_CACHE_DIR") {
            env.push(("DOCKER_SCOUT_CACHE_DIR".into(), "/tmp/docker-scout".into()));
        }
        None
    };

    // stderr=STDOUT: one pipe for both, so the text keeps Scout's own interleaving.
    let (mut reader, writer) = std::io::pipe().map_err(|e| e.to_string())?;
    let writer_err = writer.try_clone().map_err(|e| e.to_string())?;
    let mut child = Command::new(bin)
        .args(args)
        .env_clear()
        .envs(env)
        .stdin(Stdio::null())
        .stdout(writer)
        .stderr(writer_err)
        .spawn()
        .map_err(|e| format!("Docker Scout could not start: {e}"))?;
    let collector = std::thread::spawn(move || {
        let mut out = Vec::new();
        let _ = reader.read_to_end(&mut out);
        out
    });

    let deadline = Instant::now() + timeout;
    let status = loop {
        match child.try_wait().map_err(|e| e.to_string())? {
            Some(status) => break status,
            None if Instant::now() >= deadline => {
                let _ = child.kill();
                let _ = child.wait();
                return Err(format!("Docker Scout timed out after {} seconds", timeout.as_secs()));
            }
            None => std::thread::sleep(Duration::from_millis(50)),
        }
    };
    let bytes = collector.join().unwrap_or_default();
    let mut output = String::from_utf8_lossy(&bytes).into_owned();
    if output.chars().count() > MAX_OUTPUT_CHARS {
        output = output.chars().take(MAX_OUTPUT_CHARS).collect::<String>() + "\n...[output truncated]";
    }
    if !status.success() {
        let code = status.code().unwrap_or(-1);
        let n = output.chars().count();
        let tail: String = output.chars().skip(n.saturating_sub(ERROR_TAIL_CHARS)).collect();
        return Err(format!("Docker Scout failed ({code}):\n{tail}"));
    }
    Ok(output)
}

/// `scout_cves` arguments (server.py order), after severity validation.
pub fn cves_args(image: &str, severity: &[String], only_fixed: bool, cisa_kev: bool) -> Result<Vec<String>, String> {
    let mut args: Vec<String> = ["cves", "--format", "markdown"].map(String::from).to_vec();
    if !severity.is_empty() {
        let normalized: Vec<String> = severity.iter().map(|s| s.to_lowercase()).collect();
        let bad: Vec<&str> = normalized.iter().map(String::as_str).filter(|s| !SEVERITIES.contains(s)).collect();
        if !bad.is_empty() {
            return Err(format!("Unsupported severity: {}", bad.join(", ")));
        }
        args.extend(["--only-severity".into(), normalized.join(",")]);
    }
    if only_fixed {
        args.push("--only-fixed".into());
    }
    if cisa_kev {
        args.push("--only-cisa-kev".into());
    }
    args.push(format!("local://{image}"));
    Ok(args)
}

/// `scout_full_scan` job payload: severities lowercased, validated and deduplicated in order.
pub fn full_scan_job(image: &str, severity: &[String], only_fixed: bool, cisa_kev: bool) -> Result<Value, String> {
    let mut normalized: Vec<String> = Vec::new();
    for item in severity {
        let value = item.to_lowercase();
        if !SEVERITIES.contains(&value.as_str()) {
            return Err(format!("Unsupported severity: {value}"));
        }
        if !normalized.contains(&value) {
            normalized.push(value);
        }
    }
    Ok(serde_json::json!({
        "action": "scout_full_scan", "image": image, "severity": normalized,
        "only_fixed": only_fixed, "cisa_kev": cisa_kev,
    }))
}

pub fn sbom_args(image: &str, package_type: Option<&str>) -> Result<Vec<String>, String> {
    let mut args: Vec<String> = ["sbom", "--format", "list"].map(String::from).to_vec();
    if let Some(kind) = package_type.filter(|k| !k.is_empty()) {
        if !PACKAGE_TYPE.is_match(kind) {
            return Err("Invalid package type".into());
        }
        args.extend(["--only-package-type".into(), kind.into()]);
    }
    args.push(format!("local://{image}"));
    Ok(args)
}

pub fn compare_args(image: &str, baseline: &str, only_fixed: bool) -> Vec<String> {
    let mut args: Vec<String> = ["compare", "--format", "json"].map(String::from).to_vec();
    if only_fixed {
        args.push("--only-fixed".into());
    }
    args.extend([format!("local://{image}"), "--to".into(), format!("local://{baseline}")]);
    args
}

#[cfg(test)]
mod tests {
    use super::*;

    fn s(v: &[&str]) -> Vec<String> {
        v.iter().map(|x| x.to_string()).collect()
    }

    #[test]
    fn argument_builders_match_python() {
        assert_eq!(cves_args("img:1", &s(&["HIGH", "critical"]), true, true).unwrap(),
            s(&["cves", "--format", "markdown", "--only-severity", "high,critical", "--only-fixed", "--only-cisa-kev", "local://img:1"]));
        assert_eq!(cves_args("i", &[], false, false).unwrap(), s(&["cves", "--format", "markdown", "local://i"]));
        assert_eq!(cves_args("i", &s(&["bad", "worse"]), false, false).unwrap_err(), "Unsupported severity: bad, worse");
        assert_eq!(full_scan_job("i", &s(&["High", "high", "low"]), false, true).unwrap()["severity"], serde_json::json!(["high", "low"]));
        assert!(full_scan_job("i", &s(&["nope"]), false, false).is_err());
        assert_eq!(sbom_args("i", Some("apk")).unwrap(), s(&["sbom", "--format", "list", "--only-package-type", "apk", "local://i"]));
        assert_eq!(sbom_args("i", Some("")).unwrap(), s(&["sbom", "--format", "list", "local://i"]));
        assert!(sbom_args("i", Some("a b")).is_err());
        assert_eq!(compare_args("a", "b", true), s(&["compare", "--format", "json", "--only-fixed", "local://a", "--to", "local://b"]));
    }

    #[cfg(unix)]
    fn sh(script: &str, env: Vec<(String, String)>, timeout: u64) -> Result<String, String> {
        run_binary("/bin/sh", &s(&["-c", script]), Duration::from_secs(timeout), env)
    }

    #[cfg(unix)]
    #[test]
    fn merged_output_errors_and_timeout() {
        assert_eq!(sh("echo out; echo err 1>&2", vec![], 5).unwrap(), "out\nerr\n");
        assert_eq!(sh("echo boom; exit 3", vec![], 5).unwrap_err(), "Docker Scout failed (3):\nboom\n");
        assert!(sh("sleep 5", vec![], 1).unwrap_err().contains("timed out"));
    }

    #[cfg(unix)]
    #[test]
    fn hub_credentials_come_only_from_files() {
        let dir = std::env::temp_dir().join(format!("scout-secrets-{}", uuid::Uuid::new_v4().simple()));
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("user"), " hub-user \n").unwrap();
        // SAFETY: test-only env changes; no other test reads these variables.
        unsafe {
            std::env::set_var("DOCKER_SCOUT_HUB_PASSWORD", "inherited-must-not-leak");
            std::env::set_var("DOCKER_SCOUT_HUB_USER_FILE", dir.join("user"));
            std::env::set_var("DOCKER_SCOUT_HUB_PASSWORD_FILE", dir.join("missing"));
        }
        let env = scout_env();
        assert!(env.contains(&("DOCKER_SCOUT_HUB_USER".into(), "hub-user".into())));
        assert!(!env.iter().any(|(k, _)| k == "DOCKER_SCOUT_HUB_PASSWORD"));
        assert!(env.contains(&("NO_COLOR".into(), "1".into())));
        std::fs::remove_dir_all(dir).unwrap();
    }
}
