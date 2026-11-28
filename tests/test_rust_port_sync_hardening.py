"""The Rust port (rust/) must not silently drift from the server.py code it mirrors."""

import importlib.util
import json
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("port_sync", ROOT / "rust" / "port_sync.py")
port_sync = importlib.util.module_from_spec(spec)
spec.loader.exec_module(port_sync)


class RustPortSyncTest(unittest.TestCase):
    def test_ported_python_code_matches_the_recorded_fingerprints(self):
        recorded = json.loads(port_sync.RECORD.read_text(encoding="utf-8"))
        current = port_sync.compute()
        changed = sorted(
            name
            for kind in ("functions", "constants")
            for name in current[kind]
            if recorded[kind].get(name) != current[kind][name]
        )
        self.assertEqual(
            changed, [],
            "server.py changed code the Rust port mirrors. Update rust/ to match, then run "
            "`python rust/port_sync.py --write`.",
        )

    def test_every_tool_is_classified(self):
        self.assertEqual(
            port_sync.compute()["unclassified_tools"], [],
            "New tool: add it to PORTED_TOOLS or NOT_PORTED_TOOLS in rust/port_sync.py.",
        )

    def test_ported_list_matches_the_rust_tools(self):
        main = (ROOT / "rust" / "src" / "main.rs").read_text(encoding="utf-8")
        rust_tools = set(re.findall(r"#\[tool\(description[^\]]*\]\s*async fn ([a-z_]+)", main, re.S))
        self.assertEqual(rust_tools, set(port_sync.PORTED_TOOLS))

    def test_a_changed_function_is_detected(self):
        source = port_sync.SERVER.read_text(encoding="utf-8")
        before = port_sync.compute(source)["functions"]["_redact"]
        after = port_sync.compute(source.replace("[REDACTED]", "[HIDDEN]", 1))["functions"]["_redact"]
        self.assertNotEqual(before, after)


if __name__ == "__main__":
    unittest.main()
