from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
SERVER = (ROOT / "server.py").read_text(encoding="utf-8")
COMPOSE = (ROOT / "compose.public.yaml").read_text(encoding="utf-8")
CATALOG = (ROOT / "dockerlocal.yaml").read_text(encoding="utf-8")
RUNTIME = (ROOT / "dockerlocal-scout-runtime.ps1").read_text(encoding="utf-8")


class DockerLocalScoutHardeningTests(unittest.TestCase):
    def test_long_lived_service_uses_file_pointers_not_credentials(self) -> None:
        self.assertIn("DOCKER_SCOUT_HUB_USER_FILE:", COMPOSE)
        self.assertIn("DOCKER_SCOUT_HUB_PASSWORD_FILE:", COMPOSE)
        self.assertNotIn("DOCKER_SCOUT_HUB_USER:", COMPOSE)
        self.assertNotIn("DOCKER_SCOUT_HUB_PASSWORD:", COMPOSE)

    def test_scout_secrets_live_in_dedicated_tmpfs(self) -> None:
        self.assertIn("/run/dockerlocal-secrets:rw,nosuid,nodev,noexec", COMPOSE)
        self.assertIn("/run/dockerlocal-secrets/scout_hub_user", COMPOSE)
        self.assertIn("/run/dockerlocal-secrets/scout_hub_password", COMPOSE)

    def test_server_strips_parent_credentials_and_loads_runtime_files(self) -> None:
        self.assertIn('env.pop("DOCKER_SCOUT_HUB_USER", None)', SERVER)
        self.assertIn('env.pop("DOCKER_SCOUT_HUB_PASSWORD", None)', SERVER)
        self.assertIn('env["DOCKER_SCOUT_HUB_USER"] = scout_user', SERVER)
        self.assertIn('env["DOCKER_SCOUT_HUB_PASSWORD"] = scout_password', SERVER)

    def test_catalog_no_longer_requests_scout_env_credentials(self) -> None:
        self.assertNotIn("DOCKER_SCOUT_HUB_USER", CATALOG)
        self.assertNotIn("DOCKER_SCOUT_HUB_PASSWORD", CATALOG)

    def test_host_runtime_uses_dpapi_and_supervisor_rehydration(self) -> None:
        self.assertIn("scout_hub_user.dpapi", RUNTIME)
        self.assertIn("scout_hub_password.dpapi", RUNTIME)
        self.assertIn("ConvertFrom-SecureString", RUNTIME)
        self.assertIn('name = "dockerlocal-scout-secrets"', RUNTIME)
        self.assertIn('arguments = @("Up")', RUNTIME)
        self.assertIn("required_files", RUNTIME)

    def test_existing_mcp_edge_recovery_is_normalized_to_positional_action(self) -> None:
        self.assertIn('[string]$existingRuntime.name -eq "mcp-edge"', RUNTIME)
        self.assertIn('$existingRuntime.recovery.arguments = @("Up")', RUNTIME)

    def test_migration_recreates_container_before_verifying_env_removal(self) -> None:
        recreate = RUNTIME.index("--force-recreate")
        verify = RUNTIME.index("if (-not (Test-LongLivedScoutEnvAbsent))")
        self.assertLess(recreate, verify)


if __name__ == "__main__":
    unittest.main()
