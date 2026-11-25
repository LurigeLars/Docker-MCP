//! Pure text helpers mirrored byte-for-byte from server.py.

use std::sync::LazyLock;

use regex::Regex;

static BEARER: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"(?i)(authorization:\s*bearer\s+)[^\s]+").unwrap());
static SECRET_KV: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(?i)\b(password|passwd|token|secret|api[_-]?key)\b(\s*[:=]\s*)([^\s,;]+)").unwrap()
});

/// Same two patterns, same order, same replacements as server.py `_redact`.
pub fn redact(text: &str) -> String {
    let once = BEARER.replace_all(text, "${1}[REDACTED]");
    SECRET_KV.replace_all(&once, "${1}${2}[REDACTED]").into_owned()
}

/// Docker multiplexed log stream (8-byte frame headers) or plain bytes, as `_decode_logs`.
pub fn decode_logs(data: &[u8]) -> String {
    if data.len() >= 8 && data[0] <= 3 && data[1..4] == [0, 0, 0] {
        let mut out = Vec::with_capacity(data.len());
        let mut pos = 0;
        while pos + 8 <= data.len() {
            let size = u32::from_be_bytes(data[pos + 4..pos + 8].try_into().unwrap()) as usize;
            pos += 8;
            if pos + size > data.len() {
                break;
            }
            out.extend_from_slice(&data[pos..pos + size]);
            pos += size;
        }
        return String::from_utf8_lossy(&out).into_owned();
    }
    String::from_utf8_lossy(data).into_owned()
}

pub fn bytes_human(value: f64) -> String {
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn redaction_matches_python() {
        assert_eq!(redact("Authorization: Bearer abc.def"), "Authorization: Bearer [REDACTED]");
        assert_eq!(redact("password=hunter2, next"), "password=[REDACTED], next");
        assert_eq!(redact("API-KEY: x1;y"), "API-KEY: [REDACTED];y");
        assert_eq!(redact("Api_Key = v"), "Api_Key = [REDACTED]");
        // \b keeps substrings like "tokens" and "mytoken" untouched, as in Python.
        assert_eq!(redact("tokens=3 mytoken=4"), "tokens=3 mytoken=4");
        // Unicode word characters count for \b in both engines.
        assert_eq!(redact("étoken=5"), "étoken=5");
    }

    #[test]
    fn log_frames_and_plain_bytes() {
        let mut framed = vec![1, 0, 0, 0, 0, 0, 0, 3];
        framed.extend_from_slice(b"ab\n");
        framed.extend_from_slice(&[2, 0, 0, 0, 0, 0, 0, 2]);
        framed.extend_from_slice(b"c\n");
        assert_eq!(decode_logs(&framed), "ab\nc\n");
        // A truncated final frame is dropped, like the Python loop.
        framed.extend_from_slice(&[1, 0, 0, 0, 0, 0, 0, 9, b'x']);
        assert_eq!(decode_logs(&framed), "ab\nc\n");
        assert_eq!(decode_logs(b"plain \xff text"), "plain \u{fffd} text");
    }

    #[test]
    fn bytes_human_matches_python() {
        assert_eq!(bytes_human(0.0), "0.0 B");
        assert_eq!(bytes_human(1536.0), "1.5 KiB");
        assert_eq!(bytes_human(5.0 * 1024f64.powi(5)), "5120.0 TiB");
    }
}
