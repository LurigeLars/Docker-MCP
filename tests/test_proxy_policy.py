import unittest

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


if __name__ == "__main__":
    unittest.main()
