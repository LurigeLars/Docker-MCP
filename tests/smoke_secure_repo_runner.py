"""Offline end-to-end sandbox acceptance fixture for ephemeral GitHub runner.

This test runs real Docker commands, and must NOT be run by unit test discovery
or on the user's host without explicit operator consent. No network is
accessible to the test container. The Git checkout is synthetic.
"""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "local-test-runner"))
import secure_test_runner as runner


def fixed(args, cwd):
    result = subprocess.run(args, cwd=cwd, text=True, capture_output=True, timeout=30)
    if result.returncode:
        raise RuntimeError("Fixture setup command failed")
    return result.stdout.strip()


def main():
    image = fixed(["docker", "image", "inspect", "--format", "{{.Id}}",
                   "dockerlocal-regression-sandbox:review"], None)
    assert runner.IMAGE.fullmatch(image)
    with tempfile.TemporaryDirectory() as tmp:
        base = Path(tmp)
        checkout = base / "checkout"
        checkout.mkdir()
        fixed(["git", "init", "-b", "main"], checkout)
        fixed(["git", "config", "user.email", "ci-fixture@example.invalid"], checkout)
        fixed(["git", "config", "user.name", "CI Fixture"], checkout)
        fixtures = checkout / "tests"
        fixtures.mkdir()
        (fixtures / "test_sandbox.py").write_text('''
import os
from pathlib import Path
import socket
import unittest

class Sandbox(unittest.TestCase):
    def test_no_network(self):
        with self.assertRaises(OSError):
            socket.create_connection(("1.1.1.1", 53), timeout=0.5)
    def test_nonroot_no_docker_and_no_untrusted_env(self):
        self.assertNotEqual(0, os.getuid())
        self.assertFalse(Path("/var/run/docker.sock").exists())
        self.assertNotIn("TEST_SECRET", os.environ)
        self.assertFalse(Path("/root").is_dir() and os.access("/root", os.R_OK))
    def test_readonly_root(self):
        with self.assertRaises(OSError):
            Path("/root-untrusted-output").write_text("no")
''', encoding="utf-8")
        fixed(["git", "add", "tests/test_sandbox.py"], checkout)
        fixed(["git", "commit", "-m", "Isolated test fixture"], checkout)
        sha = fixed(["git", "rev-parse", "HEAD"], checkout)
        fixed(["git", "remote", "add", "origin",
               "https://github.com/LurigeLars/trade-spine.git"], checkout)
        fixed(["git", "update-ref", "refs/remotes/origin/security-fixture", sha], checkout)
        job_root = base / "private"
        job_root.mkdir()
        config = {
            "enabled": True, "repo_path": str(checkout),
            "origin_url": "https://github.com/LurigeLars/trade-spine.git",
            "allowed_ref": "refs/remotes/origin/security-fixture",
            "image_id": image,
        }
        (job_root / "config.json").write_text(json.dumps(config), encoding="utf-8")
        os.environ[runner.ROOT_ENV] = str(job_root)
        queued = runner.submit("trade-spine", sha)
        result = runner.work_once()
        if result["status"] != "PASSED":
            raise RuntimeError("The isolated smoke test did not pass")
        completed = runner.status(queued["job_id"])
        if completed["status"] != "PASSED" or completed["exit_code"] != 0:
            raise RuntimeError("Untrustworthy sandbox result")
        jobs = fixed(["docker", "ps", "-a", "--filter",
                      "name=dl-regression-", "--format", "{{.Names}}"], None)
        if jobs:
            raise RuntimeError("Disposable test container leaked")
        print("DOCKER SANDBOX SMOKE PASSED: isolated, cleaned, no network")


if __name__ == "__main__":
    main()
