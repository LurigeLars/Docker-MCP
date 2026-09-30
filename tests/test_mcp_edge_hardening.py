from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = (ROOT / "mcp-edge-runtime.ps1").read_text(encoding="utf-8")
WATCH = (ROOT / "dependency-watch" / "edge-images" / "Dockerfile").read_text(encoding="utf-8")


class McpEdgeSecretHardeningTests(unittest.TestCase):
    def test_lastexitcode_is_seeded_before_native_exit_checks(self) -> None:
        seed = SCRIPT.index("$global:LASTEXITCODE = 0")
        first_check = SCRIPT.index("$LASTEXITCODE")
        self.assertLessEqual(seed, first_check)

    def test_tunnel_token_is_dpapi_backed(self) -> None:
        self.assertIn("tunnel_token.dpapi", SCRIPT)
        self.assertIn("ConvertFrom-SecureString", SCRIPT)
        self.assertIn("Get-DpapiSecretValue", SCRIPT)

    def test_cloudflared_uses_token_file_not_token_env(self) -> None:
        self.assertIn("--token-file", SCRIPT)
        self.assertIn("/run/mcp-edge-secrets/tunnel_token", SCRIPT)
        self.assertIn('return -not ($keys -contains "TUNNEL_TOKEN")', SCRIPT)

    def test_runtime_secret_lives_in_docker_tmpfs(self) -> None:
        self.assertIn("type: tmpfs", SCRIPT)
        self.assertIn("device: tmpfs", SCRIPT)
        self.assertIn("mcp-edge-secret-holder", SCRIPT)
        self.assertIn('"exec", "-i", $SecretHolder', SCRIPT)

    def test_legacy_plaintext_is_removed_only_after_success_path(self) -> None:
        update_index = SCRIPT.index("Update-SupervisorConfig")
        remove_index = SCRIPT.rindex("Remove-Item -LiteralPath $LegacyEnvPath")
        self.assertGreater(remove_index, update_index)

    def test_runtime_supervisor_rehydrates_missing_tmpfs_secret(self) -> None:
        self.assertIn('name = "mcp-edge"', SCRIPT)
        self.assertIn('required_files = @($RuntimeSecretPath)', SCRIPT)
        self.assertIn('arguments = @("Up")', SCRIPT)

    def test_migration_keeps_rollback_compose_until_hardened_start_succeeds(self) -> None:
        self.assertIn("compose.pre-dpapi.yaml", SCRIPT)
        self.assertIn("Copy-Item -LiteralPath $ComposeBackupPath -Destination $ComposePath -Force", SCRIPT)

    def test_busybox_watch_pin_matches_runtime_pin(self) -> None:
        watch = next(
            line.split(":", 1)[1].split()[0]
            for line in WATCH.splitlines()
            if line.startswith("FROM busybox:")
        )
        runtime = next(
            line.split("busybox:", 1)[1].split("'")[0]
            for line in SCRIPT.splitlines()
            if "image: busybox:" in line
        )
        self.assertEqual(watch, runtime)

    def test_cloudflared_watch_is_signal_only(self) -> None:
        self.assertIn("Dependabot-only manifest", WATCH)
        self.assertIn("never built or deployed", WATCH)
        self.assertRegex(WATCH, r"FROM cloudflare/cloudflared:[0-9.]+ AS cloudflared")


if __name__ == "__main__":
    unittest.main()
