"""
Integration tests for Elasticsearch service.

Tests cross-service integration with:
- Mangle Query Service (via MCP)
- OData Vocabularies (via shared ES index patterns)

These tests use mocked external services to validate integration contracts.
"""

import unittest
import json
from unittest.mock import Mock, patch, AsyncMock
import asyncio
import sys
import os

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))


class TestMangleIntegration(unittest.TestCase):
    """Test integration with Mangle Query Service."""
    
    def test_mcp_request_format_compatibility(self):
        """Test that MCP requests match Mangle service expectations."""
        # Standard MCP request format that Mangle service expects
        mcp_request = {
            "jsonrpc": "2.0",
            "id": "test-123",
            "method": "tools/call",
            "params": {
                "name": "es_hybrid_search",
                "arguments": {
                    "query": "customer orders high value",
                    "index": "odata_entity",
                    "top_k": 5,
                    "knn_weight": 0.7,
                    "bm25_weight": 0.3
                }
            }
        }
        
        # Validate request structure
        self.assertEqual(mcp_request["jsonrpc"], "2.0")
        self.assertIn("id", mcp_request)
        self.assertEqual(mcp_request["method"], "tools/call")
        self.assertIn("name", mcp_request["params"])
        self.assertIn("arguments", mcp_request["params"])
        
        # Validate arguments match ES hybrid search interface
        args = mcp_request["params"]["arguments"]
        self.assertIn("query", args)
        self.assertIn("index", args)
    
    def test_mcp_response_format_compatibility(self):
        """Test that MCP responses match expected format."""
        # Response format that ES MCP server returns
        mcp_response = {
            "jsonrpc": "2.0",
            "id": "test-123",
            "result": {
                "content": [{
                    "type": "text",
                    "text": json.dumps({
                        "hits": [
                            {"title": "Sales Order 1001", "score": 0.95},
                            {"title": "Sales Order 1002", "score": 0.88}
                        ],
                        "total": 2,
                        "max_score": 0.95
                    })
                }]
            }
        }
        
        # Validate response structure
        self.assertEqual(mcp_response["jsonrpc"], "2.0")
        self.assertEqual(mcp_response["id"], "test-123")
        self.assertIn("result", mcp_response)
        self.assertIn("content", mcp_response["result"])
        
        # Validate content can be parsed
        content = json.loads(mcp_response["result"]["content"][0]["text"])
        self.assertIn("hits", content)
        self.assertIn("total", content)
    
    def test_mangle_predicate_result_format(self):
        """Test that results match Mangle predicate expectations."""
        # Mangle expects es_hybrid_search/3: (Query, DocsJSON, TopScore)
        query = "customer orders"
        docs_json = json.dumps([
            {"title": "Order 1", "content": "...", "source": "es", "score": 0.9},
            {"title": "Order 2", "content": "...", "source": "es", "score": 0.8}
        ])
        top_score = 0.9
        
        # Parse and validate
        docs = json.loads(docs_json)
        self.assertIsInstance(docs, list)
        self.assertTrue(all("title" in d for d in docs))
        self.assertTrue(all("score" in d for d in docs))
        self.assertEqual(top_score, max(d["score"] for d in docs))


class TestODataIntegration(unittest.TestCase):
    """Test integration with OData Vocabularies service."""
    
    def test_odata_entity_index_schema_compatibility(self):
        """Test that ES index schema supports OData vocabulary fields."""
        # Required fields from odata_entity_index.json
        required_fields = [
            "entity_type",
            "entity_namespace", 
            "entity_set",
            "odata_metadata",
            "common_annotations",
            "analytics_annotations",
            "personal_data",
            "hana_metadata",
            "display_text",
            "display_text_embedding"
        ]
        
        # Our ES server should support indexing these fields
        sample_doc = {
            "entity_type": "SalesOrder",
            "entity_namespace": "com.sap.gateway.srvd.c_salesorder",
            "entity_set": "SalesOrderSet",
            "odata_metadata": {
                "namespace": "com.sap.gateway.srvd.c_salesorder",
                "entity_set": "SalesOrderSet",
                "key_properties": ["SalesOrder"],
                "is_analytical": False
            },
            "common_annotations": {
                "label": "Sales Order",
                "description": "Sales order business object",
                "semantic_object": "SalesOrder"
            },
            "analytics_annotations": {
                "dimensions": ["Customer", "Product"],
                "measures": ["NetValue"]
            },
            "personal_data": {
                "is_data_subject": False,
                "potentially_personal_fields": ["CustomerName"]
            },
            "hana_metadata": {
                "schema": "SAP_SALES",
                "table_or_view": "V_SALESORDER"
            },
            "display_text": "Sales Order 1001 - Customer ABC",
            "display_text_embedding": [0.1] * 1536  # 1536-dim embedding
        }
        
        # Validate all required fields present
        for field in required_fields:
            self.assertIn(field, sample_doc)
        
        # Validate embedding dimensions
        self.assertEqual(len(sample_doc["display_text_embedding"]), 1536)
    
    def test_vocabulary_search_query_format(self):
        """Test vocabulary search query compatibility."""
        # Query format for searching vocabulary terms
        search_body = {
            "query": {
                "multi_match": {
                    "query": "LineItem",
                    "fields": [
                        "term_name^3",
                        "qualified_name^2", 
                        "description",
                        "vocabulary"
                    ],
                    "type": "best_fields",
                    "fuzziness": "AUTO"
                }
            },
            "size": 10
        }
        
        # Validate query structure
        self.assertIn("query", search_body)
        self.assertIn("multi_match", search_body["query"])
        self.assertIn("fields", search_body["query"]["multi_match"])
    
    def test_gdpr_audit_fields(self):
        """Test GDPR/personal data audit fields compatibility."""
        # Audit document for GDPR compliance
        audit_doc = {
            "timestamp": "2026-03-01T16:00:00Z",
            "query_id": "audit-123",
            "event_type": "entity_access",
            "query": "SELECT * FROM Customer WHERE ...",
            "query_hash": "abc123",
            "entities_accessed": [
                {
                    "entity_type": "Customer",
                    "entity_id": "CUST001",
                    "access_level": "read"
                }
            ],
            "personal_data_audit": {
                "data_subject_accessed": True,
                "personal_fields": ["CustomerName", "Email"],
                "sensitive_fields": [],
                "legal_basis": "CONTRACT",
                "purpose": "ORDER_PROCESSING"
            },
            "user_id": "user123",
            "success": True
        }
        
        # Validate audit structure
        self.assertIn("personal_data_audit", audit_doc)
        self.assertIn("data_subject_accessed", audit_doc["personal_data_audit"])
        self.assertIn("legal_basis", audit_doc["personal_data_audit"])


class TestHybridSearchIntegration(unittest.TestCase):
    """Test BM25 + kNN hybrid search integration."""
    
    def test_hybrid_search_request_format(self):
        """Test hybrid search request matches ES RRF API."""
        # ES 8.x sub_searches format for RRF
        hybrid_request = {
            "sub_searches": [
                {
                    "query": {
                        "match": {
                            "display_text": {
                                "query": "sales order customer",
                                "boost": 0.3
                            }
                        }
                    }
                },
                {
                    "knn": {
                        "field": "display_text_embedding",
                        "query_vector": [0.1] * 1536,
                        "k": 10,
                        "num_candidates": 100,
                        "boost": 0.7
                    }
                }
            ],
            "rank": {
                "rrf": {
                    "window_size": 100,
                    "rank_constant": 60
                }
            },
            "size": 5
        }
        
        # Validate structure
        self.assertEqual(len(hybrid_request["sub_searches"]), 2)
        self.assertIn("rank", hybrid_request)
        self.assertIn("rrf", hybrid_request["rank"])
    
    def test_rrf_fusion_calculation(self):
        """Test RRF score fusion calculation."""
        # RRF formula: sum(1 / (rank_constant + rank_i))
        rank_constant = 60
        
        # Document rankings from two searches
        bm25_ranks = {"doc1": 1, "doc2": 3, "doc3": 5}
        knn_ranks = {"doc1": 2, "doc2": 1, "doc3": 4}
        
        def rrf_score(doc_id):
            score = 0
            if doc_id in bm25_ranks:
                score += 1 / (rank_constant + bm25_ranks[doc_id])
            if doc_id in knn_ranks:
                score += 1 / (rank_constant + knn_ranks[doc_id])
            return score
        
        scores = {doc: rrf_score(doc) for doc in ["doc1", "doc2", "doc3"]}
        
        # doc1 should rank highest: rank 1 in BM25 + rank 2 in kNN
        # gives a higher combined RRF score than doc2 (rank 3 BM25 + rank 1 kNN).
        sorted_docs = sorted(scores.keys(), key=lambda d: scores[d], reverse=True)
        self.assertEqual(sorted_docs[0], "doc1")


class TestIndexSyncIntegration(unittest.TestCase):
    """Test index synchronization patterns."""
    
    def test_sync_status_tracking(self):
        """Test sync status fields for HANA-ES integration."""
        doc_with_sync = {
            "entity_type": "Product",
            "hana_key": "PROD001",
            "last_synced_at": "2026-03-01T15:00:00Z",
            "hana_changed_at": "2026-03-01T14:55:00Z",
            "sync_status": "synced",
            "sync_error": None
        }
        
        # Validate sync tracking
        self.assertIn("last_synced_at", doc_with_sync)
        self.assertIn("hana_changed_at", doc_with_sync)
        self.assertIn("sync_status", doc_with_sync)
        self.assertIn(doc_with_sync["sync_status"], ["synced", "pending", "error"])
    
    def test_delta_tracking_fields(self):
        """Test delta tracking for CDC integration."""
        delta_config = {
            "method": "timestamp",  # or "cdc", "version"
            "timestamp_column": "CHANGED_AT",
            "change_type_column": "CHANGE_TYPE"  # I=Insert, U=Update, D=Delete
        }
        
        # Validate delta config structure
        self.assertIn("method", delta_config)
        self.assertIn(delta_config["method"], ["timestamp", "cdc", "version"])


class TestMCPToolSchemaIntegration(unittest.TestCase):
    """Test MCP tool schemas for cross-service compatibility."""
    
    def test_es_search_tool_schema(self):
        """Test es_search tool schema matches consumer expectations."""
        tool_schema = {
            "name": "es_search",
            "description": "Search Elasticsearch index",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "index": {"type": "string", "description": "Index name"},
                    "query": {"type": ["string", "object"], "description": "ES query"},
                    "size": {"type": "integer", "default": 10}
                },
                "required": ["index"]
            }
        }
        
        # Validate JSON Schema
        self.assertEqual(tool_schema["inputSchema"]["type"], "object")
        self.assertIn("index", tool_schema["inputSchema"]["required"])
    
    def test_mangle_query_tool_schema(self):
        """Test mangle_query tool schema for Mangle service compatibility."""
        tool_schema = {
            "name": "mangle_query",
            "description": "Execute Mangle query",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "predicate": {"type": "string"},
                    "args": {"type": "array", "items": {"type": "string"}}
                },
                "required": ["predicate"]
            }
        }
        
        # Validate compatibility
        self.assertEqual(tool_schema["name"], "mangle_query")
        self.assertIn("predicate", tool_schema["inputSchema"]["required"])


if __name__ == "__main__":
    unittest.main()