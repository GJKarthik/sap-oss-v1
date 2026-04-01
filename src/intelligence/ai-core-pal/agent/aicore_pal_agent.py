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

# BTP integration modules — ensure agent/ directory is on sys.path
_agent_dir = _os.path.dirname(_os.path.abspath(__file__))
if _agent_dir not in _sys.path:
    _sys.path.insert(0, _agent_dir)

_btp_server_client = None
try:
    import btp_server_client as _btp_server_client_mod  # type: ignore[import]
    _btp_server_client = _btp_server_client_mod
except ImportError:
    pass

_hana_client = None
try:
    import hana_client as _hana_client_mod  # type: ignore[import]
    _hana_client = _hana_client_mod
except ImportError:
    pass

_btp_kuzu_seeder = None
try:
    import btp_kuzu_seeder as _btp_kuzu_seeder_mod  # type: ignore[import]
    _btp_kuzu_seeder = _btp_kuzu_seeder_mod
except ImportError:
    pass


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
            "kuzu_index", "kuzu_query",
            # BTP schema integration tools
            "btp_registry_query", "btp_registry_query_domain", "btp_search",
            "search_schema_registry", "list_domains", "hana_tables",
            "kuzu_seed_btp",
            # Direct PAL calls via hdbcli (synthetic data)
            "pal_arima", "pal_anomaly_detection",
            # PAL calls from BTP tables with aggregation and multi-dimension support
            "pal_arima_from_table", "pal_anomaly_from_table",
            # Analytics metadata discovery
            "get_forecastable_columns", "get_dimension_columns", "get_date_columns",
            # Hierarchical reconciliation (future)
            "reconcile_hierarchical_forecasts",
        }
        
        self.facts["agent_requires_approval"] = {
            "pal_train_model", "pal_delete_model", "hana_write",
            "btp_apply_schema",  # DDL bootstrap requires human review
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

    async def handle_btp_registry_query(self, args: Dict[str, Any]) -> Dict[str, Any]:
        """Query BTP.SCHEMA_REGISTRY via the server REST API (primary) or HANA direct."""
        domain = args.get("domain")
        source_table = args.get("source_table")
        wide_table = args.get("wide_table")
        limit = int(args.get("limit", 200))
        offset = int(args.get("offset", 0))

        # Try server API first
        if _btp_server_client is not None:
            result = _btp_server_client.registry_query(
                domain=domain,
                source_table=source_table,
                wide_table=wide_table,
                limit=limit,
                offset=offset,
            )
            if "error" not in result:
                return result

        # Fall back to direct HANA
        if _hana_client is not None and _hana_client.is_available():
            rows = _hana_client.query_schema_registry(
                domain=domain,
                source_table=source_table,
                wide_table=wide_table,
                limit=limit,
                offset=offset,
            )
            return {"fields": rows, "total": len(rows), "source": "hana_direct"}

        return {"error": "BTP server and HANA direct both unavailable", "fields": [], "total": 0}

    async def handle_btp_search(self, args: Dict[str, Any]) -> Dict[str, Any]:
        """Fan-out BTP search to ES + HANA via the server REST API."""
        query = str(args.get("query", "")).strip()
        if not query:
            return {"error": "query is required"}
        domain = args.get("domain")
        wide_table = args.get("wide_table")
        limit = int(args.get("limit", 50))

        if _btp_server_client is not None:
            result = _btp_server_client.search(
                query=query, domain=domain, wide_table=wide_table, limit=limit
            )
            if "error" not in result:
                return result

        # Fall back to HANA direct text search
        if _hana_client is not None and _hana_client.is_available():
            rows = _hana_client.search_schema_registry(
                query, domain=domain, wide_table=wide_table, limit=limit
            )
            return {"hana": rows, "es": [], "query": query, "source": "hana_direct"}

        return {"error": "BTP server and HANA direct both unavailable", "hana": [], "es": [], "query": query}

    async def handle_kuzu_seed_btp(self, args: Dict[str, Any]) -> Dict[str, Any]:
        """Seed BTP schema data into KùzuDB for graph-RAG context."""
        if _btp_kuzu_seeder is None:
            return {"error": "btp_kuzu_seeder module not available"}
        verbose = bool(args.get("verbose", False))
        return _btp_kuzu_seeder.seed_btp_into_kuzu(verbose=verbose)

    async def handle_pal_arima(self, args: Dict[str, Any]) -> Dict[str, Any]:
        """Call real PAL ARIMA on HANA Cloud via hdbcli."""
        if _hana_client is None or not _hana_client.is_available():
            return {"error": "HANA not available (set HANA_HOST, HANA_USER, HANA_PASSWORD)"}
        input_data = args.get("input_data", [])
        if isinstance(input_data, str):
            import json as _json
            try:
                input_data = _json.loads(input_data)
            except Exception:
                input_data = []
        horizon = int(args.get("horizon", 12))
        return _hana_client.call_pal_arima(input_data, horizon=horizon)

    async def handle_pal_anomaly_detection(self, args: Dict[str, Any]) -> Dict[str, Any]:
        """Call real PAL AnomalyDetection on HANA Cloud via hdbcli."""
        if _hana_client is None or not _hana_client.is_available():
            return {"error": "HANA not available (set HANA_HOST, HANA_USER, HANA_PASSWORD)"}
        input_data = args.get("input_data", [])
        if isinstance(input_data, str):
            import json as _json
            try:
                input_data = _json.loads(input_data)
            except Exception:
                input_data = []
        return _hana_client.call_pal_anomaly_detection(input_data)

    # =========================================================================
    # NEW: Table-based PAL tools with dynamic table discovery
    # =========================================================================

    async def handle_pal_arima_from_table(self, args: Dict[str, Any]) -> Dict[str, Any]:
        """
        Run PAL time series forecasting directly on a BTP table.
        
        Required args:
            table_name: Full table name e.g. "BTP.FACT"
            value_column: Numeric column to forecast e.g. "AMOUNT_USD"
        Optional args:
            order_by_column: Date column for ordering e.g. "PERIOD_DATE"
            where_clause: SQL filter e.g. "DOMAIN = 'GLA'"
            horizon: Forecast periods (default 12)
            limit: Max rows (default 1000)
        """
        if _hana_client is None or not _hana_client.is_available():
            return {"error": "HANA not available (set HANA_HOST, HANA_USER, HANA_PASSWORD)"}
        
        table_name = args.get("table_name")
        value_column = args.get("value_column")
        
        if not table_name or not value_column:
            return {"error": "table_name and value_column are required"}
        
        return _hana_client.call_pal_arima_from_table(
            table_name=table_name,
            value_column=value_column,
            order_by_column=args.get("order_by_column"),
            where_clause=args.get("where_clause"),
            horizon=int(args.get("horizon", 12)),
            limit=int(args.get("limit", 1000)),
        )

    async def handle_pal_anomaly_from_table(self, args: Dict[str, Any]) -> Dict[str, Any]:
        """
        Run PAL anomaly detection directly on a BTP table.
        
        Required args:
            table_name: Full table name e.g. "BTP.ESG_METRIC"
            value_column: Numeric column to analyze e.g. "FINANCED_EMISSION"
        Optional args:
            id_column: ID column to preserve row identity e.g. "ESG_ID"
            where_clause: SQL filter
            limit: Max rows (default 1000)
        """
        if _hana_client is None or not _hana_client.is_available():
            return {"error": "HANA not available (set HANA_HOST, HANA_USER, HANA_PASSWORD)"}
        
        table_name = args.get("table_name")
        value_column = args.get("value_column")
        
        if not table_name or not value_column:
            return {"error": "table_name and value_column are required"}
        
        return _hana_client.call_pal_anomaly_from_table(
            table_name=table_name,
            value_column=value_column,
            id_column=args.get("id_column"),
            where_clause=args.get("where_clause"),
            limit=int(args.get("limit", 1000)),
        )

    async def handle_hana_tables(self, args: Dict[str, Any]) -> Dict[str, Any]:
        """
        Discover HANA tables with numeric columns suitable for PAL analytics.
        Returns table names with column metadata for time series and anomaly detection.
        """
        if _hana_client is None or not _hana_client.is_available():
            return {"error": "HANA not available (set HANA_HOST, HANA_USER, HANA_PASSWORD)"}
        
        schema = args.get("schema", "BTP")
        include_columns = args.get("include_columns", True)
        
        try:
            from hdbcli import dbapi
            conn = dbapi.connect(
                address=_os.environ.get('HANA_HOST'),
                port=int(_os.environ.get('HANA_PORT', 443)),
                user=_os.environ.get('HANA_USER'),
                password=_os.environ.get('HANA_PASSWORD'),
                encrypt=True,
                sslValidateCertificate=False
            )
            cursor = conn.cursor()
            
            # Get tables in schema
            cursor.execute("""
                SELECT TABLE_NAME FROM TABLES 
                WHERE SCHEMA_NAME = ?
                AND TABLE_TYPE = 'COLUMN'
                ORDER BY TABLE_NAME
            """, (schema,))
            tables = []
            
            for (table_name,) in cursor.fetchall():
                table_info = {
                    "schema": schema,
                    "table": table_name,
                    "full_name": f"{schema}.{table_name}"
                }
                
                if include_columns:
                    # Get numeric columns for PAL
                    cursor.execute("""
                        SELECT COLUMN_NAME, DATA_TYPE_NAME
                        FROM TABLE_COLUMNS
                        WHERE SCHEMA_NAME = ?
                        AND TABLE_NAME = ?
                        AND DATA_TYPE_NAME IN ('INTEGER', 'BIGINT', 'DECIMAL', 'DOUBLE', 'REAL', 'FLOAT', 'SMALLINT', 'TINYINT')
                        ORDER BY POSITION
                    """, (schema, table_name))
                    numeric_cols = [{"name": r[0], "type": r[1]} for r in cursor.fetchall()]
                    
                    # Get date/time columns for ordering
                    cursor.execute("""
                        SELECT COLUMN_NAME, DATA_TYPE_NAME
                        FROM TABLE_COLUMNS
                        WHERE SCHEMA_NAME = ?
                        AND TABLE_NAME = ?
                        AND DATA_TYPE_NAME IN ('DATE', 'TIMESTAMP', 'SECONDDATE')
                        ORDER BY POSITION
                    """, (schema, table_name))
                    date_cols = [{"name": r[0], "type": r[1]} for r in cursor.fetchall()]
                    
                    # Get row count — schema/table names are DB metadata identifiers; validate strictly
                    import re as _re
                    if not _re.match(r'^[A-Za-z0-9_]+$', schema) or not _re.match(r'^[A-Za-z0-9_]+$', table_name):
                        raise ValueError(f"Invalid identifier: {schema!r}.{table_name!r}")
                    cursor.execute(f'SELECT COUNT(*) FROM "{schema}"."{table_name}"')
                    row_count = cursor.fetchone()[0]
                    
                    table_info["numeric_columns"] = numeric_cols
                    table_info["date_columns"] = date_cols
                    table_info["row_count"] = row_count
                    table_info["pal_suitable"] = len(numeric_cols) > 0 and row_count >= 4
                
                tables.append(table_info)
            
            conn.close()
            
            # Filter to only PAL-suitable tables if columns were included
            pal_tables = [t for t in tables if t.get("pal_suitable", True)] if include_columns else tables
            
            return {
                "schema": schema,
                "total_tables": len(tables),
                "pal_suitable_tables": len(pal_tables),
                "tables": pal_tables,
            }
        except Exception as e:
            return {"error": str(e)}

    async def handle_list_domains(self, args: Dict[str, Any]) -> Dict[str, Any]:
        """List available domains from SCHEMA_REGISTRY."""
        if _hana_client is None or not _hana_client.is_available():
            return {"error": "HANA not available"}
        
        try:
            domains = _hana_client.list_domains()
            return {"domains": domains, "count": len(domains)}
        except Exception as e:
            return {"error": str(e)}

    # =========================================================================
    # ANALYTICS METADATA DISCOVERY (from SCHEMA_REGISTRY enhancements)
    # =========================================================================

    async def handle_get_forecastable_columns(self, args: Dict[str, Any]) -> Dict[str, Any]:
        """
        Get columns marked as forecastable from SCHEMA_REGISTRY.
        Requires schema_registry_analytics.sql to have been run first.
        
        Args:
            wide_table: Optional table filter
            domain: Optional domain filter
        """
        if _hana_client is None or not _hana_client.is_available():
            return {"error": "HANA not available"}
        
        try:
            columns = _hana_client.get_forecastable_columns(
                wide_table=args.get("wide_table"),
                domain=args.get("domain")
            )
            return {
                "columns": columns,
                "count": len(columns),
                "description": "Columns suitable for PAL time series forecasting"
            }
        except Exception as e:
            return {"error": str(e)}

    async def handle_get_dimension_columns(self, args: Dict[str, Any]) -> Dict[str, Any]:
        """
        Get columns marked as dimensions from SCHEMA_REGISTRY.
        
        Args:
            wide_table: Optional table filter
            domain: Optional domain filter
        """
        if _hana_client is None or not _hana_client.is_available():
            return {"error": "HANA not available"}
        
        try:
            columns = _hana_client.get_dimension_columns(
                wide_table=args.get("wide_table"),
                domain=args.get("domain")
            )
            return {
                "columns": columns,
                "count": len(columns),
                "description": "Columns suitable for GROUP BY / multi-dimension iteration"
            }
        except Exception as e:
            return {"error": str(e)}

    async def handle_get_date_columns(self, args: Dict[str, Any]) -> Dict[str, Any]:
        """
        Get columns marked as date/time from SCHEMA_REGISTRY.
        
        Args:
            wide_table: Optional table filter
            domain: Optional domain filter
        """
        if _hana_client is None or not _hana_client.is_available():
            return {"error": "HANA not available"}
        
        try:
            columns = _hana_client.get_date_columns(
                wide_table=args.get("wide_table"),
                domain=args.get("domain")
            )
            return {
                "columns": columns,
                "count": len(columns),
                "description": "Date/time columns for time series ordering"
            }
        except Exception as e:
            return {"error": str(e)}

    async def handle_reconcile_hierarchical_forecasts(self, args: Dict[str, Any]) -> Dict[str, Any]:
        """
        Hierarchical forecast reconciliation (placeholder for future implementation).
        
        Ensures consistency between forecasts at different aggregation levels
        (e.g., Total Company → Region → Client).
        
        Args:
            parent_forecast: Forecast for aggregate level
            child_forecasts: List of forecasts for disaggregated level
            method: Reconciliation method (top_down, bottom_up, middle_out, optimal)
        """
        if _hana_client is None:
            return {"error": "HANA not available"}
        
        return _hana_client.reconcile_hierarchical_forecasts(
            parent_forecast=args.get("parent_forecast", {}),
            child_forecasts=args.get("child_forecasts", []),
            method=args.get("method", "top_down")
        )

    # =========================================================================
    # ORCHESTRATION: Natural Language → Discovery → PAL Execution
    # =========================================================================

    async def analyze_pal_request(self, prompt: str) -> Dict[str, Any]:
        """
        Multi-step orchestration:
        1. Parse natural language to identify intent (forecast, anomaly)
        2. Query SCHEMA_REGISTRY to discover relevant tables/columns
        3. Execute PAL on discovered table
        4. Return combined result with provenance
        """
        timestamp = datetime.now(timezone.utc).isoformat()
        steps = []
        
        # Step 1: Parse intent from prompt
        intent = self._parse_pal_intent(prompt)
        steps.append({
            "step": 1,
            "action": "parse_intent",
            "result": intent
        })
        
        if not intent.get("action"):
            return {
                "status": "error",
                "error": "Could not determine PAL action from prompt",
                "steps": steps,
                "timestamp": timestamp
            }
        
        # Step 2: Discover table and column from registry
        discovery = await self._discover_table_for_intent(intent)
        steps.append({
            "step": 2,
            "action": "discover_table",
            "result": discovery
        })
        
        if not discovery.get("table_name") or not discovery.get("value_column"):
            return {
                "status": "error",
                "error": "Could not find suitable table/column for the request",
                "intent": intent,
                "steps": steps,
                "timestamp": timestamp
            }
        
        # Step 3: Execute PAL based on intent
        if intent["action"] == "forecast":
            pal_result = await self.handle_pal_arima_from_table({
                "table_name": discovery["table_name"],
                "value_column": discovery["value_column"],
                "order_by_column": discovery.get("order_by_column"),
                "where_clause": intent.get("filter"),
                "horizon": intent.get("horizon", 12),
            })
        elif intent["action"] == "anomaly":
            pal_result = await self.handle_pal_anomaly_from_table({
                "table_name": discovery["table_name"],
                "value_column": discovery["value_column"],
                "id_column": discovery.get("id_column"),
                "where_clause": intent.get("filter"),
            })
        else:
            return {
                "status": "error",
                "error": f"Unknown PAL action: {intent['action']}",
                "steps": steps,
                "timestamp": timestamp
            }
        
        steps.append({
            "step": 3,
            "action": f"execute_{intent['action']}",
            "result": "success" if pal_result.get("status") == "success" else "error"
        })
        
        self._log_audit("analyze_pal_request", intent["action"], "hana_direct", prompt)
        
        return {
            "status": pal_result.get("status", "success"),
            "intent": intent,
            "discovery": discovery,
            "pal_result": pal_result,
            "steps": steps,
            "timestamp": timestamp
        }

    def _parse_pal_intent(self, prompt: str) -> Dict[str, Any]:
        """
        Parse natural language prompt to extract:
        - action: forecast, anomaly, classify, cluster
        - domain_hint: ESG, Treasury, Finance, etc.
        - column_hint: emission, amount, revenue, etc.
        - filter: optional SQL-like filter
        - horizon: for forecasting
        """
        prompt_lower = prompt.lower()
        
        # Determine action
        action = None
        if any(w in prompt_lower for w in ["forecast", "predict", "time series", "arima", "future"]):
            action = "forecast"
        elif any(w in prompt_lower for w in ["anomaly", "outlier", "unusual", "detect", "abnormal"]):
            action = "anomaly"
        elif any(w in prompt_lower for w in ["classify", "classification", "categorize"]):
            action = "classify"
        elif any(w in prompt_lower for w in ["cluster", "segment", "group"]):
            action = "cluster"
        
        # Extract domain hint
        domain_hint = None
        domain_keywords = {
            "ESG": ["esg", "emission", "carbon", "sustainability", "green", "environmental"],
            "GLA": ["gla", "ledger", "accounting", "financial", "balance"],
            "TREASURY": ["treasury", "position", "liquidity", "cash", "fx"],
            "TRADE": ["trade", "transaction", "payment"],
        }
        for domain, keywords in domain_keywords.items():
            if any(k in prompt_lower for k in keywords):
                domain_hint = domain
                break
        
        # Extract column hint
        column_hint = None
        column_keywords = {
            "AMOUNT_USD": ["amount", "value", "usd", "dollars", "money"],
            "FINANCED_EMISSION": ["emission", "carbon", "co2", "financed"],
            "REVENUE": ["revenue", "sales", "income"],
            "MARKET_VALUE": ["market", "value", "price"],
        }
        for column, keywords in column_keywords.items():
            if any(k in prompt_lower for k in keywords):
                column_hint = column
                break
        
        # Extract horizon for forecasting
        horizon = 12  # default
        import re
        horizon_match = re.search(r'(\d+)\s*(month|period|point|step)', prompt_lower)
        if horizon_match:
            horizon = int(horizon_match.group(1))
        
        return {
            "action": action,
            "domain_hint": domain_hint,
            "column_hint": column_hint,
            "horizon": horizon,
            "original_prompt": prompt
        }

    async def _discover_table_for_intent(self, intent: Dict[str, Any]) -> Dict[str, Any]:
        """
        Query SCHEMA_REGISTRY and HANA metadata to find the best table/column
        for the given intent.
        """
        domain_hint = intent.get("domain_hint")
        column_hint = intent.get("column_hint")
        
        # Table mapping based on domain
        domain_table_map = {
            "ESG": {"table": "BTP.ESG_METRIC", "value_col": "FINANCED_EMISSION", "id_col": "ESG_ID", "date_col": "PERIOD_DATE"},
            "GLA": {"table": "BTP.FACT", "value_col": "AMOUNT_USD", "id_col": None, "date_col": "PERIOD_DATE"},
            "TREASURY": {"table": "BTP.TREASURY_POSITION", "value_col": "AMOUNT_USD", "id_col": "POSITION_ID", "date_col": "REPORTING_DATE"},
            "TRADE": {"table": "BTP.FACT", "value_col": "AMOUNT_USD", "id_col": None, "date_col": "PERIOD_DATE"},
        }
        
        # First try domain-based mapping
        if domain_hint and domain_hint in domain_table_map:
            mapping = domain_table_map[domain_hint]
            return {
                "table_name": mapping["table"],
                "value_column": column_hint or mapping["value_col"],
                "id_column": mapping["id_col"],
                "order_by_column": mapping["date_col"],
                "discovery_method": "domain_mapping",
                "domain": domain_hint,
            }
        
        # Fall back to SCHEMA_REGISTRY search
        if column_hint:
            registry_result = await self.handle_btp_search({"query": column_hint, "limit": 5})
            if registry_result.get("hana"):
                first_match = registry_result["hana"][0]
                return {
                    "table_name": f"BTP.{first_match.get('source_table', first_match.get('wide_table', 'FACT'))}",
                    "value_column": first_match.get("field_name", column_hint),
                    "id_column": None,
                    "order_by_column": None,
                    "discovery_method": "registry_search",
                    "registry_match": first_match,
                }
        
        # Default fallback to BTP.FACT
        return {
            "table_name": "BTP.FACT",
            "value_column": column_hint or "AMOUNT_USD",
            "id_column": None,
            "order_by_column": "PERIOD_DATE",
            "discovery_method": "default_fallback",
        }

    async def invoke(self, prompt: str, context: Optional[Dict] = None) -> Dict[str, Any]:
        context = context or {}
        tool = context.get("tool", "pal_classification")
        timestamp = datetime.now(timezone.utc).isoformat()

        # Dispatch graph-RAG tools directly
        if tool == "kuzu_index":
            return await self.handle_kuzu_index(context.get("args", {}))
        if tool == "kuzu_query":
            return await self.handle_kuzu_query(context.get("args", {}))

        # Dispatch BTP schema tools directly (no vLLM needed)
        if tool == "btp_registry_query":
            return await self.handle_btp_registry_query(context.get("args", {}))
        if tool == "btp_search":
            return await self.handle_btp_search(context.get("args", {}))
        if tool == "kuzu_seed_btp":
            return await self.handle_kuzu_seed_btp(context.get("args", {}))

        # Dispatch real PAL calls directly (hdbcli, no LLM)
        if tool == "pal_arima":
            return await self.handle_pal_arima(context.get("args", {}))
        if tool == "pal_anomaly_detection":
            return await self.handle_pal_anomaly_detection(context.get("args", {}))
        
        # Dispatch table-based PAL tools with aggregation support
        if tool == "pal_arima_from_table":
            return await self.handle_pal_arima_from_table(context.get("args", {}))
        if tool == "pal_anomaly_from_table":
            return await self.handle_pal_anomaly_from_table(context.get("args", {}))
        if tool == "hana_tables":
            return await self.handle_hana_tables(context.get("args", {}))
        if tool == "list_domains":
            return await self.handle_list_domains(context.get("args", {}))
        
        # Dispatch analytics metadata discovery tools
        if tool == "get_forecastable_columns":
            return await self.handle_get_forecastable_columns(context.get("args", {}))
        if tool == "get_dimension_columns":
            return await self.handle_get_dimension_columns(context.get("args", {}))
        if tool == "get_date_columns":
            return await self.handle_get_date_columns(context.get("args", {}))
        
        # Hierarchical reconciliation (placeholder)
        if tool == "reconcile_hierarchical_forecasts":
            return await self.handle_reconcile_hierarchical_forecasts(context.get("args", {}))

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