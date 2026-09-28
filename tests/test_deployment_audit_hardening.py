import json
import unittest
from unittest import mock

import server


class DeploymentAuditComposeDriftTests(unittest.TestCase):
    def _json_side_effect(self, method, path, *, query=None, timeout=30):
        if path == "/containers/json":
            return [
                {
                    "Id": "a" * 64,
                    "Names": ["/avanza-mcp-gateway"],
                    "Image": "node:26.9.0-alpine",
                    "ImageID": "sha256:" + ("1" * 64),
                    "State": "running",
                    "Status": "Up 1 hour",
                    "Labels": {
                        "com.docker.compose.project": "avanza-mcp-public",
                        "com.docker.compose.service": "gateway",
                    },
                }
            ]
        if path == "/images/json":
            return []
        if path.startswith("/containers/") and path.endswith("/json"):
            return {
                "Image": "sha256:" + ("1" * 64),
                "Config": {
                    "Image": "node:26.9.0-alpine",
                    "Labels": {
                        "com.docker.compose.project": "avanza-mcp-public",
                        "com.docker.compose.service": "gateway",
                        "com.docker.compose.config-hash": "oldhash",
                    },
                },
            }
        if path == "/dockerlocal/runtime-source-drift":
            return {"status": "ok", "checked_files": 0, "drift": [], "errors": []}
        raise AssertionError(f"unexpected Docker API request: {method} {path}")

    def test_reports_desired_compose_hash_and_image_drift(self):
        desired = {
            "status": "succeeded",
            "projects": {
                "avanza-mcp-public": {
                    "services": {
                        "gateway": {
                            "image": "node:26.10.0-alpine",
                            "config_hash": "newhash",
                        }
                    }
                }
            },
            "errors": [],
        }

        with mock.patch.object(server, "_json", side_effect=self._json_side_effect):
            with mock.patch.object(server, "_runner_request", return_value=desired):
                payload = json.loads(server.mcp_deployment_audit())

        self.assertEqual(payload["summary"]["compose_config_drift"], 1)
        drift = payload["compose_config_drift"][0]
        self.assertEqual(drift["project"], "avanza-mcp-public")
        self.assertEqual(drift["service"], "gateway")
        self.assertTrue(drift["image_mismatch"])
        self.assertTrue(drift["config_hash_mismatch"])
        self.assertEqual(drift["desired_image"], "node:26.10.0-alpine")
        self.assertEqual(drift["running_configured_image"], "node:26.9.0-alpine")

    def test_no_compose_drift_when_desired_state_matches_running_container(self):
        desired = {
            "status": "succeeded",
            "projects": {
                "avanza-mcp-public": {
                    "services": {
                        "gateway": {
                            "image": "node:26.9.0-alpine",
                            "config_hash": "oldhash",
                        }
                    }
                }
            },
            "errors": [],
        }

        with mock.patch.object(server, "_json", side_effect=self._json_side_effect):
            with mock.patch.object(server, "_runner_request", return_value=desired):
                payload = json.loads(server.mcp_deployment_audit())

        self.assertEqual(payload["compose_config_drift"], [])
        self.assertEqual(payload["summary"]["compose_config_drift"], 0)


if __name__ == "__main__":
    unittest.main()
