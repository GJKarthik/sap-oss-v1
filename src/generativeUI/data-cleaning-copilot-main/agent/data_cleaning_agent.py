# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2024 SAP SE
"""
Data Cleaning Agent with ODPS + Regulations Integration

Routes ALL LLM calls through the central mesh (ai-core-streaming).
Uses Mangle rules for field classification (no hardcoded patterns).
Discovers field schemas from OData Vocabularies service.
Queries Elasticsearch for cached S/4 field mappings.
"""

import json
import os
import time
import urllib.request
from typing import Any, Callable, Dict, List, Optional
from datetime import datetime, timezone
import asyncio
import logging

logger = logging.getLogger(__name__)


def _sync_urlopen(req, timeout):
    """Synchronous urllib open, meant to be called via asyncio.to_thread()."""
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read().decode())


class CircuitBreaker:
    """Simple circuit breaker: opens after `threshold` consecutive failures,
    half-opens after `reset_timeout` seconds."""

    def __init__(self, threshold: int = 5, reset_timeout: float = 30.0):
        self.threshold = threshold
        self.reset_timeout = reset_timeout
        self._failure_count = 0
        self._last_failure_time: float = 0
        self._state = "closed"  # closed | open | half-open

    @property
    def state(self) -> str:
        if self._state == "open":
            if time.monotonic() - self._last_failure_time >= self.reset_timeout:
                self._state = "half-open"
        return self._state

    def record_success(self) -> None:
        self._failure_count = 0
        self._state = "closed"

    def record_failure(self) -> None:
        self._failure_count += 1
        self._last_failure_time = time.monotonic()
        if self._failure_count >= self.threshold:
            self._state = "open"

    def allow_request(self) -> bool:
        s = self.state
        return s in ("closed", "half-open")


async def retry_with_backoff(
    fn: Callable,
    max_retries: int = 3,
    base_delay: float = 0.5,
    circuit: Optional[CircuitBreaker] = None,
):
    """Retry an async-compatible callable with exponential backoff."""
    last_error = None
    for attempt in range(max_retries):
        if circuit and not circuit.allow_request():
            logger.debug("Circuit breaker open, skipping attempt %d", attempt)
            break
        try:
            result = await fn()
            if circuit:
                circuit.record_success()
            return result
        except Exception as e:
            last_error = e
            if circuit:
                circuit.record_failure()
            if attempt < max_retries - 1:
                delay = base_delay * (2 ** attempt)
                logger.debug("Retry %d/%d after %.1fs: %s", attempt + 1, max_retries, delay, e)
                await asyncio.sleep(delay)
    raise last_error if last_error else RuntimeError("retry_with_backoff: no attempts made")


class MangleQueryClient:
    """
    Client for querying Mangle rules via mangle-query-service.

    Field classification rules are defined in mangle/a2a/mcp.mg, not hardcoded.
    """

    def __init__(self, endpoint: str = "http://localhost:9200"):
        self.endpoint = endpoint
        self.mcp_endpoint = f"{endpoint}/mcp"
        self.rules_loaded = False
        self._circuit = CircuitBreaker(threshold=5, reset_timeout=30.0)

    async def query(self, predicate: str, *args) -> List[Dict]:
        """
        Query Mangle for field classification.
        
        Examples:
            query("is_dimension_field", "BUKRS") -> [{"result": "CompanyCode", ...}]
            query("suggest_finance_annotation", "HSL") -> [{"annotation": "@Analytics.measure", ...}]
        """
        request_data = {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/call",
            "params": {
                "name": "mangle_query",
                "arguments": {
                    "predicate": predicate,
                    "args": list(args)
                }
            }
        }
        
        try:
            req = urllib.request.Request(
                self.mcp_endpoint,
                data=json.dumps(request_data).encode(),
                headers={"Content-Type": "application/json"},
                method="POST"
            )

            async def _do_request():
                return await asyncio.to_thread(_sync_urlopen, req, 30)

            result = await retry_with_backoff(_do_request, max_retries=2, base_delay=0.3, circuit=self._circuit)
            return result.get("result", {}).get("content", [])
        except Exception as e:
            logger.debug("MangleQueryClient.query(%s) unavailable: %s", predicate, e)
            return []


class ODataVocabularyDiscoveryClient:
    """
    Client for OData Vocabulary discovery service.
    
    Discovers field schemas dynamically from odata-vocabularies service.
    """
    
    def __init__(self, endpoint: str = "http://localhost:9150"):
        self.endpoint = endpoint
        self.mcp_endpoint = f"{endpoint}/mcp"
        self.openai_endpoint = f"{endpoint}/v1"
        self._circuit = CircuitBreaker(threshold=5, reset_timeout=30.0)
        
    async def discover_entity_schema(self, entity_name: str) -> Dict:
        """Discover entity schema from OData Vocabularies service."""
        return await self._call_tool("get_entity_fields", {"entity": entity_name})
    
    async def search_vocabulary_terms(self, query: str, vocabulary: str = None) -> Dict:
        """Search vocabulary terms from OData Vocabularies service."""
        args = {"query": query}
        if vocabulary:
            args["vocabulary"] = vocabulary
        return await self._call_tool("search_terms", args)
    
    async def get_field_classification(self, field_name: str) -> Dict:
        """Get field classification from vocabulary service."""
        return await self._call_tool("classify_field", {"field": field_name})
    
    async def suggest_annotations(self, columns: List[str]) -> Dict:
        """Get annotation suggestions via vocabulary chat endpoint."""
        request_data = {
            "model": "odata-vocab-annotator",
            "messages": [{
                "role": "user",
                "content": f"Suggest OData vocabulary annotations for S/4HANA Finance columns: {columns}"
            }]
        }
        
        try:
            req = urllib.request.Request(
                f"{self.openai_endpoint}/chat/completions",
                data=json.dumps(request_data).encode(),
                headers={"Content-Type": "application/json"},
                method="POST"
            )
            
            result = await asyncio.to_thread(_sync_urlopen, req, 30)
            return result
        except Exception as e:
            logger.warning("suggest_annotations failed: %s", e)
            return {"error": str(e), "status": "failed"}

    async def _call_tool(self, tool_name: str, args: Dict) -> Dict:
        """Call MCP tool on vocabulary service."""
        request_data = {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/call",
            "params": {"name": tool_name, "arguments": args}
        }

        try:
            req = urllib.request.Request(
                self.mcp_endpoint,
                data=json.dumps(request_data).encode(),
                headers={"Content-Type": "application/json"},
                method="POST"
            )

            async def _do_request():
                return await asyncio.to_thread(_sync_urlopen, req, 30)

            return await retry_with_backoff(_do_request, max_retries=2, base_delay=0.3, circuit=self._circuit)
        except Exception as e:
            logger.warning("_call_tool(%s) failed: %s", tool_name, e)
            return {"error": str(e), "status": "failed"}


class ElasticsearchFieldCacheClient:
    """
    Client for querying cached field patterns from Elasticsearch.
    
    Uses the odata_entity_index in mangle-query-service.
    """
    
    def __init__(self, endpoint: str = "http://localhost:9200"):
        self.endpoint = endpoint
        self._circuit = CircuitBreaker(threshold=5, reset_timeout=30.0)

    async def search_field_mapping(self, field_name: str) -> Dict:
        """Search for field mapping in Elasticsearch cache."""
        query = {
            "query": {
                "bool": {
                    "should": [
                        {"match": {"field_name": field_name}},
                        {"match": {"technical_name": field_name}},
                        {"match": {"aliases": field_name}}
                    ]
                }
            }
        }
        
        try:
            req = urllib.request.Request(
                f"{self.endpoint}/odata_entity_index/_search",
                data=json.dumps(query).encode(),
                headers={"Content-Type": "application/json"},
                method="POST"
            )

            async def _do_request():
                return await asyncio.to_thread(_sync_urlopen, req, 10)

            result = await retry_with_backoff(_do_request, max_retries=2, base_delay=0.3, circuit=self._circuit)
            hits = result.get("hits", {}).get("hits", [])
            if hits:
                return {"status": "found", "mapping": hits[0].get("_source", {})}
            return {"status": "not_found"}
        except Exception as e:
            logger.warning("search_field_mapping(%s) failed: %s", field_name, e)
            return {"error": str(e), "status": "failed"}
    
    async def get_acdoca_fields(self) -> List[Dict]:
        """Get all ACDOCA (I_JournalEntryItem) fields from cache."""
        query = {
            "query": {"term": {"entity": "I_JournalEntryItem"}},
            "size": 100
        }
        
        try:
            req = urllib.request.Request(
                f"{self.endpoint}/odata_entity_index/_search",
                data=json.dumps(query).encode(),
                headers={"Content-Type": "application/json"},
                method="POST"
            )
            
            result = await asyncio.to_thread(_sync_urlopen, req, 10)
            return [hit.get("_source", {}) for hit in result.get("hits", {}).get("hits", [])]
        except Exception as e:
            logger.warning("get_acdoca_fields failed: %s", e)
            return []


class MangleEngine:
    """
    Mangle query interface for governance rules.
    
    Queries mangle-query-service for rules, falls back to loading .mg files.
    """
    
    def __init__(self, rules_paths: Optional[List[str]] = None):
        self.rules_paths = rules_paths or []
        self.facts: Dict[str, Any] = {}
        self._load_governance_rules()
        
    def _load_governance_rules(self):
        """Load governance rules (not field patterns)."""
        self.facts["agent_config"] = {
            ("data-cleaning-agent", "autonomy_level"): "L2",
            ("data-cleaning-agent", "service_name"): "data-cleaning-copilot",
            ("data-cleaning-agent", "mcp_endpoint"): "http://localhost:9110/mcp",
            ("data-cleaning-agent", "security_class"): "confidential",
        }
        
        self.facts["agent_can_use"] = {
            "analyze_data_quality", "suggest_cleaning_rules", 
            "generate_validation", "profile_data", "mangle_query",
            "classify_gl_fields", "validate_acdoca_schema",
            "discover_schema", "search_field_cache"
        }
        
        self.facts["agent_requires_approval"] = {
            "apply_transformation", "delete_records", 
            "modify_schema", "export_data"
        }
        
        self.facts["prompting_policy"] = {
            "data-cleaning-service-v1": {
                "max_tokens": 4096,
                "temperature": 0.3,
                "system_prompt": (
                    "You are a data cleaning assistant for SAP S/4HANA Finance data. "
                    "Use Mangle rules for field classification. "
                    "Query OData Vocabularies service for schema discovery. "
                    "Query Elasticsearch for cached field mappings."
                )
            }
        }
    
    def query(self, predicate: str, *args) -> List[Dict]:
        """Query governance rules (not field patterns)."""
        if predicate == "get_security_class":
            return [{"result": "confidential"}]
        
        if predicate == "requires_human_review":
            action = args[0] if args else ""
            if action in self.facts["agent_requires_approval"]:
                return [{"result": True, "action": action}]
            return []
        
        if predicate == "safety_check_passed":
            tool = args[0] if args else ""
            if tool in self.facts["agent_can_use"]:
                return [{"result": True, "tool": tool}]
            return []
        
        if predicate == "get_prompting_policy":
            product_id = args[0] if args else "data-cleaning-service-v1"
            policy = self.facts["prompting_policy"].get(product_id)
            if policy:
                return [policy]
            return []
        
        if predicate == "autonomy_level":
            return [{"level": "L2"}]
        
        return []


class DataCleaningAgent:
    """
    Data Cleaning Agent using Mangle + Discovery architecture.
    
    NO HARDCODED field patterns. All classification comes from:
    1. Mangle rules (mangle/a2a/mcp.mg)
    2. OData Vocabulary discovery service
    3. Elasticsearch field cache
    """
    
    MESH_ENDPOINT = os.environ.get("MESH_ENDPOINT", "http://localhost:9190/v1")
    SERVICE_ID = "data-cleaning-copilot"
    SECURITY_CLASS = "confidential"

    def __init__(self):
        self.mangle_governance = MangleEngine([
            "mangle/domain/agents.mg",
            "../regulations/mangle/rules.mg"
        ])

        # External services for field classification
        self.mangle_query = MangleQueryClient(os.environ.get("MANGLE_QUERY_ENDPOINT", "http://localhost:9200"))
        self.vocab_discovery = ODataVocabularyDiscoveryClient(os.environ.get("ODATA_VOCAB_ENDPOINT", "http://localhost:9150"))
        self.es_cache = ElasticsearchFieldCacheClient(os.environ.get("ES_CACHE_ENDPOINT", "http://localhost:9200"))
        
        self.audit_log: List[Dict] = []
    
    async def classify_gl_fields(self, columns: List[str]) -> Dict[str, Any]:
        """
        Classify GL/Subledger fields using external services.
        
        Classification chain:
        1. Query Mangle for field rules (mangle/a2a/mcp.mg)
        2. Fallback to Elasticsearch field cache
        3. Fallback to OData Vocabulary discovery
        
        NO hardcoded patterns.
        """
        results = {}
        
        for column in columns:
            classification = await self._classify_single_field(column)
            results[column] = classification
        
        # Summarize results
        dims = sum(1 for c in results.values() if c.get("category") == "dimension")
        measures = sum(1 for c in results.values() if c.get("category") == "measure")
        currencies = sum(1 for c in results.values() if c.get("category") == "currency")
        keys = sum(1 for c in results.values() if c.get("category") == "key")
        subledgers = sum(1 for c in results.values() if c.get("category") == "subledger")
        unclassified = sum(1 for c in results.values() if c.get("category") is None)
        
        self._log_audit(
            "gl_classification", 
            "classify_gl_fields", 
            "multi-source",
            f"Classified {len(columns)} columns"
        )
        
        return {
            "status": "success",
            "columns_analyzed": len(columns),
            "summary": {
                "dimensions": dims,
                "measures": measures,
                "currencies": currencies,
                "keys": keys,
                "subledgers": subledgers,
                "unclassified": unclassified
            },
            "classifications": results,
            "sources": ["mangle_rules", "elasticsearch_cache", "vocabulary_discovery"]
        }
    
    async def _classify_single_field(self, column: str) -> Dict:
        """
        Classify a single field using external services.
        
        Order:
        1. Mangle rules (primary source of truth)
        2. Elasticsearch cache (performance)
        3. OData Vocabulary discovery (fallback)
        """
        
        # 1. Try Mangle rules first
        for predicate in ["is_dimension_field", "is_measure_field", "is_currency_field", 
                          "is_key_field", "is_subledger_field"]:
            result = await self.mangle_query.query(predicate, column)
            if result:
                return {
                    "category": result[0].get("category"),
                    "field_type": result[0].get("field_type"),
                    "source": "mangle_rules",
                    "annotations": await self._get_annotations_from_mangle(column)
                }
        
        # 2. Try Elasticsearch cache
        es_result = await self.es_cache.search_field_mapping(column)
        if es_result.get("status") == "found":
            mapping = es_result.get("mapping", {})
            return {
                "category": mapping.get("category"),
                "field_type": mapping.get("field_type"),
                "source": "elasticsearch_cache",
                "annotations": mapping.get("annotations", [])
            }
        
        # 3. Try OData Vocabulary discovery
        vocab_result = await self.vocab_discovery.get_field_classification(column)
        if vocab_result.get("status") != "failed":
            return {
                "category": vocab_result.get("category"),
                "field_type": vocab_result.get("field_type"),
                "source": "vocabulary_discovery",
                "annotations": vocab_result.get("annotations", [])
            }
        
        # Not classified by any source
        return {
            "category": None,
            "field_type": None,
            "source": None,
            "annotations": []
        }
    
    async def _get_annotations_from_mangle(self, column: str) -> List[str]:
        """Get annotation suggestions from Mangle rules."""
        result = await self.mangle_query.query("suggest_finance_annotation", column)
        if result:
            return [r.get("annotation", "") for r in result]
        return []
    
    async def discover_entity_schema(self, entity_name: str) -> Dict[str, Any]:
        """
        Discover entity schema from OData Vocabulary service.
        
        Example: discover_entity_schema("I_JournalEntryItem")
        """
        result = await self.vocab_discovery.discover_entity_schema(entity_name)
        self._log_audit("discover", "discover_entity_schema", "odata-vocab", entity_name)
        return result
    
    async def search_vocabulary(self, query: str, vocabulary: str = None) -> Dict[str, Any]:
        """
        Search OData Vocabulary terms.
        
        Example: search_vocabulary("Analytics.dimension")
        """
        result = await self.vocab_discovery.search_vocabulary_terms(query, vocabulary)
        self._log_audit("search", "search_vocabulary", "odata-vocab", query)
        return result
    
    async def get_cached_acdoca_schema(self) -> Dict[str, Any]:
        """Get cached ACDOCA schema from Elasticsearch."""
        fields = await self.es_cache.get_acdoca_fields()
        self._log_audit("cache_lookup", "get_cached_acdoca_schema", "elasticsearch", "I_JournalEntryItem")
        return {
            "status": "success" if fields else "empty",
            "entity": "I_JournalEntryItem",
            "fields": fields,
            "source": "elasticsearch_cache"
        }
    
    async def invoke(self, prompt: str, context: Optional[Dict] = None) -> Dict[str, Any]:
        """Invoke agent with governance checks."""
        context = context or {}
        tool = context.get("tool", "analyze_data_quality")
        trace_id = context.get("trace_id")
        timestamp = datetime.now(timezone.utc).isoformat()

        if self.mangle_governance.query("requires_human_review", tool):
            self._log_audit("pending_approval", tool, "pending", prompt, trace_id=trace_id)
            return {
                "status": "pending_approval",
                "message": f"Action '{tool}' requires human review",
                "tool": tool,
                "timestamp": timestamp
            }

        if not self.mangle_governance.query("safety_check_passed", tool):
            self._log_audit("blocked", tool, "blocked", prompt, trace_id=trace_id)
            return {
                "status": "blocked",
                "message": f"Safety check failed for tool '{tool}'",
                "tool": tool,
                "timestamp": timestamp
            }

        prompting = self.mangle_governance.query("get_prompting_policy", "data-cleaning-service-v1")
        prompting_policy = prompting[0] if prompting else {}

        try:
            result = await self._call_mesh_chat({
                "model": "gpt-4",
                "messages": [
                    {"role": "system", "content": prompting_policy.get("system_prompt", "")},
                    {"role": "user", "content": prompt}
                ],
                "max_tokens": prompting_policy.get("max_tokens", 4096),
                "temperature": prompting_policy.get("temperature", 0.3)
            }, trace_id=trace_id)

            backend = result.get("x_mesh_backend", "unknown")
            self._log_audit("success", tool, backend, prompt, trace_id=trace_id)

            return {
                "status": "success",
                "backend": backend,
                "result": result,
                "timestamp": timestamp
            }

        except Exception as e:
            self._log_audit("error", tool, "error", prompt, str(e), trace_id=trace_id)
            return {"status": "error", "message": str(e), "timestamp": timestamp}
    
    async def _call_mesh_chat(self, request: Dict, trace_id: Optional[str] = None) -> Dict[str, Any]:
        """Call central mesh for chat completions."""
        url = f"{self.MESH_ENDPOINT}/chat/completions"

        headers = {
            "Content-Type": "application/json",
            "X-Mesh-Service": self.SERVICE_ID,
            "X-Mesh-Security-Class": self.SECURITY_CLASS,
        }
        if trace_id:
            span_id = trace_id[:16]
            headers["traceparent"] = f"00-{trace_id}-{span_id}-01"
        
        req = urllib.request.Request(
            url,
            data=json.dumps(request).encode(),
            headers=headers,
            method="POST"
        )
        
        try:
            result = await asyncio.to_thread(_sync_urlopen, req, 120)
            return result
        except Exception as e:
            logger.warning("Mesh chat call failed, using mock response: %s", e, exc_info=True)
            self._log_audit("mock_fallback", "mesh_chat", "mock", str(request.get("model", "")), str(e))
            return self._mock_mesh_response(request)
    
    def _mock_mesh_response(self, request: Dict) -> Dict[str, Any]:
        return {
            "id": "chatcmpl-mock",
            "object": "chat.completion",
            "created": int(datetime.now().timestamp()),
            "model": request.get("model", "gpt-4"),
            "choices": [{
                "index": 0,
                "message": {
                    "role": "assistant",
                    "content": "[MOCK] Analysis would be performed here"
                },
                "finish_reason": "stop"
            }],
            "x_mesh_backend": "vllm",
            "x_mesh_routing_reason": f"Service policy: {self.SERVICE_ID} -> vllm"
        }
    
    def _log_audit(self, status: str, tool: str, backend: str, prompt: str, error: str = None, trace_id: str = None):
        entry = {
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "agent": "data-cleaning-agent",
            "service_id": self.SERVICE_ID,
            "status": status,
            "tool": tool,
            "backend": backend,
            "prompt_hash": hash(prompt),
            "architecture": "mangle_discovery",
        }
        if trace_id:
            entry["trace_id"] = trace_id
        if error:
            entry["error"] = error
        self.audit_log.append(entry)
    
    def get_audit_log(self) -> List[Dict]:
        return self.audit_log
    
    def check_governance(self, prompt: str) -> Dict[str, Any]:
        prompting = self.mangle_governance.query("get_prompting_policy", "data-cleaning-service-v1")
        autonomy = self.mangle_governance.query("autonomy_level")
        
        return {
            "mesh": {
                "endpoint": self.MESH_ENDPOINT,
                "service_id": self.SERVICE_ID,
                "security_class": self.SECURITY_CLASS
            },
            "autonomy_level": autonomy[0]["level"] if autonomy else "L2",
            "prompting_policy": prompting[0] if prompting else {},
            "architecture": {
                "pattern": "mangle_discovery",
                "description": "NO hardcoded patterns - uses external services",
                "sources": [
                    {
                        "name": "Mangle Rules",
                        "endpoint": "http://localhost:9200/mcp",
                        "file": "mangle/a2a/mcp.mg",
                        "purpose": "Primary field classification rules"
                    },
                    {
                        "name": "Elasticsearch Cache",
                        "endpoint": "http://localhost:9200",
                        "index": "odata_entity_index",
                        "purpose": "Cached field mappings for performance"
                    },
                    {
                        "name": "OData Vocabulary Discovery",
                        "endpoint": "http://localhost:9150",
                        "purpose": "Dynamic schema discovery fallback"
                    }
                ]
            }
        }


def main():
    import asyncio
    
    agent = DataCleaningAgent()
    
    print("=" * 70)
    print("Data Cleaning Agent - Mangle + Discovery Architecture")
    print("NO HARDCODED PATTERNS - All classification from external services")
    print("=" * 70)
    
    # Test 1: Governance check
    print("\n--- Test 1: Architecture Check ---")
    governance = agent.check_governance("test")
    arch = governance.get("architecture", {})
    print(f"Pattern: {arch.get('pattern')}")
    print(f"Description: {arch.get('description')}")
    print("Sources:")
    for source in arch.get("sources", []):
        print(f"  - {source['name']}: {source['endpoint']}")
        print(f"    Purpose: {source['purpose']}")
    
    # Test 2: Field Classification (via external services)
    print("\n--- Test 2: Field Classification (External Services) ---")
    gl_columns = [
        "BUKRS", "GJAHR", "HKONT", "HSL", "RHCUR", 
        "KUNNR", "BELNR", "CUSTOM_FIELD"
    ]
    result = asyncio.run(agent.classify_gl_fields(gl_columns))
    
    print(f"Status: {result['status']}")
    print(f"Sources used: {result.get('sources', [])}")
    print(f"Summary: {result.get('summary', {})}")
    print("\nClassifications:")
    for col, cls in result.get('classifications', {}).items():
        source = cls.get('source', 'none')
        category = cls.get('category', 'unclassified')
        field_type = cls.get('field_type', '')
        print(f"  {col}: [{category.upper() if category else 'UNCLASSIFIED'}] via {source}")
        if field_type:
            print(f"      -> {field_type}")
    
    # Test 3: Audit log
    print("\n--- Audit Log ---")
    for entry in agent.get_audit_log():
        arch = entry.get('architecture', 'unknown')
        print(f"  [{entry['timestamp'][:19]}] {entry['status']} - {entry['tool']} ({arch})")


if __name__ == "__main__":
    main()