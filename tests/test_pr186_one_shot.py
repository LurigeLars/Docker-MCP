"""Offline security tests for exact Trade Spine PR186 one-shot execution.

No Docker commands or Git fetches are actually executed.
"""
import contextlib
import io
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "local-test-runner"
import sys
sys.path.insert(0, str(APP))
import one_shot_pr186 as one


class OneShotPR186Tests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.base = Path(self.temp.name)
        self.config = {
            "enabled": False,
            "repo_path": one.APPROVED_CHECKOUT,
            "origin_url": one.APPROVED_ORIGIN,
            "allowed_ref": one.STAGED_REF,
            "image_id": one.EXPECTED_IMAGE,
            "git_executable": "C:\\Program Files\\Git\\cmd\\git.exe",
            "docker_executable": "C:\\Users\\test\\Programs\\Docker\\docker.exe",
        }
        self.orig_env = dict(os.environ)

    def tearDown(self):
        os.environ.clear()
        os.environ.update(self.orig_env)
        self.temp.cleanup()

    def test_target_is_exact_sha_and_only_approved_branch(self):
        self.assertEqual(one.TARGET_SHA, "7279f863a69c73ef14b598dff06ac2e58034f5e1")
        self.assertEqual(one.REF, "refs/remotes/origin/fix/compact-mcp-tool-budget-20261023")
        self.assertEqual(one.STAGED_REF, "refs/remotes/origin/disable/official-tradingview-20261020")
        self.assertEqual(one.EXPECTED_IMAGE,
                         "sha256:2296bc87afa5123a933771eac82c6aede05b939692fd3746a4bd89351510cc10")

    def test_preflight_denies_enabled_or_altered_policy_before_git(self):
        for field, value in (
            ("enabled", True),
            ("origin_url", "https://example.org/repo.git"),
            ("allowed_ref", "refs/remotes/origin/main"),
            ("image_id", "sha256:" + "a" * 64),
            ("repo_path", r"C:\Unapproved"),
        ):
            wrong = dict(self.config)
            wrong[field] = value
            with self.subTest(field=field), patch.object(one, "_command") as cmd:
                with self.assertRaises(RuntimeError):
                    one._preflight(wrong)
                cmd.assert_not_called()

    def test_success_does_not_change_persistent_config_or_register_worker(self):
        persistent = self.base / "config.json"
        raw = json.dumps(self.config)
        persistent.write_text(raw, encoding="utf-8")
        seen = []
        def submit(repo, sha):
            seen.append((repo, sha, os.environ.get(one.broker.ROOT_ENV)))
            cfg = json.loads((Path(seen[-1][2]) / "config.json").read_text())
            self.assertIs(cfg["enabled"], True)
            self.assertEqual(cfg["allowed_ref"], one.REF)
            self.assertEqual(self.config["allowed_ref"], one.STAGED_REF)
            return {"job_id": "a" * 32}
        with patch.object(one.broker, "_config", return_value=self.config), \
             patch.object(one.broker, "submit", side_effect=submit), \
             patch.object(one.broker, "work_once", return_value={"status": "PASSED"}), \
             patch.object(one.broker, "status", return_value={
                "status": "PASSED", "exit_code": 0, "phase": "FINISHED", "failure_code": None
             }):
            res = one._execute_one_job(self.config, self.base)
        self.assertEqual(res["status"], "PASSED")
        self.assertEqual(seen[0][:2], ("trade-spine", one.TARGET_SHA))
        self.assertEqual(persistent.read_text(), raw)
        self.assertNotIn(one.broker.ROOT_ENV, os.environ)
        self.assertEqual(list(self.base.glob("one-shot-pr186-*")), [])

    def test_uncertain_cleanup_preserves_disabled_evidence(self):
        def work():
            ephemeral = Path(os.environ[one.broker.ROOT_ENV])
            (ephemeral / "running").mkdir()
            (ephemeral / "running" / ("a" * 32 + ".json")).write_text("{}")
            raise one.broker.SandboxCleanupFailure("CLEANUP_UNVERIFIED")
        with patch.object(one.broker, "_config", return_value=self.config), \
             patch.object(one.broker, "submit", return_value={"job_id": "a" * 32}), \
             patch.object(one.broker, "work_once", side_effect=work):
            with self.assertRaises(one.broker.SandboxCleanupFailure):
                one._execute_one_job(self.config, self.base)
        dirs = list(self.base.glob("one-shot-pr186-*"))
        self.assertEqual(len(dirs), 1)
        self.assertIs(json.loads((dirs[0] / "config.json").read_text())["enabled"], False)
        self.assertEqual(len(list((dirs[0] / "running").glob("*.json"))), 1)
        self.assertNotIn(one.broker.ROOT_ENV, os.environ)

    def test_powershell_chooses_exactly_one_reviewed_python312(self):
        script = (ROOT / "scripts/windows/run-trade-spine-pr186-once.ps1").read_text()
        # Windows can return multiple python.exe entries, including the
        # WindowsApps placeholder; never pass a list to PowerShell call operator.
        self.assertNotIn("(Get-Command python.exe", script)
        self.assertIn(
            "$python = Join-Path $env:LOCALAPPDATA 'Programs\\Python\\Python312\\python.exe'",
            script,
        )
        self.assertIn("Test-Path -LiteralPath $python -PathType Leaf", script)
        self.assertIn("sys.version_info.major", script)
        self.assertIn("$pyVersion.Trim() -ne '3.12'", script)
        self.assertLess(script.index("$pyVersion = & $python -I"),
                        script.index("& $python -E -s"))

    def test_git_fetch_only_uses_scoped_noninteractive_gcm(self):
        from subprocess import CompletedProcess
        calls = []
        def fake_run(argv, **kwargs):
            calls.append((argv, kwargs))
            return CompletedProcess(argv, 0, b"ok", b"")
        with patch.object(one.subprocess, "run", side_effect=fake_run):
            self.assertEqual(
                one._command("C:/Git/git.exe", ["-C", "repo", "fetch", "origin"],
                             git=True, stage="GIT_FETCH"),
                "ok",
            )
            self.assertEqual(
                one._command("C:/Git/git.exe", ["-C", "repo", "status"],
                             git=True, stage="GIT_STATUS"),
                "ok",
            )
        fetch_argv, fetch_options = calls[0]
        other_argv, other_options = calls[1]
        self.assertEqual(
            fetch_argv[1:7],
            ["-c", "credential.helper=", "-c", "credential.helper=manager",
             "-c", "credential.interactive=false"],
        )
        self.assertEqual(fetch_options["env"]["GCM_INTERACTIVE"], "0")
        self.assertEqual(fetch_options["env"]["GIT_TERMINAL_PROMPT"], "0")
        self.assertEqual(fetch_options["env"]["GIT_CONFIG_NOSYSTEM"], "1")
        self.assertEqual(fetch_options["env"]["GIT_CONFIG_GLOBAL"], os.devnull)
        self.assertFalse(any("credential.helper" in arg for arg in other_argv))
        self.assertNotIn("GCM_INTERACTIVE", other_options["env"])
        self.assertEqual(fetch_options["stdin"], one.subprocess.DEVNULL)
        self.assertEqual(fetch_options["stdout"], one.subprocess.PIPE)
        self.assertEqual(fetch_options["stderr"], one.subprocess.PIPE)

    def test_windows_credential_store_folders_only_pass_to_approved_fetch(self):
        from subprocess import CompletedProcess
        captures = []
        def runner(argv, **kwargs):
            captures.append(kwargs["env"])
            return CompletedProcess(argv, 0, b"", b"")
        variables = {
            "USERPROFILE": r"C:\\Users\\Operator",
            "LOCALAPPDATA": r"C:\\Users\\Operator\\AppData\\Local",
            "APPDATA": r"C:\\Users\\Operator\\AppData\\Roaming",
            "UNRELATED_SECRET": "must-not-be-inherited",
        }
        with (patch.dict(os.environ, variables),
              patch.object(one.subprocess, "run", side_effect=runner)):
            one._command("git", ["fetch", "origin"], git=True, stage="GIT_FETCH")
            one._command("git", ["status"], git=True, stage="GIT_STATUS")
        for k in ("USERPROFILE", "LOCALAPPDATA", "APPDATA"):
            self.assertEqual(captures[0][k], variables[k])
            self.assertNotIn(k, captures[1])
        self.assertNotIn("UNRELATED_SECRET", captures[0])
        self.assertNotIn("UNRELATED_SECRET", captures[1])

    def test_non_fetch_git_never_uses_gcm(self):
        from subprocess import CompletedProcess
        with patch.object(one.subprocess, "run",
                          return_value=CompletedProcess([], 0, b"", b"")) as mock_run:
            for stage in ("GIT_ORIGIN", "GIT_BRANCH", "GIT_REF",
                          "GIT_STATUS", "GIT_POST_FETCH_STATUS"):
                one._command("git", ["status"], git=True, stage=stage)
        for call in mock_run.call_args_list:
            self.assertNotIn("credential.helper=manager", call.args[0])
            self.assertNotIn("GCM_INTERACTIVE", call.kwargs["env"])

    def test_diagnostic_failures_expose_stage_not_subprocess_stderr(self):
        from subprocess import CompletedProcess

        cases = [
            ("GIT_ORIGIN", b"fatal: detected dubious ownership in repository /private/path",
             "PRECHECK_GIT_ORIGIN_EXIT_128_GIT_UNSAFE_OWNERSHIP"),
            ("GIT_FETCH", b"fatal: could not resolve host: secret.example.test",
             "PRECHECK_GIT_FETCH_EXIT_128_NETWORK_DNS"),
            ("IMAGE_ID", b"Error: No such image: operator-private-path",
             "PRECHECK_IMAGE_ID_EXIT_128_IMAGE_NOT_FOUND"),
        ]
        for stage, stderr, expected in cases:
            with self.subTest(stage=stage):
                response = CompletedProcess(args=[], returncode=128,
                                            stdout=b"secret stdout", stderr=stderr)
                with patch.object(one.subprocess, "run", return_value=response):
                    with self.assertRaisesRegex(RuntimeError, "^" + expected + "$") as caught:
                        one._command("stub", ["fixed"], stage=stage)
                self.assertNotIn("private", str(caught.exception))
                self.assertNotIn("secret", str(caught.exception))

    def test_preflight_only_never_starts_test_or_mutates_config(self):
        root = self.base / "DockerLocalRegression"
        root.mkdir()
        raw = json.dumps(self.config, sort_keys=True).encode()
        (root / "config.json").write_bytes(raw)
        output = io.StringIO()
        with patch.dict(os.environ, {"LOCALAPPDATA": str(self.base)}), \
             patch.object(sys, "argv", ["one_shot_pr186.py", "--preflight-only"]), \
             patch.object(one, "_preflight", return_value=None) as checked, \
             patch.object(one, "_execute_one_job") as forbidden, \
             contextlib.redirect_stdout(output):
            self.assertEqual(0, one.main())
        checked.assert_called_once()
        forbidden.assert_not_called()
        self.assertEqual((root / "config.json").read_bytes(), raw)
        self.assertEqual(list(root.glob("one-shot-pr186-*")), [])
        self.assertIn("NO_TEST_JOB_STARTED", output.getvalue())

    def test_powershell_preflight_mode_is_separate_from_run(self):
        script = (ROOT / "scripts/windows/run-trade-spine-pr186-once.ps1").read_text()
        self.assertIn("[switch]$PreflightOnly", script)
        self.assertIn("'--preflight-only'", script)
        self.assertIn("PR186_PREFLIGHT_NOT_PASSED", script)
        self.assertLess(script.index("if ($PreflightOnly)"),
                        script.index("START PR186: fixed commit"))

    def test_powershell_wrapper_cannot_accept_dynamic_pr_or_commands(self):
        script = (ROOT / "scripts/windows/run-trade-spine-pr186-once.ps1").read_text()
        self.assertIn("ExpectedDockerMcpHead", script)
        self.assertIn("one_shot_pr186.py", script)
        for denied in ("Invoke-Expression", "Register-ScheduledTask", "New-Service",
                       "ALLOWED_TOOLS", "docker run", "docker exec",
                       "Start-Service", "Start-ScheduledTask"):
            self.assertNotIn(denied, script)


if __name__ == "__main__":
    unittest.main()
