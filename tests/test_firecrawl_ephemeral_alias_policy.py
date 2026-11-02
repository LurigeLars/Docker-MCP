from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
PROMOTE = (ROOT / "promote-mcp-runtime.ps1").read_text(encoding="utf-8")
RUNNER = (ROOT / "maintenance-runner.ps1").read_text(encoding="utf-8")


class FirecrawlEphemeralRefreshRegistrationTests(unittest.TestCase):
    def test_only_two_fixed_new_one_service_aliases_are_registered(self):
        self.assertIn("'firecrawl-redis-refresh' = @('refresh-redis','redis')", PROMOTE)
        self.assertIn("'firecrawl-rabbitmq-refresh' = @('refresh-rabbitmq','rabbitmq')", PROMOTE)
        self.assertIn("'security\\refresh-ephemeral.ps1'", PROMOTE)
        self.assertIn("Reviewed Firecrawl ephemeral refresh implementation not present.", PROMOTE)

    def test_searxng_refresh_exact_alias_and_scan_gate(self):
        self.assertIn("'firecrawl-searxng-refresh' = @('refresh-searxng','searxng')", PROMOTE)
        self.assertIn("'security\\\\refresh-searxng.ps1'", PROMOTE)
        self.assertIn("Reviewed Firecrawl SearXNG refresh implementation not present.", PROMOTE)

    def test_search_proxy_refresh_has_exact_host_alias(self):
        self.assertIn("'firecrawl-search-proxy-refresh' = @('refresh-search-proxy','searxng-proxy')", PROMOTE)
        self.assertIn("Reviewed Firecrawl internal SearXNG proxy refresh not present.", PROMOTE)

    def test_public_gateway_uses_exact_scoped_alias_and_access_gate(self):
        self.assertIn("'firecrawl-public-gateway-refresh' = @('refresh-gateway','gateway')", PROMOTE)
        self.assertIn("Reviewed Firecrawl public gateway refresh implementation not present.", PROMOTE)

    def test_last_two_node_helpers_have_exact_fixed_actions_and_gemini_restore(self):
        self.assertIn("'firecrawl-playwright-router-refresh' = @('refresh-playwright-router','playwright-router')", PROMOTE)
        self.assertIn("'firecrawl-llm-proxy-refresh' = @('refresh-llm-proxy','llm-proxy')", PROMOTE)
        self.assertIn("Reviewed last two Firecrawl Node runtime patch actions missing.", PROMOTE)

    def test_existing_stateless_allowlist_does_not_expand_to_data_services(self):
        self.assertIn('if ($Operation -eq "update_stateless")', RUNNER)
        self.assertIn('if ($Project -cne "firecrawl" -or', RUNNER)
        self.assertIn('throw "update_stateless requires one explicitly allowlisted Firecrawl stateless service."', RUNNER)
        self.assertIn('if ($Operation -eq "update_stateless")', RUNNER)
        self.assertIn("redeploy_current = @('-Action',$Action)", PROMOTE)


if __name__ == "__main__":
    unittest.main()
