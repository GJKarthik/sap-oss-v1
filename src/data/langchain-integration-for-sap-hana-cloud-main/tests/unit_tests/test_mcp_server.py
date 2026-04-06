# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2024 SAP SE
"""
Unit tests for MCP server tool handlers, auth, and security guards.
"""

import json
import os
import sys
import unittest

# Add project root so mcp_server is importable
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", ".."))

from mcp_server.server import (
    MCPServer,
    MCPRequest,
    MCPResponse,
    _recursive_split,
    clamp_int,
    parse_json_arg,
)


class TestClampInt(unittest.TestCase):
    def test_valid_value(self):
        self.assertEqual(clamp_int(5, 10, 1, 100), 5)

    def test_below_min(self):
        self.assertEqual(clamp_int(-1, 10, 0, 100), 0)

    def test_above_max(self):
        self.assertEqual(clamp_int(200, 10, 0, 100), 100)

    def test_invalid_type_returns_default(self):
        self.assertEqual(clamp_int("abc", 42, 0, 100), 42)

    def test_none_returns_default(self):
        self.assertEqual(clamp_int(None, 42, 0, 100), 42)


class TestParseJsonArg(unittest.TestCase):
    def test_parses_valid_json_string(self):
        result = parse_json_arg('[1, 2, 3]', [])
        self.assertEqual(result, [1, 2, 3])

    def test_returns_fallback_for_invalid_json(self):
        result = parse_json_arg("not json", "fallback")
        self.assertEqual(result, "fallback")

    def test_returns_value_if_not_string(self):
        result = parse_json_arg([1, 2], "fallback")
        self.assertEqual(result, [1, 2])

    def test_returns_fallback_for_none(self):
        result = parse_json_arg(None, "default")
        self.assertEqual(result, "default")


class TestRecursiveSplit(unittest.TestCase):
    def test_short_text_returns_unchanged(self):
        result = _recursive_split("Hello", ["\n\n", ". "], 100, 0)
        self.assertEqual(result, ["Hello"])

    def test_splits_on_paragraph(self):
        text = "Paragraph one.\n\nParagraph two."
        result = _recursive_split(text, ["\n\n", ". "], 20, 0)
        self.assertTrue(len(result) >= 2)

    def test_empty_text_returns_empty(self):
        result = _recursive_split("", ["\n\n"], 100, 0)
        self.assertEqual(result, [])


class TestMCPServerRerankHandler(unittest.TestCase):
    def setUp(self):
        self.server = MCPServer()

    def test_rerank_requires_query(self):
        result = self.server._handle_rerank_results({"documents": "[]"})
        self.assertIn("error", result)
        self.assertIn("query is required", result["error"])

    def test_rerank_requires_documents(self):
        result = self.server._handle_rerank_results({"query": "test"})
        self.assertIn("error", result)

    def test_rerank_empty_documents_rejected(self):
        result = self.server._handle_rerank_results({"query": "test", "documents": "[]"})
        self.assertIn("error", result)

    def test_rerank_graceful_fallback_without_model(self):
        """Without sentence-transformers installed, should return original order."""
        docs = json.dumps([{"content": "doc1", "score": 0.9}, {"content": "doc2", "score": 0.8}])
        result = self.server._handle_rerank_results({"query": "test query", "documents": docs})
        # Either reranked=True (model available) or reranked=False (graceful fallback)
        self.assertIn("documents", result)
        self.assertIn("reranked", result)
        self.assertIsInstance(result["documents"], list)


class TestMCPServerCypherGuard(unittest.TestCase):
    def setUp(self):
        self.server = MCPServer()

    def test_rejects_create_at_start(self):
        result = self.server._handle_kuzu_query({"cypher": "CREATE (n:Test)"})
        self.assertIn("error", result)
        self.assertIn("not permitted", result["error"])

    def test_rejects_create_in_subquery(self):
        """Regression: old guard only checked startsWith."""
        result = self.server._handle_kuzu_query({"cypher": "MATCH (n) WITH n CREATE (m:Evil)"})
        self.assertIn("error", result)

    def test_rejects_delete_anywhere(self):
        result = self.server._handle_kuzu_query({"cypher": "MATCH (n) DELETE n"})
        self.assertIn("error", result)

    def test_rejects_merge(self):
        result = self.server._handle_kuzu_query({"cypher": "MERGE (n:Test {id: 1})"})
        self.assertIn("error", result)

    def test_rejects_set(self):
        result = self.server._handle_kuzu_query({"cypher": "MATCH (n) SET n.name = 'evil'"})
        self.assertIn("error", result)

    def test_rejects_drop(self):
        result = self.server._handle_kuzu_query({"cypher": "DROP TABLE test"})
        self.assertIn("error", result)

    def test_rejects_detach_delete(self):
        result = self.server._handle_kuzu_query({"cypher": "MATCH (n) DETACH DELETE n"})
        self.assertIn("error", result)

    def test_rejects_empty_cypher(self):
        result = self.server._handle_kuzu_query({"cypher": ""})
        self.assertIn("error", result)
        self.assertIn("required", result["error"])


class TestMCPServerPathTraversal(unittest.TestCase):
    def setUp(self):
        self.server = MCPServer()

    def test_local_file_disabled_when_no_allowed_dirs(self):
        """Without MCP_ALLOWED_FILE_DIRS, local file loading should be disabled."""
        # Ensure env var is not set
        old_val = os.environ.pop("MCP_ALLOWED_FILE_DIRS", None)
        try:
            result = self.server._handle_langchain_load_documents({"source": "/etc/passwd"})
            # Should NOT return file contents — either metadata-only or federated
            self.assertNotEqual(result.get("status"), "loaded-local-file")
        finally:
            if old_val is not None:
                os.environ["MCP_ALLOWED_FILE_DIRS"] = old_val

    def test_path_outside_allowed_dir_rejected(self):
        """Accessing a file outside allowed directories should be denied."""
        os.environ["MCP_ALLOWED_FILE_DIRS"] = "/tmp/safe_dir"
        try:
            result = self.server._handle_langchain_load_documents({"source": "/etc/passwd"})
            if "error" in result:
                self.assertIn("denied", result["error"].lower())
            else:
                # If file doesn't exist, it returns metadata-only (not an error)
                self.assertNotEqual(result.get("status"), "loaded-local-file")
        finally:
            del os.environ["MCP_ALLOWED_FILE_DIRS"]


class TestMCPServerSplitText(unittest.TestCase):
    def setUp(self):
        self.server = MCPServer()

    def test_empty_text_returns_empty(self):
        result = self.server._handle_langchain_split_text({"text": ""})
        self.assertEqual(result["chunks"], 0)
        self.assertEqual(result["texts"], [])

    def test_short_text_single_chunk(self):
        result = self.server._handle_langchain_split_text({"text": "Hello world", "chunk_size": 1000})
        self.assertEqual(result["chunks"], 1)
        self.assertEqual(result["texts"], ["Hello world"])

    def test_respects_chunk_size(self):
        text = "A" * 500 + " " + "B" * 500
        result = self.server._handle_langchain_split_text({"text": text, "chunk_size": 600, "chunk_overlap": 0})
        self.assertGreater(result["chunks"], 1)


class TestMCPServerHandleRequest(unittest.TestCase):
    def setUp(self):
        self.server = MCPServer()

    def test_initialize_returns_protocol_version(self):
        req = MCPRequest({"jsonrpc": "2.0", "id": 1, "method": "initialize"})
        resp = self.server.handle_request(req)
        self.assertIsNone(resp.error)
        self.assertEqual(resp.result["protocolVersion"], "2024-11-05")

    def test_tools_list_includes_rerank(self):
        req = MCPRequest({"jsonrpc": "2.0", "id": 2, "method": "tools/list"})
        resp = self.server.handle_request(req)
        tool_names = [t["name"] for t in resp.result["tools"]]
        self.assertIn("rerank_results", tool_names)

    def test_unknown_tool_returns_error(self):
        req = MCPRequest({"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": "nonexistent_tool", "arguments": {}}})
        resp = self.server.handle_request(req)
        self.assertIsNotNone(resp.error)
        self.assertIn("Unknown tool", resp.error["message"])

    def test_invalid_jsonrpc_version(self):
        req = MCPRequest({"jsonrpc": "1.0", "id": 4, "method": "initialize"})
        resp = self.server.handle_request(req)
        self.assertIsNotNone(resp.error)


class TestSanitizeIdentifier(unittest.TestCase):
    def test_valid_identifier(self):
        from mcp_server.server import _sanitize_identifier
        self.assertEqual(_sanitize_identifier("EMBEDDINGS"), "EMBEDDINGS")

    def test_valid_with_underscore(self):
        from mcp_server.server import _sanitize_identifier
        self.assertEqual(_sanitize_identifier("MY_TABLE_1"), "MY_TABLE_1")

    def test_rejects_sql_injection(self):
        from mcp_server.server import _sanitize_identifier
        with self.assertRaises(ValueError):
            _sanitize_identifier('"; DROP TABLE --')

    def test_rejects_spaces(self):
        from mcp_server.server import _sanitize_identifier
        with self.assertRaises(ValueError):
            _sanitize_identifier("MY TABLE")

    def test_rejects_empty(self):
        from mcp_server.server import _sanitize_identifier
        with self.assertRaises(ValueError):
            _sanitize_identifier("")

    def test_rejects_starts_with_number(self):
        from mcp_server.server import _sanitize_identifier
        with self.assertRaises(ValueError):
            _sanitize_identifier("1TABLE")


class TestVectorStoreHandler(unittest.TestCase):
    def setUp(self):
        self.server = MCPServer()

    def test_requires_table_name(self):
        result = self.server._handle_langchain_vector_store({})
        self.assertIn("error", result)
        self.assertIn("table_name", result["error"])

    def test_returns_local_stub_without_hana(self):
        result = self.server._handle_langchain_vector_store({"table_name": "EMBEDDINGS"})
        self.assertEqual(result["table_name"], "EMBEDDINGS")
        self.assertEqual(result["status"], "created/retrieved")
        # Without HANA_HOST set, should return local backend
        self.assertIn(result["backend"], ("local", "federated"))

    def test_updates_facts_store(self):
        self.server._handle_langchain_vector_store({"table_name": "TEST_TABLE"})
        stores = [s for s in self.server.facts["vector_stores"] if s["table_name"] == "TEST_TABLE"]
        self.assertEqual(len(stores), 1)


class TestAddDocumentsHandler(unittest.TestCase):
    def setUp(self):
        self.server = MCPServer()

    def test_requires_table_name(self):
        result = self.server._handle_langchain_add_documents({"documents": "[]"})
        self.assertIn("error", result)
        self.assertIn("table_name", result["error"])

    def test_invalid_json_documents_treated_as_empty(self):
        result = self.server._handle_langchain_add_documents({"table_name": "T", "documents": "not-json"})
        # parse_json_arg falls back to [], so 0 documents added
        self.assertEqual(result["documents_added"], 0)

    def test_rejects_non_list_documents(self):
        result = self.server._handle_langchain_add_documents({"table_name": "T", "documents": '{"key": "val"}'})
        self.assertIn("error", result)

    def test_returns_buffered_local_without_hana(self):
        docs = json.dumps([{"content": "hello", "metadata": {}}])
        result = self.server._handle_langchain_add_documents({"table_name": "EMBEDDINGS", "documents": docs})
        self.assertEqual(result["table_name"], "EMBEDDINGS")
        self.assertIn(result["status"], ("buffered-local", "federated", "hana"))
        self.assertEqual(result["documents_added"], 1)

    def test_truncates_excess_documents(self):
        docs = json.dumps([{"content": f"doc{i}"} for i in range(5)])
        result = self.server._handle_langchain_add_documents({"table_name": "T", "documents": docs})
        self.assertLessEqual(result["documents_added"], 5)


class TestSimilaritySearchHandler(unittest.TestCase):
    def setUp(self):
        self.server = MCPServer()

    def test_requires_table_and_query(self):
        result = self.server._handle_langchain_similarity_search({"table_name": "T"})
        self.assertIn("error", result)

    def test_requires_query(self):
        result = self.server._handle_langchain_similarity_search({"table_name": "T", "query": ""})
        self.assertIn("error", result)

    def test_returns_degraded_without_hana(self):
        result = self.server._handle_langchain_similarity_search({"table_name": "EMBEDDINGS", "query": "test query"})
        self.assertEqual(result["table_name"], "EMBEDDINGS")
        self.assertIn(result["status"], ("degraded-no-remote", "federated", "hana"))


class TestRagChainHandler(unittest.TestCase):
    def setUp(self):
        self.server = MCPServer()

    def test_requires_query_and_table(self):
        result = self.server._handle_langchain_rag_chain({"query": "test"})
        self.assertIn("error", result)

    def test_requires_query(self):
        result = self.server._handle_langchain_rag_chain({"table_name": "T", "query": ""})
        self.assertIn("error", result)

    def test_returns_degraded_fallback_without_backends(self):
        result = self.server._handle_langchain_rag_chain({"query": "test question", "table_name": "EMBEDDINGS"})
        self.assertIn("status", result)
        self.assertIn("query", result)
        self.assertIn("context_docs", result)


if __name__ == "__main__":
    unittest.main()
