import json
import os
import sys
import unittest
import urllib.error
from unittest.mock import patch


sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import agent.ui5_ngx_agent as ui5_agent


class _MockHttpResponse:
    def __init__(self, payload: dict | None = None):
        self._payload = payload or {}

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc, tb):
        return False

    def read(self):
        return json.dumps(self._payload).encode("utf-8")


class TestUrlValidation(unittest.TestCase):
    def test_rejects_private_ipv4_ranges(self):
        for value in (
            "https://10.1.2.3/api",
            "https://192.168.10.20/api",
            "https://172.20.1.5/api",
        ):
            with self.assertRaises(ValueError):
                ui5_agent._validate_remote_url(value, "HANA_BASE_URL")

    def test_rejects_link_local_and_unique_local_ipv6(self):
        for value in (
            "https://[fe80::1]/api",
            "https://[fd00::1]/api",
        ):
            with self.assertRaises(ValueError):
                ui5_agent._validate_remote_url(value, "HANA_BASE_URL")

    def test_allows_public_https_hostname(self):
        value = ui5_agent._validate_remote_url("https://api.sap.com/v1", "HANA_BASE_URL")
        self.assertEqual(value, "https://api.sap.com/v1")


class TestHanaTokenRefresh(unittest.TestCase):
    def test_hana_sql_retries_once_on_401(self):
        unauthorized = urllib.error.HTTPError(
            url="https://hana.example.test/v1/statement",
            code=401,
            msg="Unauthorized",
            hdrs=None,
            fp=None,
        )

        with patch.object(ui5_agent, "_HANA_BASE_URL", "https://hana.example.test"):
            with patch("agent.ui5_ngx_agent._hana_get_token", side_effect=["stale-token", "fresh-token"]) as mocked_token:
                with patch("urllib.request.urlopen", side_effect=[unauthorized, _MockHttpResponse()]):
                    ui5_agent._hana_sql("SELECT 1")

        self.assertEqual(mocked_token.call_count, 2)


if __name__ == "__main__":
    unittest.main()
