"""
AI Core PAL Agent with ODPS + Regulations Integration

MCP Integration with SAP HANA Predictive Analysis Library (PAL).
Always routes to vLLM - HANA data is enterprise confidential.
"""

import json
import urllib.request
from typing import Any, Dict, List, Optional
from datetime import datetime, timezone
import asyncio

# Graph-RAG: HippoCPP-backed KùzuDB store with graceful fallback
_kuzu_store_factory = None
try:
    import sys as _sys
    import os as _os
    _mcp_dir = _os.path.join(_os.path.dirname(__file__), "..", "mcp_server")
    if _os.path.isdir(_mcp_dir) and _mcp_dir not in _sys.path:
        _sys.path.insert(0, _os.path.abspath(_mcp_dir))
    from kuzu_store import get_kuzu_store as _get_kuzu_store
    _kuzu_store_factory = _get_kuzu_store
except ImportError:
    _kuzu_store_factory = None


def _parse_json_arg(value: Any, default: Any) -> Any:
    if value is None:
        return default
    if isinstance(value, (dict, list)):
        return value
    try:
        return json.loads(str(value))
    except Exception:
        return default


class VocabularyClient:
    """Client for OData Vocabularies service - Analytics vocabulary integration."""
    
    def __init__(self, endpoint: str = "http://localhost:9150"):
        self.endpoint = endpoint
        self.openai_endpoint = f"{endpoint}/v1"
    
    async def get_analytics_annotations(self, pal_function: str) -> Dict:
        """Get Analytics vocabulary annotations for PAL function output."""
        return await self._chat_completion(
            model="odata-vocab-annotator",
            content=f"Suggest Analytics vocabulary annotations for PAL function output: {pal_function}. Include @Analytics.Measure for KPIs and @Analytics.Dimension for grouping columns."
        )
    
    async def annotate_kpi(self, kpi_definition: Dict) -> Dict:
        """Annotate KPI with Analytics.Measure vocabulary."""
        return await self._chat_completion(
            model="odata-vocab-annotator",
            content=f"Generate Analytics vocabulary annotations for this KPI: {json.dumps(kpi_definition)}. Focus on @Analytics.Measure, @Analytics.AccumulativeMeasure, and aggregation types."
        )
    
    async def get_measure_annotation(self, column_name: str, column_type: str) -> Dict:
        """Get appropriate Analytics.Measure annotation for a column."""
        return await self._chat_completion(
            model="odata-vocab-search",
            content=f"What Analytics vocabulary annotation should I use for column '{column_name}' of type '{column_type}'?"
        )
    
    async def suggest_dimension_annotations(self, columns: List[str]) -> Dict:
        """Suggest Analytics.Dimension annotations for dimension columns."""
        return await self._chat_completion(
            model="odata-vocab-annotator",
            content=f"Suggest Analytics.Dimension annotations for these dimension columns: {columns}"
        )
    
    async def lookup_analytics_term(self, term: str) -> Dict:
        """Look up a specific Analytics vocabulary term."""
        return await self._call_tool("get_term", {
            "vocabulary": "Analytics",
            "term": term
        })
    
    async def search_analytics_terms(self, query: str) -> Dict:
        """Search Analytics vocabulary terms."""
        return await self._call_tool("search_terms", {
            "query": query,
            "vocabulary": "Analytics"
        })
    
    async def _chat_completion(self, model: str, content: str) -> Dict:
        """Call OpenAI-compatible chat endpoint."""
        request_data = {
            "model": model,
            "messages": [{"role": "user", "content": content}]
        }
        
        try:
            req = urllib.request.Request(
                f"{self.openai_endpoint}/chat/completions",
                data=json.dumps(request_data).encode(),
                headers={"Content-Type": "application/json"},
                method="POST"
            )
            
            with urllib.request.urlopen(req, timeout=30) as resp:
                return json.loads(resp.read().decode())
        except Exception as e:
            return {"error": str(e), "status": "failed"}
    
    async def _call_tool(self, tool_name: str, args: Dict) -> Dict:
        """Call MCP tool."""
        request_data = {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/call",
            "params": {"name": tool_name, "arguments": args}
        }
        
        try:
            req = urllib.request.Request(
                f"{self.endpoint}/mcp",
                data=json.dumps(request_data).encode(),
                headers={"Content-Type": "application/json"},
                method="POST"
            )
            
            with urllib.request.urlopen(req, timeout=30) as resp:
                return json.loads(resp.read().decode())
        except Exception as e:
            return {"error": str(e), "status": "failed"}


class MangleEngine:
    """Mangle query interface for governance rules."""
    
    def __init__(self, rules_paths: Optional[List[str]] = None):
        self.rules_paths = rules_paths or []
        self.facts: Dict[str, Any] = {}
        self._load_rules()
    
    def _load_rules(self):
        self.facts["agent_config"] = {
            ("aicore-pal-agent", "autonomy_level"): "L2",
            ("aicore-pal-agent", "service_name"): "aicore-pal",
            ("aicore-pal-agent", "mcp_endpoint"): "http://localhost:8084/mcp",
            ("aicore-pal-agent", "default_backend"): "vllm",
        }
        
        self.facts["agent_can_use"] = {
            "pal_classification", "pal_regression", "pal_clustering",
            "pal_forecast", "pal_anomaly", "mangle_query",
            "kuzu_index", "kuzu_query"
        }
        
        self.facts["agent_requires_approval"] = {
            "pal_train_model", "pal_delete_model", "hana_write"
        }
        
        self.facts["prompting_policy"] = {
            "aicore-pal-service-v1": {
                "max_tokens": 4096,
                "temperature": 0.3,
                "system_prompt": (
                    "You are an AI assistant for SAP HANA PAL predictive analytics. "
                    "Help users understand ML results, interpret predictions, and guide analysis. "
                    "All data processed is enterprise confidential - use on-premise LLM only. "
                    "Never send enterprise data or ML results to external services."
                )
            }
        }
    
    def query(self, predicate: str, *args) -> List[Dict]:
        # Always route to vLLM - HANA data is confidential
        if predicate == "route_to_vllm":
            return [{"result": True, "reason": "HANA PAL data is confidential"}]
        
        if predicate == "route_to_aicore":
            return []  # Never route to external
        
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
            product_id = args[0] if args else "aicore-pal-service-v1"
            policy = self.facts["prompting_policy"].get(product_id)
            if policy:
                return [policy]
            return []
        
        if predicate == "autonomy_level":
            return [{"level": "L2"}]
        
        return []


class AICorePALAgent:
    """
    AI Core PAL Agent - vLLM only for HANA data.
    
    Provides governance-aware access to SAP HANA PAL
    predictive analytics operations.
    
    Now integrated with OData Vocabularies for Analytics
    vocabulary annotations on PAL output columns.
    """
    
    def __init__(self):
        self.mangle = MangleEngine([
            "mangle/domain/agents.mg",
            "../regulations/mangle/rules.mg"
        ])
        self.mcp_endpoint = "http://localhost:8084/mcp"
        self.vllm_endpoint = "http://localhost:9180/mcp"
        self.vocab_client = VocabularyClient("http://localhost:9150")
        self.audit_log: List[Dict] = []
    
    async def handle_kuzu_index(self, args: Dict[str, Any]) -> Dict[str, Any]:
        """Index PAL algorithms, HANA tables, mesh services, and query intents into K\u00f9zuDB."""
        if _kuzu_store_factory is None:
            return {"error": "K\u00f9zuDB not available; install hippocpp or kuzu>=0.7.0"}
        store = _kuzu_store_factory()
        if not store.available():
            return {"error": "K\u00f9zuDB backend unavailable; check hippocpp installation"}
        store.ensure_schema()

        algos_indexed = 0
        tables_indexed = 0
        services_indexed = 0
        intents_indexed = 0

        raw_algos = _parse_json_arg(args.get("algorithms", "[]"), [])
        if isinstance(raw_algos, list):
            for a in raw_algos:
                if not isinstance(a, dict):
                    continue
                algo_id = str(a.get("algoId", "")).strip()
                if not algo_id:
                    continue
                store.upsert_pal_algorithm(
                    algo_id,
                    str(a.get("name", "")),
                    str(a.get("category", "")),
                    str(a.get("procedure", "")),
                    str(a.get("description", "")),
                )
                algos_indexed += 1
                related = str(a.get("relatedAlgo", "")).strip()
                if related:
                    store.link_related_algos(algo_id, related)

        raw_tables = _parse_json_arg(args.get("hana_tables", "[]"), [])
        if isinstance(raw_tables, list):
            for t in raw_tables:
                if not isinstance(t, dict):
                    continue
                table_id = str(t.get("tableId", "")).strip()
                if not table_id:
                    continue
                store.upsert_hana_table(
                    table_id,
                    str(t.get("name", "")),
                    str(t.get("schema_name", "")),
                    str(t.get("table_type", "")),
                )
                tables_indexed += 1
                executes_on = str(t.get("executedBy", "")).strip()
                if executes_on:
                    store.link_algo_table(executes_on, table_id)

        raw_services = _parse_json_arg(args.get("mesh_services", "[]"), [])
        if isinstance(raw_services, list):
            for s in raw_services:
                if not isinstance(s, dict):
                    continue
                service_id = str(s.get("serviceId", "")).strip()
                if not service_id:
                    continue
                store.upsert_mesh_service(
                    service_id,
                    str(s.get("name", "")),
                    str(s.get("url", "")),
                    int(s.get("port", 0)),
                    int(s.get("priority", 1)),
                )
                services_indexed += 1

        raw_intents = _parse_json_arg(args.get("query_intents", "[]"), [])
        if isinstance(raw_intents, list):
            for i in raw_intents:
                if not isinstance(i, dict):
                    continue
                intent_id = str(i.get("intentId", "")).strip()
                if not intent_id:
                    continue
                store.upsert_query_intent(
                    intent_id,
                    str(i.get("name", "")),
                    str(i.get("pattern", "")),
                    str(i.get("category", "")),
                )
                intents_indexed += 1
                routes_to = str(i.get("routesTo", "")).strip()
                if routes_to:
                    store.link_intent_service(intent_id, routes_to)
                served_by = str(i.get("servedBy", "")).strip()
                if served_by:
                    store.link_intent_algo(intent_id, served_by)

        return {
            "algos_indexed": algos_indexed,
            "tables_indexed": tables_indexed,
            "services_indexed": services_indexed,
            "intents_indexed": intents_indexed,
        }

    async def handle_kuzu_query(self, args: Dict[str, Any]) -> Dict[str, Any]:
        """Execute a read-only Cypher query against the K\u00f9zuDB graph (HippoCPP backend)."""
        cypher = str(args.get("cypher", "") or "").strip()
        if not cypher:
            return {"error": "cypher is required"}
        upper = cypher.upper().lstrip()
        for disallowed in ("CREATE ", "MERGE ", "DELETE ", "SET ", "REMOVE ", "DROP "):
            if upper.startswith(disallowed):
                return {"error": "Write Cypher statements are not permitted via this tool"}
        if _kuzu_store_factory is None:
            return {"error": "K\u00f9zuDB not available; install hippocpp or kuzu>=0.7.0"}
        store = _kuzu_store_factory()
        if not store.available():
            return {"error": "K\u00f9zuDB backend unavailable; check hippocpp installation"}
        params = _parse_json_arg(args.get("params", "{}"), {})
        if not isinstance(params, dict):
            params = {}
        rows = store.run_query(cypher, params)
        return {"rows": rows, "rowCount": len(rows)}

    async def invoke(self, prompt: str, context: Optional[Dict] = None) -> Dict[str, Any]:
        context = context or {}
        tool = context.get("tool", "pal_classification")
        timestamp = datetime.now(timezone.utc).isoformat()

        # Dispatch graph-RAG tools directly
        if tool == "kuzu_index":
            return await self.handle_kuzu_index(context.get("args", {}))
        if tool == "kuzu_query":
            return await self.handle_kuzu_query(context.get("args", {}))

        # Always vLLM for HANA data
        backend = "vllm"
        endpoint = self.vllm_endpoint
        routing_reason = "HANA PAL data is enterprise confidential - vLLM only"
        
        # Check if human review required
        if self.mangle.query("requires_human_review", tool):
            self._log_audit("pending_approval", tool, backend, prompt)
            return {
                "status": "pending_approval",
                "message": f"ML action '{tool}' requires human review",
                "tool": tool,
                "backend": backend,
                "timestamp": timestamp
            }
        
        # Safety check
        if not self.mangle.query("safety_check_passed", tool):
            self._log_audit("blocked", tool, backend, prompt)
            return {
                "status": "blocked",
                "message": f"Safety check failed for tool '{tool}'",
                "tool": tool,
                "timestamp": timestamp
            }
        
        # Get prompting policy
        prompting = self.mangle.query("get_prompting_policy", "aicore-pal-service-v1")
        prompting_policy = prompting[0] if prompting else {}
        
        # Execute via vLLM
        try:
            result = await self._call_mcp(endpoint, tool, {
                "messages": json.dumps([{
                    "role": "system", 
                    "content": prompting_policy.get("system_prompt", "")
                }, {
                    "role": "user", 
                    "content": prompt
                }]),
                "max_tokens": prompting_policy.get("max_tokens", 4096),
                "temperature": prompting_policy.get("temperature", 0.3)
            })
            
            self._log_audit("success", tool, backend, prompt)
            
            # A3 — attach graph context from KùzuDB when available
            graph_context = None
            if _kuzu_store_factory is not None:
                try:
                    store = _kuzu_store_factory()
                    if store.available():
                        ctx = store.get_algos_for_intent(tool)
                        if ctx:
                            graph_context = ctx
                except Exception:
                    pass

            response = {
                "status": "success",
                "backend": backend,
                "routing_reason": routing_reason,
                "result": result,
                "timestamp": timestamp,
            }
            if graph_context is not None:
                response["graphContext"] = graph_context
            return response
            
        except Exception as e:
            self._log_audit("error", tool, backend, prompt, str(e))
            return {
                "status": "error",
                "message": str(e),
                "backend": backend,
                "timestamp": timestamp
            }
    
    async def _call_mcp(self, endpoint: str, tool: str, args: Dict) -> Any:
        request_data = {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/call",
            "params": {"name": tool, "arguments": args}
        }
        
        req = urllib.request.Request(
            endpoint,
            data=json.dumps(request_data).encode(),
            headers={"Content-Type": "application/json"},
            method="POST"
        )
        
        with urllib.request.urlopen(req, timeout=120) as resp:
            return json.loads(resp.read().decode())
    
    def _log_audit(self, status: str, tool: str, backend: str, prompt: str, error: str = None):
        entry = {
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "agent": "aicore-pal-agent",
            "status": status,
            "tool": tool,
            "backend": backend,
            "prompt_hash": hash(prompt),
            "prompt_length": len(prompt)
        }
        if error:
            entry["error"] = error
        self.audit_log.append(entry)
    
    def get_audit_log(self) -> List[Dict]:
        return self.audit_log
    
    async def annotate_pal_output(self, pal_function: str, output_columns: List[Dict]) -> Dict[str, Any]:
        """
        Annotate PAL output columns with Analytics vocabulary.
        
        Uses OData Vocabularies service to suggest appropriate annotations
        for KPIs, dimensions, and measures.
        """
        timestamp = datetime.now(timezone.utc).isoformat()
        annotations = {}
        
        for column in output_columns:
            col_name = column.get("name", "")
            col_type = column.get("type", "DOUBLE")
            
            # Determine annotation type based on column semantics
            if self._is_kpi_column(col_name):
                # Get Analytics.Measure annotation
                annotation = await self.vocab_client.get_measure_annotation(col_name, col_type)
                annotations[col_name] = {
                    "term": "@Analytics.Measure",
                    "value": True,
                    "source": "odata-vocabularies",
                    "details": annotation
                }
            elif self._is_dimension_column(col_name):
                # Get Analytics.Dimension annotation
                annotations[col_name] = {
                    "term": "@Analytics.Dimension",
                    "value": True,
                    "source": "odata-vocabularies"
                }
            else:
                # Ask vocabulary service for suggestions
                suggestion = await self.vocab_client.get_analytics_annotations(
                    f"{pal_function} column: {col_name}"
                )
                annotations[col_name] = {
                    "suggested": True,
                    "source": "odata-vocabularies",
                    "details": suggestion
                }
        
        self._log_audit("annotate_pal_output", pal_function, "odata-vocab", str(output_columns))
        
        return {
            "status": "success",
            "pal_function": pal_function,
            "annotations": annotations,
            "vocabulary": "Analytics",
            "timestamp": timestamp
        }
    
    async def get_kpi_annotation_template(self, kpi_name: str, aggregation: str = "sum") -> Dict[str, Any]:
        """
        Get Analytics vocabulary annotation template for a KPI.
        """
        kpi_def = {
            "name": kpi_name,
            "aggregation": aggregation,
            "type": "measure"
        }
        
        result = await self.vocab_client.annotate_kpi(kpi_def)
        
        return {
            "kpi_name": kpi_name,
            "suggested_annotations": [
                f"@Analytics.Measure: true",
                f"@Aggregation.default: #{aggregation}",
                f"@Common.Label: '{kpi_name}'"
            ],
            "vocabulary_response": result
        }
    
    async def lookup_analytics_term(self, term: str) -> Dict[str, Any]:
        """
        Look up Analytics vocabulary term definition.
        """
        return await self.vocab_client.lookup_analytics_term(term)
    
    def _is_kpi_column(self, col_name: str) -> bool:
        """Check if column is a KPI/measure based on naming patterns."""
        kpi_patterns = ["prediction", "forecast", "score", "probability", 
                       "amount", "total", "sum", "avg", "count", "value"]
        col_lower = col_name.lower()
        return any(p in col_lower for p in kpi_patterns)
    
    def _is_dimension_column(self, col_name: str) -> bool:
        """Check if column is a dimension based on naming patterns."""
        dim_patterns = ["category", "segment", "cluster", "group", 
                       "type", "class", "id", "code", "key"]
        col_lower = col_name.lower()
        return any(p in col_lower for p in dim_patterns)
    
    def check_governance(self, prompt: str) -> Dict[str, Any]:
        prompting = self.mangle.query("get_prompting_policy", "aicore-pal-service-v1")
        autonomy = self.mangle.query("autonomy_level")
        
        return {
            "routing": {
                "backend": "vllm",
                "reason": "HANA PAL data is enterprise confidential - vLLM only"
            },
            "autonomy_level": autonomy[0]["level"] if autonomy else "L2",
            "prompting_policy": prompting[0] if prompting else {},
            "data_product": "aicore-pal-service-v1",
            "external_allowed": False,
            "vocabulary_integration": {
                "service": "odata-vocabularies",
                "endpoint": "http://localhost:9150",
                "vocabularies": ["Analytics", "Common"],
                "features": ["measure_annotation", "dimension_annotation", "kpi_templates"]
            }
        }


def main():
    import asyncio
    
    agent = AICorePALAgent()
    
    print("=" * 60)
    print("AI Core PAL Agent - vLLM Only (HANA Data)")
    print("=" * 60)
    
    # Test 1: Classification (vLLM)
    print("\n--- Test 1: PAL Classification ---")
    governance = agent.check_governance("Classify customers by revenue")
    print(f"Routing: {governance['routing']['backend']}")
    print(f"Reason: {governance['routing']['reason']}")
    print(f"External allowed: {governance['external_allowed']}")
    
    # Test 2: Regression (vLLM)
    print("\n--- Test 2: PAL Regression ---")
    governance = agent.check_governance("Predict sales for Q4")
    print(f"Routing: {governance['routing']['backend']}")
    print(f"Autonomy: {governance['autonomy_level']}")
    
    # Test 3: Forecasting (vLLM)
    print("\n--- Test 3: PAL Forecast ---")
    result = asyncio.run(agent.invoke(
        "Forecast next 12 months of sales",
        {"tool": "pal_forecast"}
    ))
    print(f"Status: {result['status']}")
    print(f"Backend: {result.get('backend', 'N/A')}")
    
    # Test 4: Train model (requires approval)
    print("\n--- Test 4: Train Model ---")
    result = asyncio.run(agent.invoke(
        "Train new classification model",
        {"tool": "pal_train_model"}
    ))
    print(f"Status: {result['status']}")
    print(f"Message: {result.get('message', '')}")
    
    # Test 5: Delete model (requires approval)
    print("\n--- Test 5: Delete Model ---")
    result = asyncio.run(agent.invoke(
        "Delete old regression model",
        {"tool": "pal_delete_model"}
    ))
    print(f"Status: {result['status']}")
    print(f"Message: {result.get('message', '')}")
    
    # Test 6: Vocabulary Integration - Annotate PAL output
    print("\n--- Test 6: Vocabulary Integration - Annotate PAL Output ---")
    pal_output_columns = [
        {"name": "prediction_score", "type": "DOUBLE"},
        {"name": "customer_segment", "type": "NVARCHAR"},
        {"name": "forecast_value", "type": "DECIMAL"},
        {"name": "cluster_id", "type": "INTEGER"}
    ]
    result = asyncio.run(agent.annotate_pal_output("PAL_CLASSIFICATION", pal_output_columns))
    print(f"Status: {result['status']}")
    print(f"Vocabulary: {result['vocabulary']}")
    for col, ann in result.get('annotations', {}).items():
        print(f"  {col}: {ann.get('term', ann.get('suggested', 'unknown'))}")
    
    # Test 7: KPI Annotation Template
    print("\n--- Test 7: KPI Annotation Template ---")
    result = asyncio.run(agent.get_kpi_annotation_template("sales_forecast", "sum"))
    print(f"KPI: {result['kpi_name']}")
    print("Suggested annotations:")
    for ann in result.get('suggested_annotations', []):
        print(f"  {ann}")
    
    # Test 8: Lookup Analytics Term
    print("\n--- Test 8: Lookup Analytics Term ---")
    result = asyncio.run(agent.lookup_analytics_term("Measure"))
    print(f"Term lookup result: {result.get('status', 'N/A')}")
    
    # Test 9: Audit log
    # Test 9: Audit log
    print("\n--- Audit Log ---")
    for entry in agent.get_audit_log():
        print(f"  [{entry['timestamp']}] {entry['status']} - {entry['tool']} via {entry['backend']}")


if __name__ == "__main__":
    main()