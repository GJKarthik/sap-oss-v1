# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2024 SAP SE
"""Integration tests for the MCP server."""

import json
import os
import subprocess
import sys
import time
import unittest
from unittest.mock import patch

# Add parent directory to path
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


class TestMCPServerUnit(unittest.TestCase):
    """Unit tests for MCP server components (no server startup required)."""

    def test_normalize_mcp_endpoint_adds_suffix(self):
        from mcp_server.server import normalize_mcp_endpoint

        self.assertEqual(normalize_mcp_endpoint("http://localhost:9110"), "http://localhost:9110/mcp")
        self.assertEqual(normalize_mcp_endpoint("http://localhost:9110/"), "http://localhost:9110/mcp")
        self.assertEqual(normalize_mcp_endpoint("http://localhost:9110/mcp"), "http://localhost:9110/mcp")
        self.assertEqual(normalize_mcp_endpoint(""), "")

    def test_parse_json_arg_handles_strings(self):
        from mcp_server.server import parse_json_arg

        self.assertEqual(parse_json_arg('["a", "b"]', []), ["a", "b"])
        self.assertEqual(parse_json_arg("invalid", []), [])
        self.assertEqual(parse_json_arg(None, "default"), "default")
        self.assertEqual(parse_json_arg({"key": "value"}, {}), {"key": "value"})

    def test_clamp_int_enforces_bounds(self):
        from mcp_server.server import clamp_int

        self.assertEqual(clamp_int(50, 10, 0, 100), 50)
        self.assertEqual(clamp_int(-5, 10, 0, 100), 0)
        self.assertEqual(clamp_int(150, 10, 0, 100), 100)
        self.assertEqual(clamp_int("invalid", 10, 0, 100), 10)
        self.assertEqual(clamp_int(None, 10, 0, 100), 10)

    def test_mcp_request_parsing(self):
        from mcp_server.server import MCPRequest

        data = {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/list",
            "params": {"foo": "bar"},
        }
        req = MCPRequest(data)

        self.assertEqual(req.jsonrpc, "2.0")
        self.assertEqual(req.id, 1)
        self.assertEqual(req.method, "tools/list")
        self.assertEqual(req.params, {"foo": "bar"})

    def test_mcp_response_to_dict(self):
        from mcp_server.server import MCPResponse

        # Success response
        resp = MCPResponse(id=1, result={"tools": []})
        self.assertEqual(resp.to_dict(), {"jsonrpc": "2.0", "id": 1, "result": {"tools": []}})

        # Error response
        resp_err = MCPResponse(id=2, error={"code": -32600, "message": "Invalid Request"})
        self.assertEqual(
            resp_err.to_dict(), {"jsonrpc": "2.0", "id": 2, "error": {"code": -32600, "message": "Invalid Request"}}
        )


class TestMCPServerTools(unittest.TestCase):
    """Test MCP server tool handlers."""

    def setUp(self):
        from mcp_server.server import MCPServer

        self.server = MCPServer()

    def test_tools_registered(self):
        """Verify all expected tools are registered."""
        expected_tools = [
            "data_quality_check",
            "schema_analysis",
            "data_profiling",
            "anomaly_detection",
            "generate_cleaning_query",
            "ai_chat",
            "mangle_query",
            "kuzu_index",
            "kuzu_query",
        ]
        for tool_name in expected_tools:
            self.assertIn(tool_name, self.server.tools, f"Tool '{tool_name}' should be registered")

    def test_data_quality_check_requires_table_name(self):
        result = self.server._handle_data_quality_check({})
        self.assertIn("error", result)
        self.assertEqual(result["error"], "table_name is required")

    def test_data_quality_check_returns_valid_structure(self):
        result = self.server._handle_data_quality_check({"table_name": "Users"})

        self.assertIn("table", result)
        self.assertEqual(result["table"], "Users")
        self.assertIn("checks", result)
        self.assertIn("overall_status", result)
        self.assertIsInstance(result["checks"], list)

    def test_data_quality_check_with_custom_checks(self):
        result = self.server._handle_data_quality_check(
            {"table_name": "Orders", "checks": '["completeness", "accuracy"]'}
        )

        self.assertEqual(result["table"], "Orders")
        check_names = [c["check"] for c in result["checks"]]
        self.assertIn("completeness", check_names)
        self.assertIn("accuracy", check_names)

    def test_schema_analysis_returns_recommendations(self):
        result = self.server._handle_schema_analysis({"schema_definition": '{"tables": []}'})

        self.assertIn("recommendations", result)
        self.assertIsInstance(result["recommendations"], list)
        self.assertEqual(result["status"], "analyzed")

    def test_data_profiling_requires_table_name(self):
        result = self.server._handle_data_profiling({})
        self.assertIn("error", result)

    def test_anomaly_detection_requires_table_and_column(self):
        result = self.server._handle_anomaly_detection({})
        self.assertIn("error", result)

        result = self.server._handle_anomaly_detection({"table_name": "Users"})
        self.assertIn("error", result)

    def test_generate_cleaning_query_returns_sql(self):
        result = self.server._handle_generate_cleaning_query(
            {"issue_description": "Remove duplicates", "table_name": "Users"}
        )

        self.assertIn("suggested_query", result)
        self.assertIn("Users", result["suggested_query"])
        self.assertEqual(result["status"], "query_generated")

    def test_mangle_query_returns_service_registry(self):
        result = self.server._handle_mangle_query({"predicate": "service_registry"})

        self.assertEqual(result["predicate"], "service_registry")
        self.assertIn("results", result)
        self.assertIsInstance(result["results"], list)

    def test_mangle_query_service_available(self):
        result = self.server._handle_mangle_query({"predicate": "service_available"})

        self.assertEqual(result["predicate"], "service_available")
        self.assertIn("results", result)

    def test_kuzu_index_requires_schema(self):
        result = self.server._handle_kuzu_index({})
        self.assertIn("error", result)

        result = self.server._handle_kuzu_index({"schema_definition": ""})
        self.assertIn("error", result)

    def test_kuzu_query_requires_cypher(self):
        result = self.server._handle_kuzu_query({})
        self.assertIn("error", result)

    def test_kuzu_query_blocks_write_operations(self):
        for cypher in ["CREATE (n:Node)", "MERGE (n:Node)", "DELETE n", "SET n.prop = 1", "DROP TABLE x"]:
            result = self.server._handle_kuzu_query({"cypher": cypher})
            self.assertIn("error", result)
            self.assertIn("not permitted", result["error"])


class TestMCPServerRequestHandling(unittest.TestCase):
    """Test MCP server request handling."""

    def setUp(self):
        from mcp_server.server import MCPServer

        self.server = MCPServer()

    def test_initialize_returns_capabilities(self):
        from mcp_server.server import MCPRequest

        req = MCPRequest({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}})
        resp = self.server.handle_request(req)

        self.assertIsNone(resp.error)
        self.assertIn("protocolVersion", resp.result)
        self.assertIn("capabilities", resp.result)
        self.assertIn("serverInfo", resp.result)

    def test_tools_list_returns_all_tools(self):
        from mcp_server.server import MCPRequest

        req = MCPRequest({"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}})
        resp = self.server.handle_request(req)

        self.assertIsNone(resp.error)
        self.assertIn("tools", resp.result)
        self.assertGreaterEqual(len(resp.result["tools"]), 9)

    def test_tools_call_executes_handler(self):
        from mcp_server.server import MCPRequest

        req = MCPRequest(
            {
                "jsonrpc": "2.0",
                "id": 3,
                "method": "tools/call",
                "params": {"name": "data_quality_check", "arguments": {"table_name": "TestTable"}},
            }
        )
        resp = self.server.handle_request(req)

        self.assertIsNone(resp.error)
        self.assertIn("content", resp.result)
        content = json.loads(resp.result["content"][0]["text"])
        self.assertEqual(content["table"], "TestTable")

    def test_tools_call_unknown_tool_returns_error(self):
        from mcp_server.server import MCPRequest

        req = MCPRequest(
            {
                "jsonrpc": "2.0",
                "id": 4,
                "method": "tools/call",
                "params": {"name": "nonexistent_tool", "arguments": {}},
            }
        )
        resp = self.server.handle_request(req)

        self.assertIsNotNone(resp.error)
        self.assertEqual(resp.error["code"], -32602)
        self.assertIn("Unknown tool", resp.error["message"])

    def test_resources_list_returns_resources(self):
        from mcp_server.server import MCPRequest

        req = MCPRequest({"jsonrpc": "2.0", "id": 5, "method": "resources/list", "params": {}})
        resp = self.server.handle_request(req)

        self.assertIsNone(resp.error)
        self.assertIn("resources", resp.result)
        self.assertGreaterEqual(len(resp.result["resources"]), 3)

    def test_resources_read_mangle_facts(self):
        from mcp_server.server import MCPRequest

        req = MCPRequest({"jsonrpc": "2.0", "id": 6, "method": "resources/read", "params": {"uri": "mangle://facts"}})
        resp = self.server.handle_request(req)

        self.assertIsNone(resp.error)
        self.assertIn("contents", resp.result)
        facts = json.loads(resp.result["contents"][0]["text"])
        self.assertIn("service_registry", facts)
        self.assertIn("quality_rules", facts)

    def test_invalid_jsonrpc_version(self):
        from mcp_server.server import MCPRequest

        req = MCPRequest({"jsonrpc": "1.0", "id": 7, "method": "initialize", "params": {}})
        resp = self.server.handle_request(req)

        self.assertIsNotNone(resp.error)
        self.assertEqual(resp.error["code"], -32600)

    def test_method_not_found(self):
        from mcp_server.server import MCPRequest

        req = MCPRequest({"jsonrpc": "2.0", "id": 8, "method": "nonexistent/method", "params": {}})
        resp = self.server.handle_request(req)

        self.assertIsNotNone(resp.error)
        self.assertEqual(resp.error["code"], -32601)


class TestMCPAuthentication(unittest.TestCase):
    """Test MCP server authentication."""

    def test_verify_auth_no_token_configured(self):
        """When MCP_AUTH_TOKEN is not set, auth passes (dev mode)."""
        from mcp_server.server import _verify_auth, MCP_AUTH_TOKEN

        # Create a mock handler
        class MockHandler:
            client_address = ("192.168.1.100", 12345)
            headers = {}

        with patch("mcp_server.server.MCP_AUTH_TOKEN", None):
            with patch("mcp_server.server.MCP_AUTH_REQUIRED", False):
                handler = MockHandler()
                is_auth, error = _verify_auth(handler)
                # In dev mode without token, auth should pass
                self.assertTrue(is_auth)
                self.assertIsNone(error)

    def test_verify_auth_required_but_no_token(self):
        """When MCP_AUTH_REQUIRED is true but no token configured, should fail."""
        from mcp_server.server import _verify_auth

        class MockHandler:
            client_address = ("192.168.1.100", 12345)
            headers = {}

        with patch("mcp_server.server.MCP_AUTH_TOKEN", None):
            with patch("mcp_server.server.MCP_AUTH_REQUIRED", True):
                handler = MockHandler()
                is_auth, error = _verify_auth(handler)
                self.assertFalse(is_auth)
                self.assertIn("not configured", error)

    def test_verify_auth_bypass_host(self):
        """Requests from bypass hosts should pass without token."""
        from mcp_server.server import _verify_auth

        class MockHandler:
            client_address = ("127.0.0.1", 12345)
            headers = {}

        with patch("mcp_server.server.MCP_AUTH_TOKEN", "secret-token"):
            with patch("mcp_server.server.MCP_AUTH_BYPASS_HOSTS", {"127.0.0.1", "localhost"}):
                handler = MockHandler()
                is_auth, error = _verify_auth(handler)
                self.assertTrue(is_auth)
                self.assertIsNone(error)

    def test_verify_auth_missing_header(self):
        """Missing Authorization header should fail."""
        from mcp_server.server import _verify_auth

        class MockHandler:
            client_address = ("192.168.1.100", 12345)

            class Headers:
                def get(self, name, default=""):
                    return default

            headers = Headers()

        with patch("mcp_server.server.MCP_AUTH_TOKEN", "secret-token"):
            with patch("mcp_server.server.MCP_AUTH_BYPASS_HOSTS", set()):
                handler = MockHandler()
                is_auth, error = _verify_auth(handler)
                self.assertFalse(is_auth)
                self.assertIn("Missing Authorization", error)

    def test_verify_auth_invalid_format(self):
        """Invalid Authorization header format should fail."""
        from mcp_server.server import _verify_auth

        class MockHandler:
            client_address = ("192.168.1.100", 12345)

            class Headers:
                def get(self, name, default=""):
                    if name == "Authorization":
                        return "Basic abc123"
                    return default

            headers = Headers()

        with patch("mcp_server.server.MCP_AUTH_TOKEN", "secret-token"):
            with patch("mcp_server.server.MCP_AUTH_BYPASS_HOSTS", set()):
                handler = MockHandler()
                is_auth, error = _verify_auth(handler)
                self.assertFalse(is_auth)
                self.assertIn("Invalid Authorization", error)

    def test_verify_auth_wrong_token(self):
        """Wrong token should fail."""
        from mcp_server.server import _verify_auth

        class MockHandler:
            client_address = ("192.168.1.100", 12345)

            class Headers:
                def get(self, name, default=""):
                    if name == "Authorization":
                        return "Bearer wrong-token"
                    return default

            headers = Headers()

        with patch("mcp_server.server.MCP_AUTH_TOKEN", "secret-token"):
            with patch("mcp_server.server.MCP_AUTH_BYPASS_HOSTS", set()):
                handler = MockHandler()
                is_auth, error = _verify_auth(handler)
                self.assertFalse(is_auth)
                self.assertIn("Invalid authentication", error)

    def test_verify_auth_correct_token(self):
        """Correct token should pass."""
        from mcp_server.server import _verify_auth

        class MockHandler:
            client_address = ("192.168.1.100", 12345)

            class Headers:
                def get(self, name, default=""):
                    if name == "Authorization":
                        return "Bearer secret-token"
                    return default

            headers = Headers()

        with patch("mcp_server.server.MCP_AUTH_TOKEN", "secret-token"):
            with patch("mcp_server.server.MCP_AUTH_BYPASS_HOSTS", set()):
                handler = MockHandler()
                is_auth, error = _verify_auth(handler)
                self.assertTrue(is_auth)
                self.assertIsNone(error)


class TestMCPServerFacts(unittest.TestCase):
    """Test MCP server fact management."""

    def setUp(self):
        from mcp_server.server import MCPServer

        self.server = MCPServer()

    def test_service_registry_initialized(self):
        self.assertIn("service_registry", self.server.facts)
        self.assertIsInstance(self.server.facts["service_registry"], list)
        self.assertGreater(len(self.server.facts["service_registry"]), 0)

    def test_quality_rules_initialized(self):
        self.assertIn("quality_rules", self.server.facts)
        rules = {r["rule"]: r["threshold"] for r in self.server.facts["quality_rules"]}

        self.assertEqual(rules["completeness"], 95.0)
        self.assertEqual(rules["accuracy"], 99.0)
        self.assertEqual(rules["consistency"], 98.0)

    def test_tool_invocation_tracking(self):
        initial_count = len(self.server.facts.get("tool_invocation", []))

        self.server._handle_data_quality_check({"table_name": "TestTable"})

        new_count = len(self.server.facts.get("tool_invocation", []))
        self.assertEqual(new_count, initial_count + 1)

        last_invocation = self.server.facts["tool_invocation"][-1]
        self.assertEqual(last_invocation["tool"], "data_quality_check")
        self.assertEqual(last_invocation["table"], "TestTable")
        self.assertIn("timestamp", last_invocation)


if __name__ == "__main__":
    unittest.main()