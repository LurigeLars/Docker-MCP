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


    def test_exact_public_read_shapes(self):
        self.assertTrue(proxy.allowed("GET", "/v1.54/containers/json?all=1"))
        self.assertTrue(proxy.allowed("GET", "/v1.54/containers/json?all=0"))
        self.assertTrue(
            proxy.allowed(
                "GET",
                "/v1.54/containers/example/logs?stdout=1&stderr=1&timestamps=1&tail=200",
            )
        )
        self.assertTrue(
            proxy.allowed("GET", "/v1.54/containers/example/stats?stream=false")
        )
        self.assertTrue(proxy.allowed("GET", "/v1.54/images/json?all=0"))
        self.assertTrue(proxy.allowed("GET", "/v1.54/containers/example/json"))
        self.assertTrue(proxy.allowed("GET", "/v1.54/images/example/json"))

    def test_streaming_and_unbounded_queries_are_rejected(self):
        self.assertFalse(proxy.allowed("GET", "/v1.54/containers/json"))
        self.assertFalse(
            proxy.allowed(
                "GET",
                "/v1.54/containers/example/logs?stdout=1&stderr=1&timestamps=1&tail=all",
            )
        )
        self.assertFalse(
            proxy.allowed(
                "GET",
                "/v1.54/containers/example/logs?stdout=1&stderr=1&timestamps=1&tail=200&follow=1",
            )
        )
        self.assertFalse(
            proxy.allowed("GET", "/v1.54/containers/example/stats?stream=true")
        )
        self.assertFalse(proxy.allowed("GET", "/v1.54/containers/example/stats"))
        self.assertFalse(proxy.allowed("GET", "/v1.54/images/json?all=1"))

    def test_restart_is_limited_to_timeout_only(self):
        self.assertTrue(
            proxy.allowed("POST", "/v1.54/containers/example/restart?t=10")
        )
        self.assertTrue(
            proxy.allowed("POST", "/v1.54/containers/example/restart?t=0")
        )
        self.assertFalse(
            proxy.allowed("POST", "/v1.54/containers/example/restart")
        )
        self.assertFalse(
            proxy.allowed("POST", "/v1.54/containers/example/restart?t=61")
        )
        self.assertFalse(
            proxy.allowed(
                "POST",
                "/v1.54/containers/example/restart?t=0&signal=SIGKILL",
            )
        )

    def test_image_pull_rejects_import_and_extra_parameters(self):
        self.assertTrue(
            proxy.allowed("POST", "/v1.54/images/create?fromImage=node:26-alpine")
        )
        self.assertFalse(
            proxy.allowed(
                "POST",
                "/v1.54/images/create?fromSrc=http://169.254.169.254/latest/meta-data/&repo=x",
            )
        )
        self.assertFalse(
            proxy.allowed("POST", "/v1.54/images/create?fromSrc=-&repo=x")
        )
        self.assertFalse(
            proxy.allowed(
                "POST",
                "/v1.54/images/create?fromImage=node:26-alpine&platform=linux/amd64",
            )
        )

    def test_prune_is_dangling_only(self):
        dangling = "%7B%22dangling%22%3A%5B%22true%22%5D%7D"
        not_dangling = "%7B%22dangling%22%3A%5B%22false%22%5D%7D"
        self.assertTrue(
            proxy.allowed("POST", f"/v1.54/images/prune?filters={dangling}")
        )
        self.assertFalse(proxy.allowed("POST", "/v1.54/images/prune"))
        self.assertFalse(
            proxy.allowed("POST", f"/v1.54/images/prune?filters={not_dangling}")
        )
        self.assertFalse(
            proxy.allowed(
                "POST",
                f"/v1.54/images/prune?filters={dangling}&extra=1",
            )
        )

    def test_dangerous_engine_operations_are_denied(self):
        denied = [
            ("POST", "/v1.54/containers/create"),
            ("POST", "/v1.54/containers/example/start"),
            ("POST", "/v1.54/containers/example/stop"),
            ("POST", "/v1.54/containers/example/kill"),
            ("POST", "/v1.54/containers/example/exec"),
            ("POST", "/v1.54/exec/example/start"),
            ("DELETE", "/v1.54/containers/example?force=1"),
            ("POST", "/v1.54/volumes/create"),
            ("DELETE", "/v1.54/volumes/example"),
            ("POST", "/v1.54/networks/create"),
            ("DELETE", "/v1.54/networks/example"),
            ("POST", "/v1.54/build"),
            ("POST", "/v1.54/commit"),
            ("POST", "/v1.54/images/load"),
            ("DELETE", "/v1.54/images/example"),
        ]
        for method, target in denied:
            with self.subTest(method=method, target=target):
                self.assertFalse(proxy.allowed(method, target))

    def test_only_immutable_image_exports_are_allowed(self):
        self.assertTrue(
            proxy.allowed("GET", f"/v1.54/images/{IMAGE_ID}/get")
        )
        self.assertFalse(
            proxy.allowed("GET", "/v1.54/images/node:26.10.0-alpine/get")
        )
        self.assertFalse(
            proxy.allowed("GET", f"/v1.54/images/{IMAGE_ID}/get?extra=1")
        )

    def test_absolute_form_and_queries_on_no_query_routes_are_rejected(self):
        self.assertFalse(proxy.allowed("GET", "http://docker/version"))
        self.assertFalse(proxy.allowed("GET", "/version?x=1"))
        self.assertFalse(proxy.allowed("GET", "/info#fragment"))

    def test_custom_routes_have_exact_request_shapes(self):
        self.assertTrue(
            proxy.allowed_custom("GET", "/dockerlocal/runtime-source-drift")
        )
        self.assertFalse(
            proxy.allowed_custom(
                "GET", "/dockerlocal/runtime-source-drift?extra=1"
            )
        )
        self.assertTrue(
            proxy.allowed_custom(
                "POST",
                "/dockerlocal/cleanup-stale-mcp-probes?min_age_seconds=900",
            )
        )
        self.assertFalse(
            proxy.allowed_custom(
                "POST",
                "/dockerlocal/cleanup-stale-mcp-probes?min_age_seconds=299",
            )
        )
        self.assertFalse(
            proxy.allowed_custom(
                "POST",
                "/dockerlocal/cleanup-stale-mcp-probes?min_age_seconds=900&extra=1",
            )
        )
        self.assertTrue(
            proxy.allowed_custom(
                "POST", "/dockerlocal/cleanup-superseded-images"
            )
        )
        self.assertFalse(
            proxy.allowed_custom(
                "POST", "/dockerlocal/cleanup-superseded-images?extra=1"
            )
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
