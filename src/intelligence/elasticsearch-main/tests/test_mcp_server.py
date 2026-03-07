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
    clamp_int, parse_json_arg, get_es_config, get_aicore_config, aicore_config_ready
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
            "generate_embedding", "ai_semantic_search", "mangle_query"
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
        self.assertTrue(len(resp.result["tools"]) >= 8)
    
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
        mock_es.assert_called_once()
        call_args = mock_es.call_args
        self.assertEqual(call_args[0][0], "POST")
        self.assertIn("test_index", call_args[0][1])
    
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
        call_args = mock_es.call_args
        body = call_args[0][2]
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
        
        call_args = mock_es.call_args
        body = call_args[0][2]
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


if __name__ == "__main__":
    unittest.main()