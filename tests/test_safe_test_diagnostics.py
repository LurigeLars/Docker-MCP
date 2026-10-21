"""Security regression tests: never return raw hostile unittest logs."""
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "local-test-runner"))
import safe_test_diagnostics as safe
import secure_test_runner as broker

IMAGE = "sha256:" + "f" * 64

class BoundedDiagnostics(unittest.TestCase):
    def test_allowlisted_unittest_failure_fields_only(self):
        raw = (b"secrets: token=DO_NOT_ECHO path=C:/Users/private\n"
               b"FAIL: test_old (test_unapproved.Module.test_old)\n"
               b"ERROR: test_a (test_mcp.Server.test_a)\n"
               b"FAIL: test_b (test_portfolio_watch_runner.RecoveryRunner.test_b)\n"
               b"RuntimeError: secret=/mnt/private do not show\n"
               b"ModuleNotFoundError: No module named 'super-secret'\n"
               b"Ran 653 tests in 22.0s\n"
               b"FAILED (failures=1, errors=1, skipped=2)\n")
        result = safe.summarize(raw)
        self.assertEqual(["test_mcp:test_a", "test_portfolio_watch_runner:test_b"],
                         result["cases"])
        self.assertEqual(["ModuleNotFoundError", "RuntimeError"], result["error_kinds"])
        self.assertEqual((653, 1, 1, 2),
                         (result["tests_run"], result["failures"], result["errors"],
                          result["skipped"]))
        self.assertTrue(result["advisory_only"])
        self.assertTrue(result["summary_found"])
        text = json.dumps(result)
        for private in ("DO_NOT_ECHO", "super-secret", "/mnt/private",
                        "test_unapproved", "C:/Users/private"):
            self.assertNotIn(private, text)

    def test_malicious_names_and_large_output_are_bounded(self):
        payload = b"ERROR: test_secret_!!! (test_mcp.Server.test_secret)\n"
        payload += b"ERROR: test_not_allowed (test_evil.SomeClass.test_not_allowed)\n"
        for i in range(200):
            payload += ("ERROR: test_case_%03d (test_mcp.Server.test_case_%03d)\n"
                        % (i, i)).encode()
        raw = b"SECRET_MARKER" * 10000 + payload
        result = safe.summarize(raw)
        self.assertLessEqual(len(result["cases"]), 12)
        self.assertTrue(all(x.startswith("test_mcp:") for x in result["cases"]))
        self.assertNotIn("SECRET_MARKER", json.dumps(result))

    def test_docker_logs_captured_before_cleanup_and_never_control_exit(self):
        job = "a" * 32
        cid = "b" * 64
        with tempfile.TemporaryDirectory() as td:
            archive = Path(td) / "source.tar"
            archive.write_bytes(b"fixture")
            cfg = {"docker_executable": "/operator/docker", "image_id": IMAGE}
            history = []
            def fake_run(argv, **kwargs):
                command = argv[1]
                history.append(command)
                def result(code=0, stdout=b"", stderr=b""):
                    return type("Result", (), {
                        "returncode": code, "stdout": stdout, "stderr": stderr})()
                if command == "info":
                    return result(stdout=b'["name=seccomp,profile=builtin"]')
                if command == "image":
                    return result(stdout=IMAGE.encode())
                if command == "create":
                    return result(stdout=cid.encode())
                if command == "inspect":
                    host = {
                        "NetworkMode": "none", "ReadonlyRootfs": True,
                        "Privileged": False, "CapDrop": ["ALL"],
                        "SecurityOpt": ["no-new-privileges"],
                        "PidsLimit": 64, "NanoCpus": 1000000000,
                        "Memory": 1024 * 1024 * 1024,
                        "Tmpfs": {"/workspace": {}, "/tmp": {}},
                        "Mounts": [{
                            "Type": "bind", "Target": "/input/source.tar",
                            "ReadOnly": True, "Source": str(archive)
                        }],
                    }
                    info = {
                        "Id": cid, "Name": "/dl-regression-" + job,
                        "Image": IMAGE,
                        "HostConfig": host,
                        "Config": {
                            "User": "65532:65532",
                            "Entrypoint": ["python", "-I", "/runner/container_entrypoint.py"],
                            "Labels": {"dockerlocal.test-job": job},
                            "Volumes": None,
                        },
                    }
                    return result(stdout=json.dumps(info).encode())
                if command == "wait":
                    return result(stdout=b"1\n")
                if command == "logs":
                    raise AssertionError("Log collection bypassed bounded reader")
                if command in ("start", "rm"):
                    return result()
                raise AssertionError("Unexpected fixed Docker operation")
            diag = {}
            def fake_bounded(docker, container_id):
                history.append("logs")
                self.assertEqual("/operator/docker", docker)
                self.assertEqual(cid, container_id)
                return safe.summarize(
                    b"ERROR: test_a (test_mcp.Server.test_a)\n"
                    b"AssertionError: raw=password\n"
                    b"Ran 1 test in 0.1s\nFAILED (errors=1)\n")
            with (patch.object(broker, "_run", side_effect=fake_run),
                  patch.object(broker, "_collect_bounded_failure_hints",
                               side_effect=fake_bounded)):
                outcome = broker._docker_job(cfg, job, archive, diagnostics=diag)
            self.assertEqual(("FAILED", 1), outcome)
            self.assertEqual(["test_mcp:test_a"], diag["cases"])
            self.assertIn("logs", history)
            self.assertLess(history.index("wait"), history.index("logs"))
            self.assertLess(history.index("logs"), history.index("rm"))
            self.assertNotIn("password", json.dumps(diag))

    def test_log_probe_is_bounded_before_memory_allocation(self):
        class DummyProc:
            def __init__(self, data):
                self.stdout = io.BytesIO(data)
                self.returncode = 0
                self.killed = False
            def kill(self):
                self.killed = True
                self.returncode = -9
            def wait(self, timeout=None):
                return self.returncode
            def poll(self):
                return self.returncode

        data = (b"ERROR: test_a (test_mcp.Server.test_a)\n"
                b"RuntimeError: private-data-here\n"
                b"Ran 1 test in 0.1s\nFAILED (errors=1)\n")
        proc = DummyProc(data)
        with patch.object(safe.subprocess, "Popen", return_value=proc) as popen:
            hints = safe.collect_bounded("C:/Docker/docker.exe", "a" * 64)
        self.assertEqual(["test_mcp:test_a"], hints["cases"])
        self.assertNotIn("private-data", json.dumps(hints))
        self.assertFalse(proc.killed)
        self.assertEqual(
            ["C:/Docker/docker.exe", "logs", "--tail", "160", "a" * 64],
            popen.call_args.args[0],
        )
        self.assertEqual(False, popen.call_args.kwargs["shell"])
        big = DummyProc(b"X" * (safe._LOG_LIMIT_BYTES + 1500))
        with patch.object(safe.subprocess, "Popen", return_value=big):
            summary = safe.collect_bounded("C:/Docker/docker.exe", "b" * 64)
        self.assertTrue(big.killed)
        self.assertEqual({"advisory_only": True, "summary_found": False}, summary)

    def test_no_raw_log_emission_or_unowned_container_query(self):
        source = (Path(__file__).resolve().parents[1] /
                  "local-test-runner" / "secure_test_runner.py").read_text()
        self.assertIn("_collect_bounded_failure_hints(docker, created_id)", source)
        self.assertIn('[docker, "rm", "--force", owned_id]', source)
        self.assertNotIn('["logs", "--tail"', source)
        self.assertEqual(
            {"advisory_only": True, "summary_found": False},
            safe.collect_bounded("ignored", "../bad"),
        )


if __name__ == "__main__":
    unittest.main()
