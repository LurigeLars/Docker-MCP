import base64
import json
import unittest
from unittest import mock

import proxy


IMAGE_ID = "sha256:" + ("a" * 64)


class ProxyPolicyTests(unittest.TestCase):
    def test_scout_export_allows_one_immutable_image_id(self):
        self.assertTrue(
            proxy.allowed("GET", f"/v1.54/images/get?names={IMAGE_ID}")
        )

    def test_scout_export_rejects_broad_or_mutable_requests(self):
        self.assertFalse(proxy.allowed("GET", "/v1.54/images/get"))
        self.assertFalse(proxy.allowed("GET", "/v1.54/images/get?names=node:26-alpine"))
        self.assertFalse(
            proxy.allowed(
                "GET",
                f"/v1.54/images/get?names={IMAGE_ID}&names={IMAGE_ID}",
            )
        )
        self.assertFalse(
            proxy.allowed("GET", f"/v1.54/images/get?names={IMAGE_ID}&extra=1")
        )
        self.assertFalse(
            proxy.allowed("POST", f"/v1.54/images/get?names={IMAGE_ID}")
        )

    def test_existing_single_image_export_route_still_works(self):
        self.assertTrue(
            proxy.allowed("GET", f"/v1.54/images/{IMAGE_ID}/get")
        )


class RuntimeSourceDriftTests(unittest.TestCase):
    def test_detects_newer_read_only_bind_mounted_command_source(self):
        rows = [
            {
                "Id": "a" * 64,
                "State": "running",
                "Names": ["/gdrive-gateway"],
                "Labels": {
                    "com.docker.compose.project": "gdrive-public",
                    "com.docker.compose.service": "gateway",
                },
            }
        ]
        inspect = {
            "Name": "/gdrive-gateway",
            "State": {"StartedAt": "2026-09-27T20:00:00Z"},
            "Path": "docker-entrypoint.sh",
            "Args": ["sh", "-c", "exec node /app/gateway.mjs"],
            "Config": {
                "Cmd": ["sh", "-c", "exec node /app/gateway.mjs"],
                "Labels": rows[0]["Labels"],
            },
            "Mounts": [
                {
                    "Type": "bind",
                    "Destination": "/app",
                    "RW": False,
                }
            ],
        }
        stat = base64.b64encode(
            json.dumps(
                {
                    "name": "gateway.mjs",
                    "size": 123,
                    "mode": 0,
                    "mtime": "2026-09-27T20:05:00Z",
                    "linkTarget": "",
                }
            ).encode()
        ).decode()

        with mock.patch.object(proxy, "engine_json", side_effect=[rows, inspect]):
            with mock.patch.object(
                proxy,
                "engine_request",
                return_value=(200, {"x-docker-container-path-stat": stat}, b""),
            ):
                result = proxy.runtime_source_drift()

        self.assertEqual(result["checked_files"], 1)
        self.assertEqual(len(result["drift"]), 1)
        self.assertEqual(result["drift"][0]["name"], "gdrive-gateway")
        self.assertEqual(result["drift"][0]["container_path"], "/app/gateway.mjs")

    def test_ignores_source_older_than_process_and_writable_mounts(self):
        inspect = {
            "Name": "/gateway",
            "State": {"StartedAt": "2026-09-27T20:05:00Z"},
            "Args": ["node", "/app/gateway.mjs", "/work/helper.py"],
            "Config": {"Cmd": ["node", "/app/gateway.mjs", "/work/helper.py"]},
            "Mounts": [
                {"Type": "bind", "Destination": "/app", "RW": False},
                {"Type": "bind", "Destination": "/work", "RW": True},
            ],
        }
        self.assertEqual(proxy.command_source_paths(inspect), ["/app/gateway.mjs"])

        rows = [{"Id": "b" * 64, "State": "running", "Names": ["/gateway"]}]
        stat = base64.b64encode(
            json.dumps({"mtime": "2026-09-27T20:04:00Z"}).encode()
        ).decode()
        with mock.patch.object(proxy, "engine_json", side_effect=[rows, inspect]):
            with mock.patch.object(
                proxy,
                "engine_request",
                return_value=(200, {"x-docker-container-path-stat": stat}, b""),
            ):
                result = proxy.runtime_source_drift()

        self.assertEqual(result["checked_files"], 1)
        self.assertEqual(result["drift"], [])


if __name__ == "__main__":
    unittest.main()
