"""Advisory, bounded summary from hostile unittest output. Never echo raw logs.

This is NOT a pass/fail oracle. The Docker process exit code is authoritative.
Output may be spoofed by untrusted tests; only names of known repo test modules
and narrow exception categories are admitted as non-authoritative hints.
"""
import re

# Fixed, reviewed test module identifiers from the approved Trade Spine repo.
_MODULES = frozenset({
    "test_avanza_transactions", "test_credit_risk", "test_daily",
    "test_decision_memory", "test_legacy_scanner_audit", "test_local_inputs",
    "test_market_engine_backtest", "test_market_engine_context", "test_mcp",
    "test_opportunity_discovery", "test_policy_signals", "test_portfolio_watch",
    "test_portfolio_watch_collectors", "test_portfolio_watch_runner",
    "test_quick_check", "test_retire_legacy_verdict", "test_spine",
    "test_timezone_data", "test_tool_audit", "test_tradingview_official",
})
_KINDS = frozenset({
    "AssertionError", "ModuleNotFoundError", "ImportError", "PermissionError",
    "OperationalError", "ValueError", "TypeError", "KeyError", "RuntimeError",
    "OSError", "FileNotFoundError", "AttributeError", "TimeoutError",
    "ConnectionError", "ZeroDivisionError", "NameError",
})
_CASE = re.compile(
    r"^(?:FAIL|ERROR): (test_[A-Za-z0-9_]{1,64}) "
    r"\((?:tests\.)?(test_[A-Za-z0-9_]{1,64})"
    r"(?:\.[A-Za-z0-9_]{1,64}){1,3}\)$", re.MULTILINE,
)
_SUMMARY = re.compile(r"^Ran ([0-9]{1,6}) tests? in ", re.MULTILINE)
_FAILED = re.compile(r"^FAILED \(([^)\r\n]{0,150})\)$", re.MULTILINE)
_KIND = re.compile(r"^([A-Za-z]{1,45}(?:Error|Exception))(?::|$)", re.MULTILINE)

def summarize(raw: bytes) -> dict:
    """Parse at most the last 24KiB. Never return source or traceback text."""
    text = raw[-24576:].decode("utf-8", "replace")
    matches = _CASE.findall(text)
    safe_cases = []
    for name, module in matches:
        if module in _MODULES and len(safe_cases) < 12:
            label = module + ":" + name
            if label not in safe_cases:
                safe_cases.append(label)
    kind_names = sorted(set(_KIND.findall(text)) & _KINDS)[:8]
    ran = _SUMMARY.findall(text)
    totals = {}
    for field in ("failures", "errors", "skipped"):
        totals[field] = 0
    failure = _FAILED.findall(text)
    if failure:
        for key, val in re.findall(r"\b(failures|errors|skipped)=([0-9]{1,5})\b", failure[-1]):
            totals[key] = int(val)
    return {
        "advisory_only": True,
        "source": "bounded_sanitized_unittest_output",
        "cases": safe_cases,
        "error_kinds": kind_names,
        "tests_run": int(ran[-1]) if ran else None,
        "failures": totals["failures"],
        "errors": totals["errors"],
        "skipped": totals["skipped"],
        "summary_found": bool(ran or failure),
    }
