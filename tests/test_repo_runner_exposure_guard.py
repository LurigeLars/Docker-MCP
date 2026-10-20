"""Prevent accidental exposure of the proposed code-running tool at the public edge.

This intentionally tests a DENY default. It is not evidence that an unbuilt
sandbox exists or that dynamic authorization tests may be omitted.
"""

from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]


class PublicRegressionRunnerBoundaryTests(unittest.TestCase):
    def test_public_gateway_does_not_allow_code_execution_tool(self):
        text = (ROOT / "compose.public.yaml").read_text(encoding="utf-8")
        matches = re.findall(r"^\s*ALLOWED_TOOLS:\s*(.*)$", text, re.MULTILINE)
        self.assertEqual(len(matches), 1, "Public gateway needs exactly one explicit tool allowlist")
        allowed = matches[0].strip().strip('"').strip("'")
        self.assertTrue(allowed)
        self.assertNotIn("$", allowed, "Public tool allowlist must not be environment-expanded")
        names = [name.strip() for name in allowed.split(",")]
        self.assertEqual(len(names), len(set(names)), "Duplicate public tool entries")
        for name in ("repo_run_tests", "repo_test_status", "docker_exec", "docker_run"):
            self.assertNotIn(name, names)

    def test_public_gateway_enforces_call_and_discovery_allowlist(self):
        gateway = (ROOT / "public" / "gateway" / "gateway.mjs").read_text(encoding="utf-8")
        self.assertIn("if (!ALLOWED_TOOLS.has(name))", gateway)
        self.assertIn("message.result.tools.filter", gateway)
        self.assertIn("ALLOWED_TOOLS.has(String(tool?.name ?? ''))", gateway)


if __name__ == "__main__":
    unittest.main()
