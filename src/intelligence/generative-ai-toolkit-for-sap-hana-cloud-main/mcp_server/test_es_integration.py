import importlib.util
import json
from pathlib import Path
import unittest
from unittest.mock import patch


SERVER_PATH = Path(__file__).with_name("server.py")
SPEC = importlib.util.spec_from_file_location("toolkit_mcp_server", SERVER_PATH)
toolkit_server = importlib.util.module_from_spec(SPEC)
assert SPEC and SPEC.loader
SPEC.loader.exec_module(toolkit_server)


class TestHANAToolkitESIntegration(unittest.TestCase):
    def setUp(self):
        self.server = toolkit_server.MCPServer()
        self.endpoint = "http://vector.example/mcp"

    def test_hana_vector_add_stringifies_documents_for_es_index(self):
        calls = []

        def fake_call(endpoint, tool_name, tool_args, timeout_seconds=3):
            calls.append((endpoint, tool_name, tool_args))
            return {"result": "ok"}

        with patch.object(self.server, "_iter_federated_mcp_endpoints", return_value=[self.endpoint]):
            with patch.object(toolkit_server, "call_mcp_tool", side_effect=fake_call):
                result = self.server._handle_hana_vector_add({
                    "table_name": "research_papers",
                    "documents": json.dumps([{"text": "chunk text", "source": "paper"}]),
                })

        self.assertEqual(result["status"], "federated")
        self.assertEqual(result["indexed_remotely"], 1)
        self.assertEqual(calls[0][1], "es_index")
        self.assertIsInstance(calls[0][2]["document"], str)
        self.assertEqual(
            json.loads(calls[0][2]["document"]),
            {"text": "chunk text", "source": "paper"},
        )

    def test_hana_vector_search_prefers_text_search(self):
        calls = []

        def fake_call(endpoint, tool_name, tool_args, timeout_seconds=3):
            calls.append(tool_name)
            if tool_name == "es_search":
                return {"hits": {"hits": [{"_source": {"text": "semantic router chunk"}}]}}
            raise AssertionError(f"Unexpected tool call: {tool_name}")

        with patch.object(self.server, "_iter_federated_mcp_endpoints", return_value=[self.endpoint]):
            with patch.object(toolkit_server, "call_mcp_tool", side_effect=fake_call):
                result = self.server._handle_hana_vector_search({
                    "table_name": "research_papers",
                    "query": "semantic routing",
                    "top_k": 3,
                })

        self.assertEqual(result["status"], "federated")
        self.assertEqual(result["search_type"], "text")
        self.assertEqual(calls, ["es_search"])

    def test_hana_vector_search_falls_back_to_semantic_search_with_vector_field(self):
        calls = []

        def fake_call(endpoint, tool_name, tool_args, timeout_seconds=3):
            calls.append(tool_name)
            if tool_name == "es_search":
                return {"hits": {"hits": []}}
            if tool_name == "es_index_info":
                return {
                    "research_papers": {
                        "mappings": {"properties": {"embedding": {"type": "dense_vector"}}}
                    }
                }
            if tool_name == "ai_semantic_search":
                return {"hits": {"hits": [{"_source": {"text": "semantic result"}}]}}
            raise AssertionError(f"Unexpected tool call: {tool_name}")

        with patch.object(self.server, "_iter_federated_mcp_endpoints", return_value=[self.endpoint]):
            with patch.object(toolkit_server, "call_mcp_tool", side_effect=fake_call):
                result = self.server._handle_hana_vector_search({
                    "table_name": "research_papers",
                    "query": "semantic routing",
                    "top_k": 3,
                })

        self.assertEqual(result["status"], "federated")
        self.assertEqual(result["search_type"], "semantic")
        self.assertEqual(result["vector_field"], "embedding")
        self.assertEqual(calls, ["es_search", "es_index_info", "ai_semantic_search"])

    def test_hana_rag_uses_es_search_context_for_chat(self):
        def fake_call(endpoint, tool_name, tool_args, timeout_seconds=3):
            self.assertEqual(tool_name, "es_search")
            return {
                "hits": {
                    "hits": [
                        {"_source": {"title": "Paper", "text": "The semantic router uses signals."}}
                    ]
                }
            }

        with patch.object(self.server, "_iter_federated_mcp_endpoints", return_value=[self.endpoint]):
            with patch.object(toolkit_server, "call_mcp_tool", side_effect=fake_call):
                with patch.object(self.server, "_handle_hana_chat", return_value={"content": "Generated answer"}) as chat_mock:
                    result = self.server._handle_hana_rag({
                        "table_name": "research_papers",
                        "query": "How does the router work?",
                        "top_k": 3,
                    })

        self.assertEqual(result["status"], "federated")
        self.assertEqual(result["context_docs"], ["Title: Paper\nThe semantic router uses signals."])
        messages = json.loads(chat_mock.call_args.args[0]["messages"])
        self.assertEqual(len(messages), 1)
        self.assertIn("The semantic router uses signals.", messages[0]["content"])
        self.assertEqual(result["answer"], "Generated answer")


if __name__ == "__main__":
    unittest.main()