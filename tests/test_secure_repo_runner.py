"""Security invariants for staged local Docker regression runner.

No Docker CLI is invoked in this unit suite. A true sandbox acceptance run
must be performed on the target Windows Docker Desktop host before enabling.
"""
import io
import json
import os
from pathlib import Path
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "local-test-runner"))
import secure_test_runner as runner

SHA = "a" * 40
IMAGE = "sha256:" + "f" * 64


class SecureRunnerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.checkout = self.root / "trusted-checkout"
        self.checkout.mkdir()
        self.env = patch.dict(os.environ, {runner.ROOT_ENV: str(self.root)})
        self.env.start()
        self.config = {
            "enabled": True, "repo_path": str(self.checkout),
            "origin_url": "https://github.com/LurigeLars/trade-spine.git",
            "allowed_ref": "refs/remotes/origin/review-safe",
            "image_id": IMAGE,
        }
        self.save_config()
    def tearDown(self):
        self.env.stop()
        self.tmp.cleanup()
    def save_config(self):
        (self.root / "config.json").write_text(json.dumps(self.config), encoding="utf-8")

    def test_explicit_operator_enablement_required(self):
        self.config["enabled"] = False
        self.save_config()
        with self.assertRaises(RuntimeError):
            runner.submit("trade-spine", SHA)

    def test_rejects_unapproved_repo_and_any_non_exact_sha(self):
        for repo, sha in [
            ("other", SHA), ("trade-spine", "main"), ("trade-spine", "../" + SHA),
            ("trade-spine", SHA.upper()), ("trade-spine", SHA + " --exec"),
            ("trade-spine", ""), ("trade-spine", None)
        ]:
            with self.subTest(repo=repo, sha=sha), self.assertRaises(ValueError):
                runner.submit(repo, sha)
        self.assertEqual([], list(self.root.glob("requests/*.json")))

    def test_accepted_request_has_no_caller_commands(self):
        ticket = runner.submit("trade-spine", SHA)
        self.assertEqual("QUEUED", ticket["status"])
        self.assertRegex(ticket["job_id"], r"^[a-f0-9]{32}$")
        self.assertEqual("QUEUED", runner.status(ticket["job_id"])["status"])
        data = json.loads(next((self.root / "requests").glob("*.json")).read_text())
        self.assertEqual({"job_id", "repo", "commit_sha", "day", "created_unix"}, set(data))
        with self.assertRaises(RuntimeError):
            runner.submit("trade-spine", SHA)

    def test_status_rejects_traversal_and_forged_ids(self):
        for value in ("../secrets", "/tmp/abc", "A" * 32, "", "a" * 33):
            with self.subTest(value=value), self.assertRaises(ValueError):
                runner.status(value)

    def test_rejects_remote_ref_override_and_mutable_image(self):
        for key, value in [
            ("allowed_ref", "-c dangerous"),
            ("allowed_ref", "refs/remotes/other/main"),
            ("image_id", "python:latest"),
            ("origin_url", "https://evil.example/repo.git"),
        ]:
            old = self.config[key]
            self.config[key] = value
            self.save_config()
            with self.assertRaises(ValueError):
                runner.submit("trade-spine", SHA)
            self.config[key] = old

    def test_rejects_symlinked_private_request_area(self):
        outside = self.root / "other"
        outside.mkdir()
        p = self.root / "requests"
        try:
            p.symlink_to(outside, target_is_directory=True)
        except (OSError, NotImplementedError):
            self.skipTest("Symlink privilege unavailable on this platform")
        with self.assertRaises(ValueError):
            runner.submit("trade-spine", SHA)

    def _archive(self, specs):
        tar = self.root / "sample.tar"
        with tarfile.open(tar, "w") as f:
            for name, kind in specs:
                entry = tarfile.TarInfo(name)
                entry.mode = 0o644
                if kind == "link":
                    entry.type = tarfile.SYMTYPE
                    entry.linkname = "../outside"
                else:
                    data = b"test"
                    entry.size = len(data)
                f.addfile(entry, io.BytesIO(b"test") if kind != "link" else None)
        return tar

    def test_archive_rejects_traversal_secrets_and_links(self):
        for name, kind in [
            ("../attack.txt", "file"), ("/absolute.txt", "file"),
            ("nested/.env", "file"), ("nested\\windows.txt", "file"),
            ("source.py", "link"), ("C:/windows/test", "file")
        ]:
            with self.subTest(name=name):
                archive = self._archive([(name, kind)])
                with self.assertRaises(ValueError):
                    runner._verify_archive(archive)

    def test_archive_allows_normal_python_source(self):
        runner._verify_archive(self._archive([
            ("trade_spine/__init__.py", "file"),
            ("tests/test_example.py", "file"),
        ]))

    def test_sandbox_is_checked_before_start(self):
        calls = []
        def fake_run(argv, **_kwargs):
            calls.append(argv)
            if "image" in argv and "inspect" in argv:
                return type("Result", (), {"returncode": 0, "stdout": IMAGE.encode()})()
            if "create" in argv:
                return type("Result", (), {"returncode": 0, "stdout": b"created"})()
            if "--format" in argv and "{{json .HostConfig}}" in argv:
                # A hostile daemon/image must not be executed on a mismatch.
                state = {"NetworkMode": "bridge", "ReadonlyRootfs": True,
                         "Privileged": False, "CapDrop": ["ALL"],
                         "SecurityOpt": ["no-new-privileges"], "PidsLimit": 64,
                         "Memory": 1024 * 1024 * 1024, "Mounts": [{
                             "Type": "bind", "Target": "/input/source.tar", "ReadOnly": True
                         }]}
                return type("Result", (), {
                    "returncode": 0, "stdout": json.dumps(state).encode()
                })()
            return type("Result", (), {"returncode": 0, "stdout": b""})()
        with patch.object(runner.shutil, "which", return_value="/mock/docker"):
            with patch.object(runner, "_run", side_effect=fake_run):
                with self.assertRaisesRegex(RuntimeError, "isolation mismatch"):
                    runner._docker_job(self.config, "a" * 32, self.root / "source.tar")
        self.assertFalse(any("start" in cmd for cmd in calls))
        self.assertTrue(any("rm" in cmd for cmd in calls))

    def test_sha_only_export_does_not_use_checkout_scripts(self):
        values = iter([
            self.config["origin_url"], "main", "", SHA, ""
        ])
        commands = []
        def fake_git(argv, _checkout, **_):
            commands.append(argv)
            return next(values)
        def fake_run(argv, **_):
            self.assertIn("archive", argv)
            Path(str(next(x for x in argv if x.startswith("--output="))).split("=", 1)[1]).write_bytes(
                self._archive([("tests/test_min.py", "file")]).read_bytes()
            )
            return type("Result", (), {"returncode": 0, "stdout": b""})()
        with patch.object(runner, "_git", side_effect=fake_git):
            with patch.object(runner, "_run", side_effect=fake_run):
                with patch.object(runner.shutil, "which", return_value="git"):
                    runner._snapshot(self.config, SHA, self.root / "source.tar")
        self.assertIn(["merge-base", "--is-ancestor", SHA, self.config["allowed_ref"]], commands)
        self.assertNotIn(["fetch"], commands)

if __name__ == "__main__":
    unittest.main()
