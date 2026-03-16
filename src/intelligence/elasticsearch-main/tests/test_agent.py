"""
Unit tests for Elasticsearch Agent.

Tests:
- MangleEngine query interface
- Index-based routing logic
- Governance and approval workflows
- Audit logging
"""

import unittest
import asyncio
from unittest.mock import Mock, patch, AsyncMock
import sys
import os

# Add parent directory to path for imports
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))

from agent.elasticsearch_agent import MangleEngine, ElasticsearchAgent


class TestMangleEngine(unittest.TestCase):
    """Test the Mangle reasoning engine."""
    
    def setUp(self):
        self.engine = MangleEngine()
    
    def test_initialization(self):
        """Test MangleEngine initializes with correct facts."""
        self.assertIn("agent_config", self.engine.facts)
        self.assertIn("agent_can_use", self.engine.facts)
        self.assertIn("agent_requires_approval", self.engine.facts)
        self.assertIn("confidential_indices", self.engine.facts)
        self.assertIn("log_indices", self.engine.facts)
        self.assertIn("public_indices", self.engine.facts)
    
    def test_autonomy_level(self):
        """Test autonomy level query."""
        result = self.engine.query("autonomy_level")
        self.assertEqual(len(result), 1)
        self.assertEqual(result[0]["level"], "L2")
    
    # =========================================================================
    # Route to vLLM Tests
    # =========================================================================
    
    def test_route_to_vllm_customer_index(self):
        """Test routing to vLLM for customer index queries."""
        result = self.engine.query("route_to_vllm", "Search customers for email")
        self.assertTrue(len(result) > 0)
        self.assertTrue(result[0]["result"])
        self.assertIn("customer", result[0]["reason"].lower())
    
    def test_route_to_vllm_order_index(self):
        """Test routing to vLLM for order index queries."""
        result = self.engine.query("route_to_vllm", "Aggregate orders by status")
        self.assertTrue(len(result) > 0)
        self.assertTrue(result[0]["result"])
    
    def test_route_to_vllm_transaction_index(self):
        """Test routing to vLLM for transaction index queries."""
        result = self.engine.query("route_to_vllm", "Get transaction history")
        self.assertTrue(len(result) > 0)
        self.assertTrue(result[0]["result"])
    
    def test_route_to_vllm_financial_index(self):
        """Test routing to vLLM for financial index queries."""
        result = self.engine.query("route_to_vllm", "Query financial data")
        self.assertTrue(len(result) > 0)
        self.assertTrue(result[0]["result"])
    
    def test_route_to_vllm_audit_index(self):
        """Test routing to vLLM for audit index queries."""
        result = self.engine.query("route_to_vllm", "Check audit logs")
        self.assertTrue(len(result) > 0)
        self.assertTrue(result[0]["result"])
    
    def test_route_to_vllm_log_index(self):
        """Test routing to vLLM for log indices."""
        result = self.engine.query("route_to_vllm", "Search logs- for errors")
        self.assertTrue(len(result) > 0)
        self.assertTrue(result[0]["result"])
        self.assertIn("log", result[0]["reason"].lower())
    
    def test_route_to_vllm_search_keyword_no_longer_triggers(self):
        """Generic 'search' keyword must NOT route to vLLM.

        The old catch-all 'search'/'query' → vLLM rule was removed because it
        caused every search request to be treated as confidential.  A prompt
        that mentions neither a confidential index name nor a log-index prefix
        should now return an empty routing result (defaulting to vLLM via the
        agent's own fallback, not via the Mangle classifier).
        """
        result = self.engine.query("route_to_vllm", "search for something")
        self.assertEqual(len(result), 0)

    def test_route_to_vllm_query_keyword_no_longer_triggers(self):
        """Generic 'query' keyword must NOT route to vLLM.

        Same rationale as test_route_to_vllm_search_keyword_no_longer_triggers.
        """
        result = self.engine.query("route_to_vllm", "query the database")
        self.assertEqual(len(result), 0)
    
    # =========================================================================
    # Route to AI Core Tests
    # =========================================================================
    
    def test_route_to_aicore_cluster_health(self):
        """Test routing to AI Core for cluster health queries."""
        result = self.engine.query("route_to_aicore", "Check cluster health status")
        self.assertTrue(len(result) > 0)
        self.assertTrue(result[0]["result"])
        self.assertIn("health", result[0]["reason"].lower())
    
    def test_route_to_aicore_cluster_status(self):
        """Test routing to AI Core for cluster status queries."""
        result = self.engine.query("route_to_aicore", "Get cluster status")
        self.assertTrue(len(result) > 0)
        self.assertTrue(result[0]["result"])
    
    def test_route_to_aicore_products_index(self):
        """Test routing to AI Core for products index (public)."""
        result = self.engine.query("route_to_aicore", "List all products")
        self.assertTrue(len(result) > 0)
        self.assertTrue(result[0]["result"])
    
    def test_no_aicore_for_confidential(self):
        """Test that confidential queries don't route to AI Core."""
        # Customer query should go to vLLM, not AI Core
        result = self.engine.query("route_to_aicore", "Get customer data")
        self.assertEqual(len(result), 0)  # Should not route to AI Core
    
    # =========================================================================
    # Human Review Tests
    # =========================================================================
    
    def test_requires_human_review_create_index(self):
        """Test that create_index requires human review."""
        result = self.engine.query("requires_human_review", "create_index")
        self.assertTrue(len(result) > 0)
        self.assertTrue(result[0]["result"])
    
    def test_requires_human_review_delete_index(self):
        """Test that delete_index requires human review."""
        result = self.engine.query("requires_human_review", "delete_index")
        self.assertTrue(len(result) > 0)
        self.assertTrue(result[0]["result"])
    
    def test_requires_human_review_bulk_index(self):
        """Test that bulk_index requires human review."""
        result = self.engine.query("requires_human_review", "bulk_index")
        self.assertTrue(len(result) > 0)
        self.assertTrue(result[0]["result"])
    
    def test_requires_human_review_update_mapping(self):
        """Test that update_mapping requires human review."""
        result = self.engine.query("requires_human_review", "update_mapping")
        self.assertTrue(len(result) > 0)
        self.assertTrue(result[0]["result"])
    
    def test_no_human_review_for_search(self):
        """Test that search_query doesn't require human review."""
        result = self.engine.query("requires_human_review", "search_query")
        self.assertEqual(len(result), 0)  # Should not require review
    
    # =========================================================================
    # Safety Check Tests
    # =========================================================================
    
    def test_safety_check_search_query(self):
        """Test safety check passes for search_query."""
        result = self.engine.query("safety_check_passed", "search_query")
        self.assertTrue(len(result) > 0)
        self.assertTrue(result[0]["result"])
    
    def test_safety_check_aggregation_query(self):
        """Test safety check passes for aggregation_query."""
        result = self.engine.query("safety_check_passed", "aggregation_query")
        self.assertTrue(len(result) > 0)
        self.assertTrue(result[0]["result"])
    
    def test_safety_check_cluster_health(self):
        """Test safety check passes for cluster_health."""
        result = self.engine.query("safety_check_passed", "cluster_health")
        self.assertTrue(len(result) > 0)
        self.assertTrue(result[0]["result"])
    
    def test_safety_check_unknown_tool(self):
        """Test safety check fails for unknown tool."""
        result = self.engine.query("safety_check_passed", "unknown_tool")
        self.assertEqual(len(result), 0)  # Should not pass
    
    # =========================================================================
    # Prompting Policy Tests
    # =========================================================================
    
    def test_get_prompting_policy(self):
        """Test getting prompting policy."""
        result = self.engine.query("get_prompting_policy", "elasticsearch-search-v1")
        self.assertTrue(len(result) > 0)
        policy = result[0]
        self.assertIn("max_tokens", policy)
        self.assertIn("temperature", policy)
        self.assertIn("system_prompt", policy)
        self.assertEqual(policy["max_tokens"], 4096)
        self.assertEqual(policy["temperature"], 0.3)
    
    def test_get_prompting_policy_unknown(self):
        """Test getting prompting policy for unknown product."""
        result = self.engine.query("get_prompting_policy", "unknown-product")
        self.assertEqual(len(result), 0)


class TestElasticsearchAgent(unittest.TestCase):
    """Test the Elasticsearch Agent."""
    
    def setUp(self):
        self.agent = ElasticsearchAgent()
    
    def test_initialization(self):
        """Test agent initialization."""
        self.assertIsNotNone(self.agent.mangle)
        self.assertEqual(self.agent.mcp_endpoint, "http://localhost:9120/mcp")
        self.assertEqual(self.agent.vllm_endpoint, "http://localhost:9180/mcp")
        self.assertEqual(len(self.agent.audit_log), 0)
    
    # =========================================================================
    # Governance Check Tests
    # =========================================================================
    
    def test_check_governance_confidential(self):
        """Test governance check for confidential index."""
        governance = self.agent.check_governance("Search customers for email")
        self.assertEqual(governance["routing"]["backend"], "vllm")
        self.assertIn("customer", governance["routing"]["reason"].lower())
        self.assertEqual(governance["autonomy_level"], "L2")
        self.assertEqual(governance["data_product"], "elasticsearch-search-v1")
    
    def test_check_governance_public(self):
        """Test governance check for public index."""
        governance = self.agent.check_governance("Check cluster health status")
        self.assertEqual(governance["routing"]["backend"], "aicore")
        self.assertIn("health", governance["routing"]["reason"].lower())
    
    def test_check_governance_default(self):
        """Test governance check defaults to vLLM."""
        governance = self.agent.check_governance("Some generic request")
        # Should default to vLLM for safety
        self.assertEqual(governance["routing"]["backend"], "vllm")
    
    # =========================================================================
    # Invoke Tests (with mocking)
    # =========================================================================
    
    def test_invoke_requires_approval(self):
        """Test invoke returns pending_approval for high-risk actions."""
        result = asyncio.run(self.agent.invoke(
            "Delete the old_customers index",
            {"tool": "delete_index"}
        ))
        self.assertEqual(result["status"], "pending_approval")
        self.assertIn("delete_index", result["message"])
        self.assertEqual(result["tool"], "delete_index")
    
    def test_invoke_blocked_unknown_tool(self):
        """Test invoke blocks unknown tools."""
        result = asyncio.run(self.agent.invoke(
            "Do something",
            {"tool": "unknown_dangerous_tool"}
        ))
        self.assertEqual(result["status"], "blocked")
        self.assertIn("Safety check failed", result["message"])
    
    @patch.object(ElasticsearchAgent, '_call_mcp')
    def test_invoke_success(self, mock_mcp):
        """Test invoke succeeds for allowed tools."""
        mock_mcp.return_value = {"result": "success"}
        
        result = asyncio.run(self.agent.invoke(
            "Get cluster health",
            {"tool": "cluster_health"}
        ))
        
        self.assertEqual(result["status"], "success")
        self.assertIn("backend", result)
        self.assertIn("routing_reason", result)
    
    @patch.object(ElasticsearchAgent, '_call_mcp')
    def test_invoke_error_handling(self, mock_mcp):
        """Test invoke handles errors gracefully."""
        mock_mcp.side_effect = Exception("Connection failed")
        
        result = asyncio.run(self.agent.invoke(
            "Get cluster health",
            {"tool": "cluster_health"}
        ))
        
        self.assertEqual(result["status"], "error")
        self.assertIn("Connection failed", result["message"])
    
    # =========================================================================
    # Audit Log Tests
    # =========================================================================
    
    def test_audit_log_pending_approval(self):
        """Test audit log records pending approval."""
        asyncio.run(self.agent.invoke(
            "Delete index",
            {"tool": "delete_index"}
        ))
        
        log = self.agent.get_audit_log()
        self.assertEqual(len(log), 1)
        self.assertEqual(log[0]["status"], "pending_approval")
        self.assertEqual(log[0]["tool"], "delete_index")
        self.assertEqual(log[0]["agent"], "elasticsearch-agent")
    
    def test_audit_log_blocked(self):
        """Test audit log records blocked actions."""
        asyncio.run(self.agent.invoke(
            "Do something",
            {"tool": "unknown_tool"}
        ))
        
        log = self.agent.get_audit_log()
        self.assertEqual(len(log), 1)
        self.assertEqual(log[0]["status"], "blocked")
    
    def test_audit_log_prompt_hash(self):
        """Test audit log includes prompt hash (not raw prompt)."""
        asyncio.run(self.agent.invoke(
            "Secret customer data",
            {"tool": "delete_index"}
        ))
        
        log = self.agent.get_audit_log()
        self.assertIn("prompt_hash", log[0])
        self.assertIn("prompt_length", log[0])
        # Should NOT contain raw prompt
        self.assertNotIn("Secret customer data", str(log[0]))


class TestRoutingEdgeCases(unittest.TestCase):
    """Test edge cases in routing logic."""
    
    def setUp(self):
        self.engine = MangleEngine()
    
    def test_case_insensitive_routing(self):
        """Test routing is case insensitive."""
        result1 = self.engine.query("route_to_vllm", "CUSTOMER data")
        result2 = self.engine.query("route_to_vllm", "Customer Data")
        result3 = self.engine.query("route_to_vllm", "customer data")
        
        self.assertTrue(len(result1) > 0)
        self.assertTrue(len(result2) > 0)
        self.assertTrue(len(result3) > 0)
    
    def test_mixed_index_reference(self):
        """Test handling queries that mention both confidential and public."""
        # If query mentions both customer and products, should route to vLLM
        result = self.engine.query("route_to_vllm", "Compare customers with products")
        self.assertTrue(len(result) > 0)  # Should route to vLLM for safety
    
    def test_empty_request(self):
        """Test handling empty requests."""
        result = self.engine.query("route_to_vllm", "")
        self.assertEqual(len(result), 0)
    
    def test_none_request(self):
        """Test handling None requests."""
        result = self.engine.query("route_to_vllm")
        self.assertEqual(len(result), 0)


class TestWordBoundaryClassifier(unittest.TestCase):
    """Regression tests for the right-word-boundary fix in _matches_index_pattern.

    The original single-sided ``\b`` anchor prevented 'order' matching inside
    'disorder', but did not prevent false positives where a pattern appeared as
    a prefix of a longer token.  The right-side ``\b`` closes that gap.
    """

    def setUp(self):
        self.engine = MangleEngine()

    # -----------------------------------------------------------------
    # Patterns that SHOULD still trigger vLLM routing
    # -----------------------------------------------------------------

    def test_exact_stem_triggers(self):
        """Bare stem 'customer' triggers confidential routing."""
        result = self.engine.query("route_to_vllm", "search the customer index")
        self.assertTrue(len(result) > 0)

    def test_plural_stem_triggers(self):
        """Plural 'customers' triggers confidential routing (suffix of stem)."""
        result = self.engine.query("route_to_vllm", "query customers")
        self.assertTrue(len(result) > 0)

    def test_hyphenated_variant_triggers(self):
        """Hyphenated form 'customer-data' triggers confidential routing."""
        result = self.engine.query("route_to_vllm", "index customer-data")
        self.assertTrue(len(result) > 0)

    def test_order_index_triggers(self):
        """Index name 'orders' triggers confidential routing."""
        result = self.engine.query("route_to_vllm", "aggregate orders by status")
        self.assertTrue(len(result) > 0)

    # -----------------------------------------------------------------
    # Patterns that should NOT trigger vLLM (right-boundary regression)
    # -----------------------------------------------------------------

    def test_disorder_does_not_trigger_order(self):
        """'disorder' must not match the 'order' pattern (left-boundary guard)."""
        result = self.engine.query("route_to_vllm", "diagnose system disorder")
        self.assertEqual(len(result), 0)

    def test_log_prefix_triggers_only_on_token(self):
        """'logs-app' triggers log routing; 'dialogue' does not trigger 'log'."""
        logs_result = self.engine.query("route_to_vllm", "search logs-app for errors")
        self.assertTrue(len(logs_result) > 0)

        dialogue_result = self.engine.query("route_to_vllm", "analyse dialogue patterns")
        self.assertEqual(len(dialogue_result), 0)

    def test_audit_stem_triggers(self):
        """'audit' standalone and as prefix both trigger confidential routing.

        The boundary rule guards against mid-word matches (e.g. 'disorder'
        should not match 'order') but intentionally allows left-anchored
        prefix matches such as 'audit' inside 'auditing' or 'auditorium',
        since those tokens share the confidential stem.
        """
        audit_result = self.engine.query("route_to_vllm", "check audit trail")
        self.assertTrue(len(audit_result) > 0)

        # 'auditing' starts with the 'audit' stem — should also route to vLLM.
        auditing_result = self.engine.query("route_to_vllm", "auditing configuration changes")
        self.assertTrue(len(auditing_result) > 0)


class TestManglePredicates(unittest.TestCase):
    """Test various Mangle predicates."""
    
    def setUp(self):
        self.engine = MangleEngine()
    
    def test_unknown_predicate(self):
        """Test querying unknown predicate returns empty."""
        result = self.engine.query("unknown_predicate", "arg1")
        self.assertEqual(result, [])
    
    def test_all_confidential_indices_covered(self):
        """Test all confidential indices trigger vLLM routing."""
        confidential_keywords = ["customer", "order", "transaction", "trading", "financial", "audit"]
        
        for keyword in confidential_keywords:
            with self.subTest(keyword=keyword):
                result = self.engine.query("route_to_vllm", f"Query {keyword} data")
                self.assertTrue(len(result) > 0, f"Failed for keyword: {keyword}")
    
    def test_all_log_indices_covered(self):
        """Test all log index patterns trigger vLLM routing."""
        log_patterns = ["logs-", "metrics-", "traces-"]
        
        for pattern in log_patterns:
            with self.subTest(pattern=pattern):
                result = self.engine.query("route_to_vllm", f"Search {pattern}application for errors")
                self.assertTrue(len(result) > 0, f"Failed for pattern: {pattern}")


if __name__ == "__main__":
    unittest.main()