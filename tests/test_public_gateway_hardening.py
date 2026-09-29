from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
GATEWAY = (ROOT / "public" / "gateway" / "gateway.mjs").read_text(encoding="utf-8")


class DockerLocalGatewayHardeningTests(unittest.TestCase):
    def test_discovery_responses_are_filtered(self) -> None:
        self.assertIn("function rewriteResponseMessage", GATEWAY)
        self.assertIn("message.result.tools = message.result.tools.filter", GATEWAY)
        self.assertIn("ALLOWED_TOOLS.has", GATEWAY)
        self.assertIn("message?.method === 'tools/list'", GATEWAY)
        self.assertIn("message?.method === 'initialize'", GATEWAY)

    def test_initialize_instructions_do_not_echo_hidden_tool_catalog(self) -> None:
        self.assertIn("DockerLocal exposes only the tools returned by tools/list", GATEWAY)


if __name__ == "__main__":
    unittest.main()
