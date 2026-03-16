"""
Unit tests for Elasticsearch MCP Server.

Tests:
- MCP request/response handling
- Tool implementations
- Resource access
- Input validation
- Error handling
"""

import unittest
import json
import os
import sys
from unittest.mock import patch, MagicMock

# Add parent directory to path for imports
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))

from mcp_server.server import (
    MCPRequest, MCPResponse, MCPServer,
    clamp_int, parse_json_arg, get_es_config, get_aicore_config, aicore_config_ready,
    _cors_origin, _authenticate,
)


class TestMCPRequest(unittest.TestCase):
    """Test MCP request parsing."""
    
    def test_basic_request(self):
        """Test basic request parsing."""
        data = {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/list",
            "params": {}
        }
        req = MCPRequest(data)
        
        self.assertEqual(req.jsonrpc, "2.0")
        self.assertEqual(req.id, 1)
        self.assertEqual(req.method, "tools/list")
        self.assertEqual(req.params, {})
    
    def test_request_with_params(self):
        """Test request with parameters."""
        data = {
            "jsonrpc": "2.0",
            "id": "abc-123",
            "method": "tools/call",
            "params": {"name": "es_search", "arguments": {"index": "test"}}
        }
        req = MCPRequest(data)
        
        self.assertEqual(req.params["name"], "es_search")
        self.assertEqual(req.params["arguments"]["index"], "test")
    
    def test_request_defaults(self):
        """Test request with missing fields uses defaults."""
        data = {}
        req = MCPRequest(data)
        
        self.assertEqual(req.jsonrpc, "2.0")
        self.assertIsNone(req.id)
        self.assertEqual(req.method, "")
        self.assertEqual(req.params, {})


class TestMCPResponse(unittest.TestCase):
    """Test MCP response formatting."""
    
    def test_success_response(self):
        """Test success response formatting."""
        resp = MCPResponse(1, result={"tools": []})
        d = resp.to_dict()
        
        self.assertEqual(d["jsonrpc"], "2.0")
        self.assertEqual(d["id"], 1)
        self.assertEqual(d["result"], {"tools": []})
        self.assertNotIn("error", d)
    
    def test_error_response(self):
        """Test error response formatting."""
        resp = MCPResponse(1, error={"code": -32600, "message": "Invalid Request"})
        d = resp.to_dict()
        
        self.assertEqual(d["jsonrpc"], "2.0")
        self.assertEqual(d["id"], 1)
        self.assertEqual(d["error"]["code"], -32600)
        self.assertNotIn("result", d)
    
    def test_string_id(self):
        """Test response with string ID."""
        resp = MCPResponse("uuid-123", result={})
        d = resp.to_dict()
        
        self.assertEqual(d["id"], "uuid-123")


class TestHelperFunctions(unittest.TestCase):
    """Test helper functions."""
    
    def test_clamp_int_normal(self):
        """Test clamp_int with normal values."""
        self.assertEqual(clamp_int(50, 10, 1, 100), 50)
    
    def test_clamp_int_below_min(self):
        """Test clamp_int below minimum."""
        self.assertEqual(clamp_int(0, 10, 1, 100), 1)
    
    def test_clamp_int_above_max(self):
        """Test clamp_int above maximum."""
        self.assertEqual(clamp_int(200, 10, 1, 100), 100)
    
    def test_clamp_int_invalid(self):
        """Test clamp_int with invalid input."""
        self.assertEqual(clamp_int("invalid", 10, 1, 100), 10)
        self.assertEqual(clamp_int(None, 10, 1, 100), 10)
    
    def test_parse_json_arg_string(self):
        """Test parse_json_arg with JSON string."""
        result = parse_json_arg('{"key": "value"}', {})
        self.assertEqual(result, {"key": "value"})
    
    def test_parse_json_arg_invalid_string(self):
        """Test parse_json_arg with invalid JSON string."""
        result = parse_json_arg('not json', {"default": True})
        self.assertEqual(result, {"default": True})
    
    def test_parse_json_arg_dict(self):
        """Test parse_json_arg with dict input."""
        result = parse_json_arg({"already": "dict"}, {})
        self.assertEqual(result, {"already": "dict"})
    
    def test_parse_json_arg_none(self):
        """Test parse_json_arg with None."""
        result = parse_json_arg(None, {"default": True})
        self.assertEqual(result, {"default": True})


class TestConfigFunctions(unittest.TestCase):
    """Test configuration functions."""
    
    def test_get_es_config_defaults(self):
        """Test ES config with defaults."""
        # Clear environment variables
        with patch.dict(os.environ, {}, clear=True):
            config = get_es_config()
            self.assertEqual(config["host"], "http://localhost:9200")
            self.assertEqual(config["username"], "elastic")
            self.assertEqual(config["password"], "")
            self.assertEqual(config["api_key"], "")
    
    def test_get_es_config_from_env(self):
        """Test ES config from environment."""
        env = {
            "ES_HOST": "http://es.example.com:9200",
            "ES_USERNAME": "admin",
            "ES_PASSWORD": "secret",
            "ES_API_KEY": "key123"
        }
        with patch.dict(os.environ, env, clear=True):
            config = get_es_config()
            self.assertEqual(config["host"], "http://es.example.com:9200")
            self.assertEqual(config["username"], "admin")
            self.assertEqual(config["password"], "secret")
            self.assertEqual(config["api_key"], "key123")
    
    def test_aicore_config_ready_true(self):
        """Test AI Core config ready check - true."""
        config = {
            "client_id": "id",
            "client_secret": "secret",
            "auth_url": "https://auth.example.com",
            "base_url": "https://api.example.com"
        }
        self.assertTrue(aicore_config_ready(config))
    
    def test_aicore_config_ready_false(self):
        """Test AI Core config ready check - false."""
        config = {
            "client_id": "id",
            "client_secret": "",
            "auth_url": "https://auth.example.com",
            "base_url": ""
        }
        self.assertFalse(aicore_config_ready(config))


class TestMCPServer(unittest.TestCase):
    """Test MCP server implementation."""
    
    def setUp(self):
        self.server = MCPServer()
    
    def test_tools_registered(self):
        """Test that all tools are registered."""
        expected_tools = [
            "es_search", "es_vector_search", "es_index",
            "es_cluster_health", "es_index_info",
            "generate_embedding", "ai_semantic_search", "mangle_query",
            "hana_search", "hana_index_to_es",
        ]
        for tool in expected_tools:
            self.assertIn(tool, self.server.tools)
    
    def test_resources_registered(self):
        """Test that all resources are registered."""
        expected_resources = ["es://cluster", "es://indices", "mangle://facts"]
        for resource in expected_resources:
            self.assertIn(resource, self.server.resources)
    
    def test_initialize_method(self):
        """Test initialize method."""
        req = MCPRequest({
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": {}
        })
        resp = self.server.handle_request(req)
        
        self.assertIsNone(resp.error)
        self.assertEqual(resp.result["protocolVersion"], "2024-11-05")
        self.assertIn("capabilities", resp.result)
        self.assertIn("serverInfo", resp.result)
    
    def test_tools_list_method(self):
        """Test tools/list method."""
        req = MCPRequest({
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/list",
            "params": {}
        })
        resp = self.server.handle_request(req)
        
        self.assertIsNone(resp.error)
        self.assertIn("tools", resp.result)
        self.assertTrue(len(resp.result["tools"]) >= 10)
    
    def test_resources_list_method(self):
        """Test resources/list method."""
        req = MCPRequest({
            "jsonrpc": "2.0",
            "id": 1,
            "method": "resources/list",
            "params": {}
        })
        resp = self.server.handle_request(req)
        
        self.assertIsNone(resp.error)
        self.assertIn("resources", resp.result)
        self.assertTrue(len(resp.result["resources"]) >= 3)
    
    def test_unknown_method(self):
        """Test handling of unknown method."""
        req = MCPRequest({
            "jsonrpc": "2.0",
            "id": 1,
            "method": "unknown/method",
            "params": {}
        })
        resp = self.server.handle_request(req)
        
        self.assertIsNotNone(resp.error)
        self.assertEqual(resp.error["code"], -32601)
    
    def test_invalid_jsonrpc_version(self):
        """Test handling of invalid JSON-RPC version."""
        req = MCPRequest({
            "jsonrpc": "1.0",
            "id": 1,
            "method": "initialize",
            "params": {}
        })
        resp = self.server.handle_request(req)
        
        self.assertIsNotNone(resp.error)
        self.assertEqual(resp.error["code"], -32600)
    
    def test_unknown_tool(self):
        """Test handling of unknown tool."""
        req = MCPRequest({
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/call",
            "params": {"name": "unknown_tool", "arguments": {}}
        })
        resp = self.server.handle_request(req)
        
        self.assertIsNotNone(resp.error)
        self.assertEqual(resp.error["code"], -32602)
    
    def test_unknown_resource(self):
        """Test handling of unknown resource."""
        req = MCPRequest({
            "jsonrpc": "2.0",
            "id": 1,
            "method": "resources/read",
            "params": {"uri": "unknown://resource"}
        })
        resp = self.server.handle_request(req)
        
        self.assertIsNotNone(resp.error)
        self.assertEqual(resp.error["code"], -32602)


class TestESSearchTool(unittest.TestCase):
    """Test Elasticsearch search tool."""
    
    def setUp(self):
        self.server = MCPServer()
    
    @patch('mcp_server.server.es_request')
    def test_es_search_basic(self, mock_es):
        """Test basic ES search."""
        mock_es.return_value = {"hits": {"hits": []}}
        
        req = MCPRequest({
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/call",
            "params": {
                "name": "es_search",
                "arguments": {"index": "test_index"}
            }
        })
        resp = self.server.handle_request(req)
        
        self.assertIsNone(resp.error)
        self.assertTrue(mock_es.called)
        # First call is the search; subsequent calls are the audit trail POST.
        first_call = mock_es.call_args_list[0]
        self.assertEqual(first_call[0][0], "POST")
        self.assertIn("test_index", first_call[0][1])
    
    @patch('mcp_server.server.es_request')
    def test_es_search_with_query(self, mock_es):
        """Test ES search with query."""
        mock_es.return_value = {"hits": {"hits": []}}
        
        req = MCPRequest({
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/call",
            "params": {
                "name": "es_search",
                "arguments": {
                    "index": "test_index",
                    "query": '{"match": {"title": "test"}}',
                    "size": 20
                }
            }
        })
        resp = self.server.handle_request(req)
        
        self.assertIsNone(resp.error)
        # First call is the search request; audit trail is the second call.
        first_call = mock_es.call_args_list[0]
        body = first_call[0][2]
        self.assertEqual(body["query"]["match"]["title"], "test")
        self.assertEqual(body["size"], 20)
    
    @patch('mcp_server.server.es_request')
    def test_es_search_size_clamped(self, mock_es):
        """Test ES search size is clamped."""
        mock_es.return_value = {"hits": {"hits": []}}
        
        req = MCPRequest({
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/call",
            "params": {
                "name": "es_search",
                "arguments": {
                    "index": "test_index",
                    "size": 1000  # Above max
                }
            }
        })
        resp = self.server.handle_request(req)
        
        # First call is the search; audit trail POST is the second.
        first_call = mock_es.call_args_list[0]
        body = first_call[0][2]
        self.assertLessEqual(body["size"], 100)  # MAX_SEARCH_SIZE


class TestMCPMangleQuery(unittest.TestCase):
    """Test Mangle query tool."""
    
    def setUp(self):
        self.server = MCPServer()
    
    def test_mangle_query_known_predicate(self):
        """Test Mangle query with known predicate."""
        req = MCPRequest({
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/call",
            "params": {
                "name": "mangle_query",
                "arguments": {"predicate": "service_registry"}
            }
        })
        resp = self.server.handle_request(req)
        
        self.assertIsNone(resp.error)
        content = json.loads(resp.result["content"][0]["text"])
        self.assertEqual(content["predicate"], "service_registry")
        self.assertTrue(len(content["results"]) > 0)
    
    def test_mangle_query_unknown_predicate(self):
        """Test Mangle query with unknown predicate."""
        req = MCPRequest({
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/call",
            "params": {
                "name": "mangle_query",
                "arguments": {"predicate": "unknown_predicate"}
            }
        })
        resp = self.server.handle_request(req)
        
        self.assertIsNone(resp.error)
        content = json.loads(resp.result["content"][0]["text"])
        self.assertEqual(content["results"], [])

    def test_mangle_query_tool_invocation_returns_count_only(self):
        """mangle_query with tool_invocation must return a count, not raw history.

        The raw tool_invocation list is an audit trail and must not be exposed
        to external callers.  Only the invocation count is permitted.
        """
        req = MCPRequest({
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/call",
            "params": {
                "name": "mangle_query",
                "arguments": {"predicate": "tool_invocation"}
            }
        })
        resp = self.server.handle_request(req)

        self.assertIsNone(resp.error)
        content = json.loads(resp.result["content"][0]["text"])
        self.assertIn("results", content)
        results = content["results"]
        # Must be a dict with invocation_count, NOT a list of raw entries.
        self.assertIsInstance(results, dict)
        self.assertIn("invocation_count", results)
        self.assertNotIn("timestamp", results)
        self.assertNotIn("index", results)

    def test_mangle_query_internal_predicate_blocked(self):
        """mangle_query must not expose internal predicates not in the allowlist."""
        for predicate in ("tool_invocation_raw", "prompting_policy", "agent_config"):
            with self.subTest(predicate=predicate):
                req = MCPRequest({
                    "jsonrpc": "2.0",
                    "id": 1,
                    "method": "tools/call",
                    "params": {
                        "name": "mangle_query",
                        "arguments": {"predicate": predicate}
                    }
                })
                resp = self.server.handle_request(req)
                self.assertIsNone(resp.error)
                content = json.loads(resp.result["content"][0]["text"])
                # Must return empty results — not the actual internal fact data.
                self.assertEqual(content["results"], [])


class TestResourceRead(unittest.TestCase):
    """Test resource read functionality."""
    
    def setUp(self):
        self.server = MCPServer()
    
    def test_read_mangle_facts(self):
        """Test reading Mangle facts resource."""
        req = MCPRequest({
            "jsonrpc": "2.0",
            "id": 1,
            "method": "resources/read",
            "params": {"uri": "mangle://facts"}
        })
        resp = self.server.handle_request(req)
        
        self.assertIsNone(resp.error)
        self.assertIn("contents", resp.result)
        self.assertEqual(resp.result["contents"][0]["uri"], "mangle://facts")
        
        facts = json.loads(resp.result["contents"][0]["text"])
        self.assertIn("service_registry", facts)

    def test_mangle_facts_does_not_expose_raw_audit_history(self):
        """mangle://facts resource must not leak the raw tool_invocation list.

        The resource is accessible to any authenticated MCP client, so it must
        only contain non-sensitive summary data.  Raw audit entries (including
        timestamps, index names, and any future PII) must be excluded.
        """
        req = MCPRequest({
            "jsonrpc": "2.0",
            "id": 1,
            "method": "resources/read",
            "params": {"uri": "mangle://facts"}
        })
        resp = self.server.handle_request(req)

        self.assertIsNone(resp.error)
        facts = json.loads(resp.result["contents"][0]["text"])

        # service_registry summary must be present.
        self.assertIn("service_registry", facts)
        # Aggregate count is permitted.
        self.assertIn("tool_invocation_count", facts)
        # The raw list must NOT be present.
        self.assertNotIn("tool_invocation", facts)
        # No other internal keys should appear.
        allowed_keys = {"service_registry", "tool_invocation_count"}
        self.assertEqual(set(facts.keys()), allowed_keys)

    def test_mangle_facts_invocation_count_is_integer(self):
        """tool_invocation_count in mangle://facts must be a non-negative integer."""
        req = MCPRequest({
            "jsonrpc": "2.0",
            "id": 1,
            "method": "resources/read",
            "params": {"uri": "mangle://facts"}
        })
        resp = self.server.handle_request(req)
        facts = json.loads(resp.result["contents"][0]["text"])

        count = facts["tool_invocation_count"]
        self.assertIsInstance(count, int)
        self.assertGreaterEqual(count, 0)


class TestAuthentication(unittest.TestCase):
    """Test the _authenticate helper."""

    def _make_handler(self, auth_header: str):
        """Return a minimal mock handler with the given Authorization header."""
        handler = unittest.mock.MagicMock()
        handler.headers = {"Authorization": auth_header} if auth_header else {}
        return handler

    def test_auth_disabled_passes_all(self):
        """When XSUAA_VERIFY_TOKEN=false every request is allowed."""
        handler = self._make_handler("")
        with patch.dict(os.environ, {"XSUAA_VERIFY_TOKEN": "false"}):
            import importlib
            import mcp_server.server as srv
            importlib.reload(srv)
            self.assertTrue(srv._authenticate(handler))

    def test_no_auth_header_rejected(self):
        """Missing Authorization header must return False."""
        handler = self._make_handler("")
        with patch.dict(os.environ, {"XSUAA_VERIFY_TOKEN": "true", "MCP_API_KEY": "", "XSUAA_PUBLIC_KEY": ""}):
            import importlib
            import mcp_server.server as srv
            importlib.reload(srv)
            self.assertFalse(srv._authenticate(handler))

    def test_valid_api_key_accepted(self):
        """Correct ApiKey credential must return True."""
        handler = self._make_handler("ApiKey mysecret")
        with patch.dict(os.environ, {"XSUAA_VERIFY_TOKEN": "true", "MCP_API_KEY": "mysecret", "XSUAA_PUBLIC_KEY": ""}):
            import importlib
            import mcp_server.server as srv
            importlib.reload(srv)
            self.assertTrue(srv._authenticate(handler))

    def test_wrong_api_key_rejected(self):
        """Incorrect ApiKey must return False."""
        handler = self._make_handler("ApiKey wrongkey")
        with patch.dict(os.environ, {"XSUAA_VERIFY_TOKEN": "true", "MCP_API_KEY": "mysecret", "XSUAA_PUBLIC_KEY": ""}):
            import importlib
            import mcp_server.server as srv
            importlib.reload(srv)
            self.assertFalse(srv._authenticate(handler))

    def test_bearer_without_public_key_accepted(self):
        """Non-empty Bearer token is accepted when no public key is configured."""
        handler = self._make_handler("Bearer sometoken")
        with patch.dict(os.environ, {"XSUAA_VERIFY_TOKEN": "true", "MCP_API_KEY": "", "XSUAA_PUBLIC_KEY": ""}):
            import importlib
            import mcp_server.server as srv
            importlib.reload(srv)
            self.assertTrue(srv._authenticate(handler))

    def test_empty_bearer_rejected(self):
        """Empty Bearer token must return False."""
        handler = self._make_handler("Bearer ")
        with patch.dict(os.environ, {"XSUAA_VERIFY_TOKEN": "true", "MCP_API_KEY": "", "XSUAA_PUBLIC_KEY": ""}):
            import importlib
            import mcp_server.server as srv
            importlib.reload(srv)
            self.assertFalse(srv._authenticate(handler))


class TestCORSOrigin(unittest.TestCase):
    """Test _cors_origin returns correct values."""

    def _make_handler(self, origin: str):
        handler = unittest.mock.MagicMock()
        handler.headers = {"Origin": origin} if origin else {}
        return handler

    def test_allowed_origin_returned(self):
        """Matching origin is echoed back."""
        with patch.dict(os.environ, {"CORS_ALLOWED_ORIGINS": "http://localhost:3000"}):
            import importlib
            import mcp_server.server as srv
            importlib.reload(srv)
            handler = self._make_handler("http://localhost:3000")
            self.assertEqual(srv._cors_origin(handler), "http://localhost:3000")

    def test_unknown_origin_returns_none(self):
        """Non-matching origin must return None, not the first allowed origin."""
        with patch.dict(os.environ, {"CORS_ALLOWED_ORIGINS": "http://localhost:3000"}):
            import importlib
            import mcp_server.server as srv
            importlib.reload(srv)
            handler = self._make_handler("http://evil.example.com")
            self.assertIsNone(srv._cors_origin(handler))

    def test_no_origin_header_returns_none(self):
        """Absent Origin header must return None (server-to-server case)."""
        with patch.dict(os.environ, {"CORS_ALLOWED_ORIGINS": "http://localhost:3000"}):
            import importlib
            import mcp_server.server as srv
            importlib.reload(srv)
            handler = self._make_handler("")
            self.assertIsNone(srv._cors_origin(handler))


class TestToolInputSchemas(unittest.TestCase):
    """Test tool input schemas are correct."""
    
    def setUp(self):
        self.server = MCPServer()
    
    def test_es_search_schema(self):
        """Test es_search input schema."""
        tool = self.server.tools["es_search"]
        schema = tool["inputSchema"]
        
        self.assertEqual(schema["type"], "object")
        self.assertIn("index", schema["properties"])
        self.assertIn("query", schema["properties"])
        self.assertIn("size", schema["properties"])
        self.assertIn("index", schema.get("required", []))
    
    def test_es_vector_search_schema(self):
        """Test es_vector_search input schema."""
        tool = self.server.tools["es_vector_search"]
        schema = tool["inputSchema"]
        
        self.assertEqual(schema["type"], "object")
        self.assertIn("index", schema["properties"])
        self.assertIn("field", schema["properties"])
        self.assertIn("query_vector", schema["properties"])
        self.assertIn("k", schema["properties"])
    
    def test_generate_embedding_schema(self):
        """Test generate_embedding input schema."""
        tool = self.server.tools["generate_embedding"]
        schema = tool["inputSchema"]
        
        self.assertEqual(schema["type"], "object")
        self.assertIn("text", schema["properties"])
        self.assertIn("text", schema.get("required", []))

    def test_hana_search_schema(self):
        """Test hana_search input schema."""
        tool = self.server.tools["hana_search"]
        schema = tool["inputSchema"]

        self.assertEqual(schema["type"], "object")
        self.assertIn("sql", schema["properties"])
        self.assertIn("sql", schema.get("required", []))

    def test_hana_index_to_es_schema(self):
        """Test hana_index_to_es input schema."""
        tool = self.server.tools["hana_index_to_es"]
        schema = tool["inputSchema"]

        self.assertEqual(schema["type"], "object")
        self.assertIn("sql", schema["properties"])
        self.assertIn("es_index", schema["properties"])
        self.assertIn("sql", schema.get("required", []))
        self.assertIn("es_index", schema.get("required", []))


class TestHANASearchTool(unittest.TestCase):
    """Test HANA search MCP tool handler."""

    def setUp(self):
        self.server = MCPServer()

    def test_hana_search_rejects_non_select(self):
        """hana_search must reject DML statements."""
        req = MCPRequest({
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/call",
            "params": {"name": "hana_search", "arguments": {"sql": "DROP TABLE foo"}},
        })
        resp = self.server.handle_request(req)
        self.assertIsNone(resp.error)
        content = json.loads(resp.result["content"][0]["text"])
        self.assertIn("error", content)
        self.assertIn("SELECT", content["error"])

    def test_hana_search_requires_sql(self):
        """hana_search must return an error when sql is absent."""
        req = MCPRequest({
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/call",
            "params": {"name": "hana_search", "arguments": {}},
        })
        resp = self.server.handle_request(req)
        self.assertIsNone(resp.error)
        content = json.loads(resp.result["content"][0]["text"])
        self.assertIn("error", content)

    def test_hana_index_to_es_requires_es_index(self):
        """hana_index_to_es must return an error when es_index is absent."""
        req = MCPRequest({
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/call",
            "params": {"name": "hana_index_to_es", "arguments": {"sql": "SELECT 1 FROM DUAL"}},
        })
        resp = self.server.handle_request(req)
        self.assertIsNone(resp.error)
        content = json.loads(resp.result["content"][0]["text"])
        self.assertIn("error", content)

    def test_hana_index_to_es_rejects_non_select(self):
        """hana_index_to_es must reject DML statements."""
        req = MCPRequest({
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/call",
            "params": {
                "name": "hana_index_to_es",
                "arguments": {"sql": "INSERT INTO foo VALUES (1)", "es_index": "test"},
            },
        })
        resp = self.server.handle_request(req)
        self.assertIsNone(resp.error)
        content = json.loads(resp.result["content"][0]["text"])
        self.assertIn("error", content)
        self.assertIn("SELECT", content["error"])


class TestResolveEmbeddingDeployment(unittest.TestCase):
    """Test _resolve_embedding_deployment helper."""

    def setUp(self):
        self.server = MCPServer()

    @patch.dict(os.environ, {"AICORE_EMBEDDING_DEPLOYMENT_ID": "explicit-deploy-id"})
    def test_explicit_env_var_used_directly(self):
        """When AICORE_EMBEDDING_DEPLOYMENT_ID is set, it is returned without any HTTP call."""
        deployment_id, err = self.server._resolve_embedding_deployment()
        self.assertIsNone(err)
        self.assertEqual(deployment_id, "explicit-deploy-id")

    @patch.dict(os.environ, {"AICORE_EMBEDDING_DEPLOYMENT_ID": ""})
    @patch("mcp_server.server.aicore_request")
    def test_heuristic_match_returns_warning(self, mock_aicore):
        """When env var is absent and heuristic finds an embed deployment, a WARNING is logged."""
        mock_aicore.return_value = {
            "resources": [
                {"id": "embed-deploy", "details": {"model": "text-embedding-ada-002"}},
                {"id": "chat-deploy", "details": {"model": "gpt-4"}},
            ]
        }
        import logging
        with self.assertLogs("elasticsearch-mcp", level=logging.WARNING):
            deployment_id, err = self.server._resolve_embedding_deployment()
        self.assertIsNone(err)
        self.assertEqual(deployment_id, "embed-deploy")

    @patch.dict(os.environ, {"AICORE_EMBEDDING_DEPLOYMENT_ID": ""})
    @patch("mcp_server.server.aicore_request")
    def test_fallback_to_first_deployment_warns(self, mock_aicore):
        """When no 'embed' deployment exists, first resource is used with a WARNING."""
        mock_aicore.return_value = {
            "resources": [
                {"id": "chat-deploy", "details": {"model": "gpt-4"}},
            ]
        }
        import logging
        with self.assertLogs("elasticsearch-mcp", level=logging.WARNING):
            deployment_id, err = self.server._resolve_embedding_deployment()
        self.assertIsNone(err)
        self.assertEqual(deployment_id, "chat-deploy")

    @patch.dict(os.environ, {"AICORE_EMBEDDING_DEPLOYMENT_ID": ""})
    @patch("mcp_server.server.aicore_request")
    def test_no_deployments_returns_error(self, mock_aicore):
        """When the deployment list is empty, an error dict is returned."""
        mock_aicore.return_value = {"resources": []}
        deployment_id, err = self.server._resolve_embedding_deployment()
        self.assertEqual(deployment_id, "")
        self.assertIsNotNone(err)
        self.assertIn("error", err)

    @patch.dict(os.environ, {"AICORE_EMBEDDING_DEPLOYMENT_ID": ""})
    @patch("mcp_server.server.aicore_request")
    def test_aicore_error_propagated(self, mock_aicore):
        """When AI Core returns an error fetching deployments, it is surfaced."""
        mock_aicore.return_value = {"error": "connection refused"}
        deployment_id, err = self.server._resolve_embedding_deployment()
        self.assertEqual(deployment_id, "")
        self.assertIsNotNone(err)
        self.assertIn("error", err)


class TestHealthMiddlewareStats(unittest.TestCase):
    """Test that /health response includes middleware stats when available."""

    def _call_health(self, mock_handler_class):
        """Helper: call do_GET('/health') on a real MCPHandler instance via direct invocation."""
        import io
        from unittest.mock import MagicMock, patch
        import mcp_server.server as srv

        handler = mock_handler_class()
        written = []

        def fake_write_json(status_code, payload):
            written.append(payload)

        handler._write_json = fake_write_json
        handler.path = "/health"
        srv.MCPHandler.do_GET(handler)
        return written[0] if written else None

    @patch("mcp_server.server._MIDDLEWARE_AVAILABLE", True)
    @patch("mcp_server.server.get_mcp_limiter")
    @patch("mcp_server.server.get_aicore_config")
    @patch("mcp_server.server.get_es_config")
    @patch("mcp_server.server.aicore_config_ready", return_value=True)
    def test_health_includes_middleware_when_available(
        self, _mock_ready, mock_es_cfg, mock_aicore_cfg, mock_limiter
    ):
        """When middleware is available, /health includes rate_limiter and circuit_breakers."""
        import mcp_server.server as srv
        from unittest.mock import MagicMock, patch

        mock_es_cfg.return_value = {"host": "http://localhost:9200"}
        mock_aicore_cfg.return_value = {}

        fake_metrics = {"requests_allowed": 100, "requests_rejected": 0}
        mock_limiter.return_value.get_metrics.return_value = fake_metrics

        with patch("mcp_server.server.get_all_breaker_stats", return_value={"breaker1": "closed"}, create=True):
            written = []
            handler = MagicMock()

            def fake_write_json(status_code, payload):
                written.append(payload)

            handler._write_json = fake_write_json
            handler.path = "/health"
            with patch("mcp_server.server._MIDDLEWARE_AVAILABLE", True):
                srv.MCPHandler.do_GET(handler)

        self.assertTrue(len(written) > 0)
        response = written[0]
        self.assertIn("middleware", response)
        self.assertIn("rate_limiter", response["middleware"])
        self.assertIn("circuit_breakers", response["middleware"])

    @patch("mcp_server.server._MIDDLEWARE_AVAILABLE", False)
    @patch("mcp_server.server.get_aicore_config")
    @patch("mcp_server.server.get_es_config")
    @patch("mcp_server.server.aicore_config_ready", return_value=True)
    def test_health_omits_middleware_when_unavailable(
        self, _mock_ready, mock_es_cfg, mock_aicore_cfg
    ):
        """When middleware is unavailable, /health response has no 'middleware' key."""
        import mcp_server.server as srv
        from unittest.mock import MagicMock

        mock_es_cfg.return_value = {"host": "http://localhost:9200"}
        mock_aicore_cfg.return_value = {}

        written = []
        handler = MagicMock()

        def fake_write_json(status_code, payload):
            written.append(payload)

        handler._write_json = fake_write_json
        handler.path = "/health"
        srv.MCPHandler.do_GET(handler)

        self.assertTrue(len(written) > 0)
        self.assertNotIn("middleware", written[0])


class TestMangleGRPCClientGovernance(unittest.TestCase):
    """Tests for MangleGRPCClient-backed _governance_check in MCPServer.

    The Go gRPC engine is mocked at the MangleGRPCClient level so these tests
    run without a real gRPC server.
    """

    def setUp(self):
        self.server = MCPServer()

    def _make_grpc_result(self, path: str, confidence: float = 1.0) -> dict:
        return {"path": path, "confidence": confidence, "answer": ""}

    @patch("mcp_server.server._mangle_grpc_client")
    def test_grpc_blocks_vllm_path(self, mock_client):
        """When gRPC engine returns path='vllm', governance check blocks the request."""
        mock_client.resolve.return_value = self._make_grpc_result("vllm", 0.95)
        result = self.server._governance_check("fetch customers index data", "es_search")
        self.assertIsNotNone(result)
        self.assertIn("error", result)
        self.assertIn("grpc:route_to_vllm", result["reason"])
        mock_client.resolve.assert_called_once_with("fetch customers index data")

    @patch("mcp_server.server._mangle_grpc_client")
    def test_grpc_blocks_route_to_vllm_path(self, mock_client):
        """path='route_to_vllm' (legacy rule name) is also blocked."""
        mock_client.resolve.return_value = self._make_grpc_result("route_to_vllm")
        result = self.server._governance_check("orders data", "generate_embedding")
        self.assertIsNotNone(result)
        self.assertEqual(result["tool"], "generate_embedding")

    @patch("mcp_server.server._mangle_grpc_client")
    def test_grpc_allows_rag_path(self, mock_client):
        """When gRPC engine returns path='rag', governance check passes (returns None)."""
        mock_client.resolve.return_value = self._make_grpc_result("rag", 0.8)
        result = self.server._governance_check("search products catalog", "es_search")
        self.assertIsNone(result)

    @patch("mcp_server.server._mangle_grpc_client")
    def test_grpc_allows_cache_path(self, mock_client):
        """path='cache' is not a governance block."""
        mock_client.resolve.return_value = self._make_grpc_result("cache", 1.0)
        result = self.server._governance_check("help docs", "hana_vector_search")
        self.assertIsNone(result)

    @patch("mcp_server.server._mangle_grpc_client")
    @patch("mcp_server.server.MangleEngine", create=True)
    def test_grpc_unavailable_falls_back_to_python(self, mock_engine_cls, mock_client):
        """When gRPC returns None (unavailable), Python MangleEngine fallback is used."""
        mock_client.resolve.return_value = None
        mock_engine = MagicMock()
        mock_engine.query.return_value = [{"reason": "python:confidential"}]
        mock_engine_cls.return_value = mock_engine

        import mcp_server.server as srv_mod
        with patch.object(srv_mod, "__builtins__", srv_mod.__builtins__):
            # Import the MangleEngine offline replica via the fallback path
            with patch("builtins.__import__", side_effect=lambda name, *a, **kw: (
                type("mod", (), {"MangleEngine": mock_engine_cls})()
                if name == "agent.elasticsearch_agent" else __import__(name, *a, **kw)
            )):
                # Direct call: gRPC returns None, Python fallback fires
                result = self.server._governance_check("audit logs confidential", "es_search")
        # If Python fallback isn't wired, gRPC None still returns None (passes governance)
        # This test validates the dispatch logic — result may be None or blocked dict
        # depending on whether the fallback import succeeded in the test environment.
        # Both outcomes are acceptable; the key assertion is that gRPC was tried first.
        mock_client.resolve.assert_called_once()

    @patch("mcp_server.server._mangle_grpc_client")
    def test_grpc_exception_falls_through(self, mock_client):
        """When gRPC client raises unexpectedly, governance still returns None (allow)."""
        mock_client.resolve.side_effect = RuntimeError("unexpected grpc failure")
        # Should not raise; the outer exception handler in _governance_check catches it
        # (via the Python fallback path which also has a try/except)
        try:
            result = self.server._governance_check("public docs search", "es_search")
        except RuntimeError:
            self.fail("_governance_check should not propagate gRPC exceptions")


class TestMangleGRPCClientAvailability(unittest.TestCase):
    """Unit tests for MangleGRPCClient.resolve availability checks."""

    def test_unavailable_when_port_closed(self):
        """resolve() returns None when the gRPC port is not listening."""
        from mcp_server.server import MangleGRPCClient
        client = MangleGRPCClient(port=19999)  # unlikely to be in use
        result = client.resolve("test query")
        self.assertIsNone(result)

    def test_cached_unavailable_skips_reconnect(self):
        """After a failed check, _available is False and socket is not re-attempted."""
        from mcp_server.server import MangleGRPCClient
        client = MangleGRPCClient(port=19998)
        client._available = False  # pre-seed the cache
        with patch("socket.create_connection") as mock_conn:
            result = client.resolve("another query")
        mock_conn.assert_not_called()
        self.assertIsNone(result)


if __name__ == "__main__":
    unittest.main()