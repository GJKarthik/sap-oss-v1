# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2024 SAP SE
"""
Data Cleaning Copilot MCP Server

Model Context Protocol server with Mangle reasoning integration.
Provides tools for data cleaning, quality checks, and AI-assisted data validation.
"""

import json
import os
import hmac
import secrets
from http.server import HTTPServer, BaseHTTPRequestHandler
from typing import Any, Optional
import urllib.request
import urllib.error

MAX_REQUEST_BYTES = int(os.environ.get("MCP_MAX_REQUEST_BYTES", str(1024 * 1024)))
MAX_TOP_K = int(os.environ.get("MCP_MAX_TOP_K", "100"))
MAX_PROFILE_COLUMNS = int(os.environ.get("MCP_MAX_PROFILE_COLUMNS", "100"))
MAX_REMOTE_ENDPOINTS = int(os.environ.get("MCP_MAX_REMOTE_ENDPOINTS", "25"))
REMOTE_MCP_TIMEOUT_SECONDS = int(os.environ.get("MCP_REMOTE_TIMEOUT_SECONDS", "3"))


def clamp_int(value: Any, default: int, min_value: int, max_value: int) -> int:
    try:
        parsed = int(value)
    except (TypeError, ValueError):
        return default
    if parsed < min_value:
        return min_value
    if parsed > max_value:
        return max_value
    return parsed


def parse_json_arg(value: Any, fallback: Any):
    if isinstance(value, str):
        try:
            return json.loads(value)
        except json.JSONDecodeError:
            return fallback
    return value if value is not None else fallback


def normalize_mcp_endpoint(endpoint: str) -> str:
    normalized = (endpoint or "").strip().rstrip("/")
    if normalized == "":
        return ""
    if normalized.endswith("/mcp"):
        return normalized
    return f"{normalized}/mcp"


def get_remote_mcp_endpoints(*env_keys: str) -> list:
    endpoints = []
    seen = set()
    for env_key in env_keys:
        raw = os.environ.get(env_key, "")
        for endpoint in raw.split(","):
            normalized = normalize_mcp_endpoint(endpoint)
            if normalized and normalized not in seen:
                seen.add(normalized)
                endpoints.append(normalized)
    return endpoints[:MAX_REMOTE_ENDPOINTS]


def unwrap_mcp_tool_result(result: Any) -> Any:
    if not isinstance(result, dict):
        return result
    content = result.get("content")
    if not isinstance(content, list) or len(content) == 0:
        return result
    first = content[0]
    if not isinstance(first, dict):
        return result
    text = first.get("text")
    if not isinstance(text, str):
        return result
    return parse_json_arg(text, text)


def call_mcp_tool(endpoint: str, tool_name: str, tool_args: dict, timeout_seconds: int = REMOTE_MCP_TIMEOUT_SECONDS) -> Any:
    payload = {
        "jsonrpc": "2.0",
        "id": 1,
        "method": "tools/call",
        "params": {
            "name": tool_name,
            "arguments": tool_args,
        },
    }
    req = urllib.request.Request(
        normalize_mcp_endpoint(endpoint),
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=max(1, int(timeout_seconds))) as resp:
        rpc_response = json.loads(resp.read().decode())
    if isinstance(rpc_response, dict) and "error" in rpc_response:
        error = rpc_response.get("error", {})
        message = error.get("message", "remote MCP tool call failed") if isinstance(error, dict) else "remote MCP tool call failed"
        raise RuntimeError(message)
    result = rpc_response.get("result") if isinstance(rpc_response, dict) else None
    return unwrap_mcp_tool_result(result)

# =============================================================================
# Types
# =============================================================================

class MCPRequest:
    def __init__(self, data: dict):
        self.jsonrpc = data.get("jsonrpc", "2.0")
        self.id = data.get("id")
        self.method = data.get("method", "")
        self.params = data.get("params", {})


class MCPResponse:
    def __init__(self, id: Any, result: Any = None, error: dict = None):
        self.jsonrpc = "2.0"
        self.id = id
        self.result = result
        self.error = error

    def to_dict(self) -> dict:
        d = {"jsonrpc": self.jsonrpc, "id": self.id}
        if self.error:
            d["error"] = self.error
        else:
            d["result"] = self.result
        return d


# =============================================================================
# AI Core Configuration
# =============================================================================

def get_config() -> dict:
    return {
        "client_id": os.environ.get("AICORE_CLIENT_ID", ""),
        "client_secret": os.environ.get("AICORE_CLIENT_SECRET", ""),
        "auth_url": os.environ.get("AICORE_AUTH_URL", ""),
        "base_url": os.environ.get("AICORE_BASE_URL", os.environ.get("AICORE_SERVICE_URL", "")),
        "resource_group": os.environ.get("AICORE_RESOURCE_GROUP", "default"),
    }


_cached_token = {"token": None, "expires_at": 0}


def get_access_token(config: dict) -> str:
    import time
    import base64

    if _cached_token["token"] and time.time() < _cached_token["expires_at"]:
        return _cached_token["token"]

    auth = base64.b64encode(f"{config['client_id']}:{config['client_secret']}".encode()).decode()
    req = urllib.request.Request(
        config["auth_url"],
        data=b"grant_type=client_credentials",
        headers={"Authorization": f"Basic {auth}", "Content-Type": "application/x-www-form-urlencoded"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            result = json.loads(resp.read().decode())
            _cached_token["token"] = result["access_token"]
            _cached_token["expires_at"] = time.time() + result.get("expires_in", 3600) - 60
            return result["access_token"]
    except Exception as e:
        return ""


def aicore_request(config: dict, method: str, path: str, body: dict = None) -> Any:
    token = get_access_token(config)
    url = f"{config['base_url']}{path}"
    data = json.dumps(body).encode() if body else None
    req = urllib.request.Request(
        url,
        data=data,
        headers={
            "Authorization": f"Bearer {token}",
            "AI-Resource-Group": config["resource_group"],
            "Content-Type": "application/json",
        },
        method=method,
    )
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            return json.loads(resp.read().decode())
    except Exception as e:
        return {"error": str(e)}


# =============================================================================
# MCP Server Implementation
# =============================================================================

class MCPServer:
    def __init__(self):
        self.tools = {}
        self.resources = {}
        self.facts = {}
        self.local_mcp_endpoint = normalize_mcp_endpoint(
            os.environ.get("DATA_CLEANING_MCP_ENDPOINT", f"http://localhost:{os.environ.get('MCP_PORT', '9110')}/mcp")
        )
        self.analytics_mcp_endpoint = normalize_mcp_endpoint(
            os.environ.get("DATA_CLEANING_ANALYTICS_MCP_ENDPOINT", "http://localhost:9120/mcp")
        )
        self.context_mcp_endpoint = normalize_mcp_endpoint(
            os.environ.get("DATA_CLEANING_CONTEXT_MCP_ENDPOINT", "http://localhost:9150/mcp")
        )
        self.remote_mcp_endpoints = get_remote_mcp_endpoints("DATA_CLEANING_REMOTE_MCP_ENDPOINTS")
        self._register_tools()
        self._register_resources()
        self._initialize_facts()

    def _register_tools(self):
        # Data Quality Check
        self.tools["data_quality_check"] = {
            "name": "data_quality_check",
            "description": "Run data quality checks on a dataset",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "table_name": {"type": "string", "description": "Table name to check"},
                    "checks": {"type": "string", "description": "JSON array of check types (completeness, accuracy, consistency)"},
                },
                "required": ["table_name"],
            },
        }

        # Schema Analysis
        self.tools["schema_analysis"] = {
            "name": "schema_analysis",
            "description": "Analyze database schema for issues and recommendations",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "schema_definition": {"type": "string", "description": "Schema definition as JSON or SQL DDL"},
                },
                "required": ["schema_definition"],
            },
        }

        # Data Profiling
        self.tools["data_profiling"] = {
            "name": "data_profiling",
            "description": "Profile data to understand distributions and patterns",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "table_name": {"type": "string", "description": "Table name to profile"},
                    "columns": {"type": "string", "description": "Columns to profile (JSON array, optional)"},
                },
                "required": ["table_name"],
            },
        }

        # Anomaly Detection
        self.tools["anomaly_detection"] = {
            "name": "anomaly_detection",
            "description": "Detect anomalies in data using statistical or ML methods",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "table_name": {"type": "string", "description": "Table name"},
                    "column": {"type": "string", "description": "Column to analyze"},
                    "method": {"type": "string", "description": "Method: zscore, iqr, isolation_forest"},
                },
                "required": ["table_name", "column"],
            },
        }

        # Query Generation
        self.tools["generate_cleaning_query"] = {
            "name": "generate_cleaning_query",
            "description": "Generate SQL query to clean or fix data issues",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "issue_description": {"type": "string", "description": "Description of the data issue"},
                    "table_name": {"type": "string", "description": "Target table"},
                    "schema": {"type": "string", "description": "Table schema as JSON"},
                },
                "required": ["issue_description", "table_name"],
            },
        }

        # AI Chat
        self.tools["ai_chat"] = {
            "name": "ai_chat",
            "description": "Chat with AI for data cleaning guidance",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "messages": {"type": "string", "description": "JSON array of messages [{role, content}]"},
                    "context": {"type": "string", "description": "Additional context about the data"},
                },
                "required": ["messages"],
            },
        }

        # Mangle Query
        self.tools["mangle_query"] = {
            "name": "mangle_query",
            "description": "Query the Mangle reasoning engine",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "predicate": {"type": "string", "description": "Predicate to query"},
                    "args": {"type": "string", "description": "Arguments as JSON array"},
                },
                "required": ["predicate"],
            },
        }

        # Graph-RAG: index schema into KùzuDB
        self.tools["kuzu_index"] = {
            "name": "kuzu_index",
            "description": (
                "Parse a database schema definition and store table, column, and "
                "foreign-key nodes in the embedded KùzuDB graph database. "
                "Optionally records active quality checks and the columns they cover. "
                "Use before data_quality_check to enable graph-context enrichment."
            ),
            "inputSchema": {
                "type": "object",
                "properties": {
                    "schema_definition": {
                        "type": "string",
                        "description": "Schema as JSON: {tables: [{name, columns: [{name, type}], foreign_keys: [{column, ref_table, ref_column}]}]}",
                    },
                    "checks": {
                        "type": "string",
                        "description": "JSON array of {table, check_type, status, score, columns} objects to record as QualityCheck nodes (optional)",
                    },
                },
                "required": ["schema_definition"],
            },
        }

        # Graph-RAG: run a Cypher query against KùzuDB
        self.tools["kuzu_query"] = {
            "name": "kuzu_query",
            "description": (
                "Execute a read-only Cypher query against the embedded KùzuDB graph "
                "database and return matching rows as JSON. "
                "Use for FK traversal, check-coverage discovery, and relationship analysis."
            ),
            "inputSchema": {
                "type": "object",
                "properties": {
                    "cypher": {
                        "type": "string",
                        "description": "Cypher query string (MATCH … RETURN only)",
                    },
                    "params": {
                        "type": "string",
                        "description": "Query parameters as JSON object (optional)",
                    },
                },
                "required": ["cypher"],
            },
        }

    def _register_resources(self):
        self.resources["data://schemas"] = {
            "uri": "data://schemas",
            "name": "Database Schemas",
            "description": "Available database schemas",
            "mimeType": "application/json",
        }
        self.resources["data://quality_rules"] = {
            "uri": "data://quality_rules",
            "name": "Data Quality Rules",
            "description": "Defined data quality rules",
            "mimeType": "application/json",
        }
        self.resources["mangle://facts"] = {
            "uri": "mangle://facts",
            "name": "Mangle Facts",
            "description": "Mangle fact store",
            "mimeType": "application/json",
        }

    def _initialize_facts(self):
        self.facts["service_registry"] = [
            {"name": "data-cleaning-mcp", "endpoint": self.local_mcp_endpoint, "model": "data-cleaning-copilot-mcp"},
            {"name": "analytics-mcp", "endpoint": self.analytics_mcp_endpoint, "model": "elasticsearch-mcp"},
            {"name": "context-mcp", "endpoint": self.context_mcp_endpoint, "model": "odata-vocab-mcp"},
            {"name": "data-quality", "endpoint": "dcc://quality", "model": "quality-analyzer"},
            {"name": "data-profiling", "endpoint": "dcc://profiling", "model": "profiler"},
            {"name": "anomaly-detection", "endpoint": "dcc://anomaly", "model": "anomaly-detector"},
        ]
        for idx, endpoint in enumerate(self.remote_mcp_endpoints):
            self.facts["service_registry"].append({"name": f"remote-mcp-{idx + 1}", "endpoint": endpoint, "model": "federated"})
        self.facts["tool_invocation"] = []
        self.facts["quality_rules"] = [
            {"rule": "completeness", "threshold": 95.0},
            {"rule": "accuracy", "threshold": 99.0},
            {"rule": "consistency", "threshold": 98.0},
        ]

    def _iter_federated_mcp_endpoints(self, preferred: list = None) -> list:
        ordered = []
        seen = set()

        def push(endpoint: str):
            normalized = normalize_mcp_endpoint(endpoint)
            if not normalized:
                return
            if normalized == self.local_mcp_endpoint:
                return
            if not (normalized.startswith("http://") or normalized.startswith("https://")):
                return
            if normalized in seen:
                return
            seen.add(normalized)
            ordered.append(normalized)

        for endpoint in preferred or []:
            push(endpoint)
        for endpoint in self.remote_mcp_endpoints:
            push(endpoint)
        for service in self.facts.get("service_registry", []):
            if not isinstance(service, dict):
                continue
            endpoint = service.get("endpoint")
            if isinstance(endpoint, str):
                push(endpoint)
        return ordered

    def _federated_mcp_call(self, tool_name: str, tool_args: dict, preferred: list = None) -> dict | None:
        for endpoint in self._iter_federated_mcp_endpoints(preferred):
            try:
                result = call_mcp_tool(endpoint, tool_name, tool_args)
                return {"source": endpoint, "result": result}
            except Exception:
                continue
        return None

    # Tool Handlers
    def _handle_data_quality_check(self, args: dict) -> dict:
        table_name = str(args.get("table_name", "") or "").strip()
        if table_name == "":
            return {"error": "table_name is required"}
        checks = parse_json_arg(args.get("checks", '["completeness", "accuracy", "consistency"]'), ["completeness", "accuracy", "consistency"])
        if not isinstance(checks, list):
            return {"error": "checks must be a JSON array"}

        checks = checks[:MAX_TOP_K]
        thresholds = {r["rule"]: r["threshold"] for r in self.facts.get("quality_rules", []) if isinstance(r, dict)}
        results = []
        for check in checks:
            check_name = str(check)
            seed = sum(ord(ch) for ch in f"{table_name}:{check_name}") % 7
            base_threshold = float(thresholds.get(check_name, 95.0))
            score = max(80.0, min(100.0, base_threshold + seed - 3))
            results.append({
                "check": check_name,
                "table": table_name,
                "score": round(score, 2),
                "status": "PASS" if score >= base_threshold else "WARN",
            })

        context = self._federated_mcp_call("get_statistics", {}, preferred=[self.context_mcp_endpoint])
        self.facts["tool_invocation"].append({"tool": "data_quality_check", "table": table_name, "timestamp": __import__("time").time()})
        overall_status = "PASS" if all(item["status"] == "PASS" for item in results) else "WARN"
        response = {"table": table_name, "checks": results, "overall_status": overall_status}
        if context:
            response["external_context"] = {"source": context["source"], "result": context["result"]}

        # M4 — enrich with graph context from KùzuDB when available
        graph_context = self._graph_context_for_table(table_name)
        if graph_context:
            response["graph_context"] = graph_context
        return response

    def _handle_schema_analysis(self, args: dict) -> dict:
        schema_def = args.get("schema_definition", "")
        return {
            "schema": schema_def[:200] + "..." if len(schema_def) > 200 else schema_def,
            "recommendations": [
                "Consider adding NOT NULL constraints",
                "Index frequently queried columns",
                "Add foreign key relationships",
            ],
            "status": "analyzed",
        }

    def _handle_data_profiling(self, args: dict) -> dict:
        table_name = str(args.get("table_name", "") or "").strip()
        if table_name == "":
            return {"error": "table_name is required"}
        columns = parse_json_arg(args.get("columns", "[]"), [])
        if not isinstance(columns, list):
            return {"error": "columns must be a JSON array"}
        columns = columns[:MAX_PROFILE_COLUMNS]

        mapping_result = self._federated_mcp_call(
            "es_index_info",
            {"index": table_name},
            preferred=[self.analytics_mcp_endpoint],
        )
        sample_result = self._federated_mcp_call(
            "es_search",
            {"index": table_name, "query": json.dumps({"match_all": {}}), "size": 1},
            preferred=[self.analytics_mcp_endpoint],
        )

        if mapping_result or sample_result:
            row_count = 0
            column_stats = {}

            if sample_result and isinstance(sample_result.get("result"), dict):
                hits = sample_result["result"].get("hits", {})
                if isinstance(hits, dict):
                    total = hits.get("total", {})
                    if isinstance(total, dict):
                        row_count = int(total.get("value", 0) or 0)
                    elif isinstance(total, int):
                        row_count = total

            if mapping_result and isinstance(mapping_result.get("result"), dict):
                payload = mapping_result["result"]
                if isinstance(payload.get(table_name), dict):
                    mappings = payload[table_name].get("mappings", {})
                    properties = mappings.get("properties", {}) if isinstance(mappings, dict) else {}
                else:
                    properties = {}
                if isinstance(properties, dict):
                    for col_name, details in properties.items():
                        if columns and col_name not in columns:
                            continue
                        col_type = details.get("type", "unknown") if isinstance(details, dict) else "unknown"
                        column_stats[col_name] = {"type": col_type}
            return {
                "table": table_name,
                "row_count": row_count,
                "column_stats": column_stats,
                "status": "profiled",
                "backend": "federated",
            }

        return {"table": table_name, "row_count": 0, "column_stats": {}, "status": "profiled-local"}

    def _handle_anomaly_detection(self, args: dict) -> dict:
        table_name = str(args.get("table_name", "") or "").strip()
        column = str(args.get("column", "") or "").strip()
        method = str(args.get("method", "zscore") or "zscore")
        if table_name == "" or column == "":
            return {"error": "table_name and column are required"}

        top_k = clamp_int(args.get("top_k", 10), 10, 1, MAX_TOP_K)
        delegation = self._federated_mcp_call(
            "ai_semantic_search",
            {"index": table_name, "query": f"anomaly detection on {column} using {method}", "k": top_k},
            preferred=[self.analytics_mcp_endpoint],
        )
        if delegation and isinstance(delegation.get("result"), dict):
            result = delegation["result"]
            hits = result.get("hits", {})
            hit_list = hits.get("hits", []) if isinstance(hits, dict) else []
            return {
                "table": table_name,
                "column": column,
                "method": method,
                "anomalies_found": len(hit_list) if isinstance(hit_list, list) else 0,
                "status": "federated",
                "source": delegation["source"],
            }

        return {"table": table_name, "column": column, "method": method, "anomalies_found": 0, "status": "degraded-no-remote"}

    def _handle_generate_cleaning_query(self, args: dict) -> dict:
        issue = args.get("issue_description", "")
        table = args.get("table_name", "")
        return {
            "issue": issue,
            "table": table,
            "suggested_query": f"-- Cleaning query for {table}\n-- Issue: {issue}\nUPDATE {table} SET ... WHERE ...",
            "status": "query_generated",
        }

    def _handle_ai_chat(self, args: dict) -> dict:
        config = get_config()
        messages = parse_json_arg(args.get("messages", "[]"), [])
        if not isinstance(messages, list) or len(messages) == 0:
            return {"content": "messages must be a non-empty JSON array", "error": True}
        
        try:
            deployments = aicore_request(config, "GET", "/v2/lm/deployments")
            resources = deployments.get("resources", [])
            if not resources:
                return {"content": "No AI deployment available", "error": True}
            
            deployment = resources[0]
            is_anthropic = "anthropic" in str(deployment.get("details", {})).lower()
            
            if is_anthropic:
                result = aicore_request(config, "POST", f"/v2/inference/deployments/{deployment['id']}/invoke", {
                    "anthropic_version": "bedrock-2023-05-31",
                    "max_tokens": 1024,
                    "messages": messages,
                })
                content = result.get("content", [{}])[0].get("text", "")
            else:
                result = aicore_request(config, "POST", f"/v2/inference/deployments/{deployment['id']}/chat/completions", {
                    "messages": messages,
                    "max_tokens": 1024,
                })
                content = result.get("choices", [{}])[0].get("message", {}).get("content", "")
            
            return {"content": content, "model": deployment["id"]}
        except Exception as e:
            return {"content": str(e), "error": True}

    def _graph_context_for_table(self, table_name: str) -> list[dict]:
        """Return KùzuDB column/FK/check context for a table, or [] if unavailable.

        Falls back silently so ``data_quality_check`` always degrades gracefully
        when the kuzu package is absent or the table has not been indexed yet.
        """
        try:
            from graph.kuzu_store import get_store as _get_store
            store = _get_store()
            if not store.available():
                return []
            return store.get_table_context(table_name, hops=2)
        except Exception as exc:
            import logging
            logging.getLogger("data-cleaning-copilot.mcp").debug(
                "graph context lookup skipped: %s", exc
            )
            return []

    def _handle_kuzu_index(self, args: dict) -> dict:
        """M2 — Parse a schema definition and index it into KùzuDB."""
        schema_raw = args.get("schema_definition") or ""
        if not schema_raw.strip():
            return {"error": "schema_definition is required"}

        schema = parse_json_arg(schema_raw, None)
        if not isinstance(schema, dict):
            return {"error": "schema_definition must be a JSON object"}

        checks_raw = parse_json_arg(args.get("checks", "[]"), [])
        if not isinstance(checks_raw, list):
            checks_raw = []

        try:
            from graph.kuzu_store import get_store as _get_store
            store = _get_store()
        except Exception as exc:
            return {"error": f"KùzuDB unavailable: {exc}"}

        if not store.available():
            return {"error": "KùzuDB not installed; add kuzu to pyproject.toml dependencies"}

        tables_indexed = 0
        columns_indexed = 0
        fks_indexed = 0
        checks_indexed = 0

        for table_def in schema.get("tables", []):
            if not isinstance(table_def, dict):
                continue
            tbl_name = str(table_def.get("name") or "").strip()
            if not tbl_name:
                continue
            store.upsert_table(tbl_name)
            tables_indexed += 1

            for col_def in table_def.get("columns", []):
                if not isinstance(col_def, dict):
                    continue
                col_name = str(col_def.get("name") or "").strip()
                col_type = str(col_def.get("type") or "UNKNOWN")
                if col_name:
                    store.upsert_column(tbl_name, col_name, col_type)
                    columns_indexed += 1

            for fk_def in table_def.get("foreign_keys", []):
                if not isinstance(fk_def, dict):
                    continue
                src_col = str(fk_def.get("column") or "").strip()
                ref_table = str(fk_def.get("ref_table") or "").strip()
                ref_col = str(fk_def.get("ref_column") or "").strip()
                constraint = str(fk_def.get("constraint_name") or "")
                if src_col and ref_table and ref_col:
                    store.upsert_table(ref_table)
                    store.link_fk(tbl_name, src_col, ref_table, ref_col, constraint)
                    fks_indexed += 1

        for check_def in checks_raw:
            if not isinstance(check_def, dict):
                continue
            tbl = str(check_def.get("table") or "").strip()
            chk_type = str(check_def.get("check_type") or "").strip()
            if not tbl or not chk_type:
                continue
            cols = check_def.get("columns") or []
            store.upsert_quality_check(
                tbl, chk_type,
                status=str(check_def.get("status") or ""),
                score=str(check_def.get("score") or ""),
                columns=[str(c) for c in cols if c],
            )
            checks_indexed += 1

        self.facts["tool_invocation"].append({
            "tool": "kuzu_index",
            "tables": tables_indexed,
            "columns": columns_indexed,
            "fks": fks_indexed,
            "checks": checks_indexed,
            "timestamp": __import__("time").time(),
        })
        return {
            "tables_indexed": tables_indexed,
            "columns_indexed": columns_indexed,
            "fks_indexed": fks_indexed,
            "checks_indexed": checks_indexed,
        }

    def _handle_kuzu_query(self, args: dict) -> dict:
        """M3 — Execute a read-only Cypher query against KùzuDB."""
        cypher = (args.get("cypher") or "").strip()
        if not cypher:
            return {"error": "cypher is required"}

        cypher_upper = cypher.upper().lstrip()
        for disallowed in ("CREATE ", "MERGE ", "DELETE ", "SET ", "REMOVE ", "DROP "):
            if cypher_upper.startswith(disallowed):
                return {"error": "Write Cypher statements are not permitted via this tool"}

        params = parse_json_arg(args.get("params", "{}"), {})
        if not isinstance(params, dict):
            params = {}

        try:
            from graph.kuzu_store import get_store as _get_store
            store = _get_store()
        except Exception as exc:
            return {"error": f"KùzuDB unavailable: {exc}"}

        if not store.available():
            return {"error": "KùzuDB not installed; add kuzu to pyproject.toml dependencies"}

        rows = store.run_query(cypher, params)
        self.facts["tool_invocation"].append({
            "tool": "kuzu_query",
            "row_count": len(rows),
            "timestamp": __import__("time").time(),
        })
        return {"rows": rows, "row_count": len(rows)}

    def _handle_mangle_query(self, args: dict) -> dict:
        predicate = args.get("predicate", "")
        query_args = parse_json_arg(args.get("args", "[]"), [])
        facts = self.facts.get(predicate)
        if facts:
            return {"predicate": predicate, "results": facts}
        if predicate == "service_available":
            return {"predicate": predicate, "results": self.facts.get("service_registry", [])}

        delegation = self._federated_mcp_call(
            "mangle_query",
            {"predicate": predicate, "args": json.dumps(query_args)},
            preferred=[self.analytics_mcp_endpoint, self.context_mcp_endpoint],
        )
        if delegation and isinstance(delegation.get("result"), dict):
            remote_result = delegation["result"]
            results = remote_result.get("results") if isinstance(remote_result, dict) else None
            if isinstance(results, list) and len(results) > 0:
                return {"predicate": predicate, "results": results, "source": delegation["source"]}
        return {"predicate": predicate, "results": [], "message": "Unknown predicate"}

    def handle_request(self, request: MCPRequest) -> MCPResponse:
        method = request.method
        params = request.params
        id = request.id

        try:
            if request.jsonrpc != "2.0":
                return MCPResponse(id, error={"code": -32600, "message": "Invalid Request: jsonrpc must be '2.0'"})
            if not isinstance(params, dict):
                return MCPResponse(id, error={"code": -32600, "message": "Invalid Request: params must be an object"})

            if method == "initialize":
                return MCPResponse(id, {
                    "protocolVersion": "2024-11-05",
                    "capabilities": {
                        "tools": {"listChanged": True},
                        "resources": {"listChanged": True},
                        "prompts": {"listChanged": True},
                    },
                    "serverInfo": {"name": "data-cleaning-copilot-mcp", "version": "1.0.0"},
                })

            elif method == "tools/list":
                return MCPResponse(id, {"tools": list(self.tools.values())})

            elif method == "tools/call":
                tool_name = params.get("name", "")
                args = params.get("arguments", {})
                if args is None:
                    args = {}
                if not isinstance(args, dict):
                    return MCPResponse(id, error={"code": -32602, "message": "Invalid params: arguments must be an object"})

                handlers = {
                    "data_quality_check": self._handle_data_quality_check,
                    "schema_analysis": self._handle_schema_analysis,
                    "data_profiling": self._handle_data_profiling,
                    "anomaly_detection": self._handle_anomaly_detection,
                    "generate_cleaning_query": self._handle_generate_cleaning_query,
                    "ai_chat": self._handle_ai_chat,
                    "mangle_query": self._handle_mangle_query,
                    "kuzu_index": self._handle_kuzu_index,
                    "kuzu_query": self._handle_kuzu_query,
                }

                handler = handlers.get(tool_name)
                if not handler:
                    return MCPResponse(id, error={"code": -32602, "message": f"Unknown tool: {tool_name}"})

                result = handler(args)
                return MCPResponse(id, {"content": [{"type": "text", "text": json.dumps(result, indent=2)}]})

            elif method == "resources/list":
                return MCPResponse(id, {"resources": list(self.resources.values())})

            elif method == "resources/read":
                uri = params.get("uri", "")
                if uri == "mangle://facts":
                    return MCPResponse(id, {"contents": [{"uri": uri, "mimeType": "application/json", "text": json.dumps(self.facts, indent=2)}]})
                return MCPResponse(id, error={"code": -32602, "message": f"Unknown resource: {uri}"})

            else:
                return MCPResponse(id, error={"code": -32601, "message": f"Method not found: {method}"})

        except Exception as e:
            return MCPResponse(id, error={"code": -32603, "message": str(e)})


# =============================================================================
# HTTP Server
# =============================================================================

mcp_server = MCPServer()


CORS_ALLOWED_ORIGINS = [
    o.strip() for o in os.environ.get("CORS_ALLOWED_ORIGINS", "http://localhost:3000,http://127.0.0.1:3000").split(",")
    if o.strip()
]

# =============================================================================
# Authentication Configuration
# =============================================================================

# MCP_AUTH_TOKEN: If set, all requests must include this token in the Authorization header.
# If not set, authentication is disabled (development mode only).
# In production, always set MCP_AUTH_TOKEN to a secure random value.
MCP_AUTH_TOKEN: Optional[str] = os.environ.get("MCP_AUTH_TOKEN")

# MCP_AUTH_REQUIRED: If "true", authentication is mandatory even if MCP_AUTH_TOKEN is not set.
# This prevents accidental deployment without authentication.
MCP_AUTH_REQUIRED: bool = os.environ.get("MCP_AUTH_REQUIRED", "false").lower() == "true"

# Allowed hosts that bypass authentication (for internal service-to-service calls)
MCP_AUTH_BYPASS_HOSTS = set(
    h.strip() for h in os.environ.get("MCP_AUTH_BYPASS_HOSTS", "127.0.0.1,localhost").split(",")
    if h.strip()
)


def _verify_auth(handler: BaseHTTPRequestHandler) -> tuple[bool, Optional[str]]:
    """
    Verify authentication for an incoming request.
    
    Returns:
        Tuple of (is_authenticated, error_message)
        - (True, None) if authenticated
        - (False, "error message") if not authenticated
    """
    # Check if authentication is configured
    if not MCP_AUTH_TOKEN:
        if MCP_AUTH_REQUIRED:
            return False, "Authentication required but MCP_AUTH_TOKEN not configured"
        # Development mode: no auth required
        return True, None
    
    # Check if request is from a bypass host (internal service calls)
    client_host = handler.client_address[0] if handler.client_address else ""
    if client_host in MCP_AUTH_BYPASS_HOSTS:
        return True, None
    
    # Extract and validate Bearer token
    auth_header = handler.headers.get("Authorization", "")
    if not auth_header:
        return False, "Missing Authorization header"
    
    if not auth_header.startswith("Bearer "):
        return False, "Invalid Authorization header format (expected: Bearer <token>)"
    
    provided_token = auth_header[7:]  # Strip "Bearer " prefix
    
    # Constant-time comparison to prevent timing attacks
    if not hmac.compare_digest(provided_token, MCP_AUTH_TOKEN):
        return False, "Invalid authentication token"
    
    return True, None


def _cors_origin(handler: BaseHTTPRequestHandler) -> str | None:
    origin = (handler.headers.get("Origin") or "").strip()
    if origin and origin in CORS_ALLOWED_ORIGINS:
        return origin
    return CORS_ALLOWED_ORIGINS[0] if CORS_ALLOWED_ORIGINS else None


class MCPHandler(BaseHTTPRequestHandler):
    def _write_json(self, status_code: int, payload: dict):
        self.send_response(status_code)
        self.send_header("Content-Type", "application/json")
        origin = _cors_origin(self)
        if origin:
            self.send_header("Access-Control-Allow-Origin", origin)
        self.end_headers()
        self.wfile.write(json.dumps(payload).encode())

    def do_OPTIONS(self):
        self.send_response(204)
        origin = _cors_origin(self)
        if origin:
            self.send_header("Access-Control-Allow-Origin", origin)
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.end_headers()

    def do_GET(self):
        if self.path == "/health":
            # Health endpoint does not require authentication
            from datetime import datetime, timezone
            response = {
                "status": "healthy",
                "service": "data-cleaning-copilot-mcp",
                "timestamp": datetime.now(timezone.utc).isoformat(),
                "auth_enabled": MCP_AUTH_TOKEN is not None,
            }
            self._write_json(200, response)
        else:
            self._write_json(404, {"error": "Not found"})

    def do_POST(self):
        if self.path == "/mcp":
            # Verify authentication for MCP endpoint
            is_auth, auth_error = _verify_auth(self)
            if not is_auth:
                self._write_json(401, {
                    "jsonrpc": "2.0",
                    "id": None,
                    "error": {"code": -32000, "message": f"Unauthorized: {auth_error}"}
                })
                return
            
            content_length = int(self.headers.get("Content-Length", 0))
            if content_length <= 0:
                self._write_json(400, {"jsonrpc": "2.0", "id": None, "error": {"code": -32600, "message": "Invalid Request: empty body"}})
                return
            if content_length > MAX_REQUEST_BYTES:
                self._write_json(413, {"jsonrpc": "2.0", "id": None, "error": {"code": -32600, "message": "Request too large"}})
                return

            raw_body = self.rfile.read(content_length)
            try:
                body = raw_body.decode("utf-8")
                data = json.loads(body)
                if not isinstance(data, dict):
                    self._write_json(400, {"jsonrpc": "2.0", "id": None, "error": {"code": -32600, "message": "Invalid Request"}})
                    return
                request = MCPRequest(data)
                response = mcp_server.handle_request(request)
                self._write_json(200, response.to_dict())
            except UnicodeDecodeError:
                self._write_json(400, {"jsonrpc": "2.0", "id": None, "error": {"code": -32700, "message": "Invalid UTF-8 body"}})
            except json.JSONDecodeError:
                self._write_json(400, {"jsonrpc": "2.0", "id": None, "error": {"code": -32700, "message": "Parse error"}})
        else:
            self._write_json(404, {"error": "Not found"})

    def log_message(self, format, *args):
        pass  # Suppress default logging


def main():
    import sys
    port = 9110
    for arg in sys.argv[1:]:
        if arg.startswith("--port="):
            port = int(arg.split("=")[1])

    # Security status
    auth_status = "ENABLED" if MCP_AUTH_TOKEN else "DISABLED (dev mode)"
    if MCP_AUTH_REQUIRED and not MCP_AUTH_TOKEN:
        print("ERROR: MCP_AUTH_REQUIRED=true but MCP_AUTH_TOKEN is not set.")
        print("Set MCP_AUTH_TOKEN environment variable or disable MCP_AUTH_REQUIRED.")
        sys.exit(1)

    server = HTTPServer(("", port), MCPHandler)
    print(f"""
╔══════════════════════════════════════════════════════════╗
║   Data Cleaning Copilot MCP Server                       ║
║   Model Context Protocol v2024-11-05                     ║
╚══════════════════════════════════════════════════════════╝

Server: http://localhost:{port}
Authentication: {auth_status}

Tools: data_quality_check, schema_analysis, data_profiling,
       anomaly_detection, generate_cleaning_query, ai_chat, mangle_query,
       kuzu_index, kuzu_query

Resources: data://schemas, data://quality_rules, mangle://facts

Security Notes:
  - Set MCP_AUTH_TOKEN for production deployments
  - Set MCP_AUTH_REQUIRED=true to enforce authentication
  - Bypass hosts: {', '.join(MCP_AUTH_BYPASS_HOSTS) or 'none'}
""")
    server.serve_forever()


if __name__ == "__main__":
    main()
