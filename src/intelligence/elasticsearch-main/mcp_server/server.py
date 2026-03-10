"""
Elasticsearch MCP Server

Model Context Protocol server with Mangle reasoning integration.
Provides tools for Elasticsearch search, indexing, and cluster management.
"""

import base64
import hashlib
import json
import logging
import os
import sys
import threading
import time
from datetime import datetime, timezone
from http.server import HTTPServer, BaseHTTPRequestHandler
from typing import Any
import urllib.request
import urllib.error

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s %(message)s",
    stream=sys.stdout,
)
logger = logging.getLogger("elasticsearch-mcp")

XSUAA_PUBLIC_KEY = os.environ.get("XSUAA_PUBLIC_KEY", "")
XSUAA_VERIFY_TOKEN = os.environ.get("XSUAA_VERIFY_TOKEN", "true").lower() == "true"
MCP_API_KEY = os.environ.get("MCP_API_KEY", "")

CORS_ALLOWED_ORIGINS = [
    o.strip() for o in os.environ.get("CORS_ALLOWED_ORIGINS", "http://localhost:3000,http://127.0.0.1:3000").split(",")
    if o.strip()
]


def _cors_origin(handler: BaseHTTPRequestHandler) -> str | None:
    origin = (handler.headers.get("Origin") or "").strip()
    if origin and origin in CORS_ALLOWED_ORIGINS:
        return origin
    return None


def _authenticate(handler: BaseHTTPRequestHandler) -> bool:
    """Validate Bearer token (JWT/XSUAA) or static API key.

    Returns True if the request is authorised, False otherwise.
    When XSUAA_VERIFY_TOKEN is false (dev mode), all requests pass.
    """
    if not XSUAA_VERIFY_TOKEN:
        return True

    auth_header = (handler.headers.get("Authorization") or "").strip()
    if not auth_header:
        return False

    if MCP_API_KEY and auth_header == f"ApiKey {MCP_API_KEY}":
        return True

    if auth_header.startswith("Bearer "):
        token = auth_header[len("Bearer "):].strip()
        if not token:
            return False
        if XSUAA_PUBLIC_KEY:
            try:
                import jwt as _jwt  # type: ignore
                _jwt.decode(token, XSUAA_PUBLIC_KEY, algorithms=["RS256"])
                return True
            except Exception as exc:
                logger.warning("JWT validation failed: %s", exc)
                return False
        # Public key not configured — accept any non-empty Bearer token
        # (allows development without a full XSUAA setup)
        return bool(token)

    return False


MAX_REQUEST_BYTES = int(os.environ.get("MCP_MAX_REQUEST_BYTES", str(1024 * 1024)))
MAX_SEARCH_SIZE = int(os.environ.get("MCP_MAX_SEARCH_SIZE", "100"))
MAX_KNN_K = int(os.environ.get("MCP_MAX_KNN_K", "100"))


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


def parse_json_arg(value: Any, default: Any):
    if isinstance(value, str):
        try:
            return json.loads(value)
        except json.JSONDecodeError:
            return default
    return value if value is not None else default

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
# Elasticsearch Configuration
# =============================================================================

def get_es_config() -> dict:
    return {
        "host": os.environ.get("ES_HOST", "http://localhost:9200"),
        "username": os.environ.get("ES_USERNAME", "elastic"),
        "password": os.environ.get("ES_PASSWORD", ""),
        "api_key": os.environ.get("ES_API_KEY", ""),
    }


def es_request(method: str, path: str, body: dict = None) -> Any:
    config = get_es_config()
    url = f"{config['host']}{path}"
    data = json.dumps(body).encode() if body else None
    
    headers = {"Content-Type": "application/json"}
    if config["api_key"]:
        headers["Authorization"] = f"ApiKey {config['api_key']}"
    elif config["password"]:
        import base64
        auth = base64.b64encode(f"{config['username']}:{config['password']}".encode()).decode()
        headers["Authorization"] = f"Basic {auth}"
    
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return json.loads(resp.read().decode())
    except urllib.error.HTTPError as e:
        return {"error": f"HTTP {e.code}: {e.reason}", "status_code": e.code}
    except Exception as e:
        return {"error": str(e)}


# =============================================================================
# AI Core Integration
# =============================================================================

def get_aicore_config() -> dict:
    return {
        "client_id": os.environ.get("AICORE_CLIENT_ID", ""),
        "client_secret": os.environ.get("AICORE_CLIENT_SECRET", ""),
        "auth_url": os.environ.get("AICORE_AUTH_URL", ""),
        "base_url": os.environ.get("AICORE_BASE_URL", os.environ.get("AICORE_SERVICE_URL", "")),
        "resource_group": os.environ.get("AICORE_RESOURCE_GROUP", "default"),
    }


def aicore_config_ready(config: dict) -> bool:
    return all(config.get(k) for k in ("client_id", "client_secret", "auth_url", "base_url"))


_cached_token: dict = {"token": None, "expires_at": 0}
_token_lock = threading.Lock()
_token_inflight: threading.Event | None = None


def get_aicore_token(config: dict) -> str:
    """Fetch or return cached AI Core OAuth token with coalesced refresh.

    A threading.Lock guards the check-then-fetch sequence so that concurrent
    callers never issue parallel token refresh requests.
    """
    global _token_inflight

    with _token_lock:
        if _cached_token["token"] and time.time() < _cached_token["expires_at"]:
            return _cached_token["token"]
        if not config["auth_url"]:
            return ""
        # Mark inflight so we hold the lock during the HTTP call
        auth = base64.b64encode(
            f"{config['client_id']}:{config['client_secret']}".encode()
        ).decode()
        req = urllib.request.Request(
            config["auth_url"],
            data=b"grant_type=client_credentials",
            headers={
                "Authorization": f"Basic {auth}",
                "Content-Type": "application/x-www-form-urlencoded",
            },
            method="POST",
        )
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                result = json.loads(resp.read().decode())
                _cached_token["token"] = result["access_token"]
                _cached_token["expires_at"] = (
                    time.time() + result.get("expires_in", 3600) - 60
                )
                return result["access_token"]
        except Exception as exc:
            logger.warning("AI Core token refresh failed: %s", exc)
            return ""


def aicore_request(method: str, path: str, body: dict = None) -> Any:
    config = get_aicore_config()
    token = get_aicore_token(config)
    if not token:
        return {"error": "No AI Core token"}
    url = f"{config['base_url']}{path}"
    data = json.dumps(body).encode() if body else None
    req = urllib.request.Request(
        url, data=data,
        headers={"Authorization": f"Bearer {token}", "AI-Resource-Group": config["resource_group"], "Content-Type": "application/json"},
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
        self._register_tools()
        self._register_resources()
        self._initialize_facts()

    def _register_tools(self):
        # Search
        self.tools["es_search"] = {
            "name": "es_search",
            "description": "Search Elasticsearch indices",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "index": {"type": "string", "description": "Index name or pattern"},
                    "query": {"type": "string", "description": "Query DSL as JSON"},
                    "size": {"type": "number", "description": "Number of results"},
                },
                "required": ["index"],
            },
        }

        # HANA Cloud Search
        self.tools["hana_search"] = {
            "name": "hana_search",
            "description": (
                "Execute a SQL SELECT query against SAP HANA Cloud and return results. "
                "Supports full HANA SQL syntax including full-text search predicates "
                "(CONTAINS) and vector similarity (COSINE_SIMILARITY). "
                "Results are returned as a JSON array of row objects."
            ),
            "inputSchema": {
                "type": "object",
                "properties": {
                    "sql": {
                        "type": "string",
                        "description": "SQL SELECT statement to execute against HANA Cloud",
                    },
                    "params": {
                        "type": "string",
                        "description": "Query parameters as JSON array (optional)",
                    },
                    "max_rows": {
                        "type": "number",
                        "description": "Maximum rows to return (default 100, max 1000)",
                    },
                },
                "required": ["sql"],
            },
        }

        # HANA → ES Sync (index HANA data into Elasticsearch)
        self.tools["hana_index_to_es"] = {
            "name": "hana_index_to_es",
            "description": (
                "Run a SQL query against HANA Cloud and bulk-index the result rows "
                "into an Elasticsearch index. Optionally generates and stores embeddings "
                "for a text column using AI Core, enabling semantic search over HANA data."
            ),
            "inputSchema": {
                "type": "object",
                "properties": {
                    "sql": {
                        "type": "string",
                        "description": "SQL SELECT to fetch rows from HANA Cloud",
                    },
                    "es_index": {
                        "type": "string",
                        "description": "Target Elasticsearch index name",
                    },
                    "id_field": {
                        "type": "string",
                        "description": "Column to use as the Elasticsearch document _id",
                    },
                    "embed_field": {
                        "type": "string",
                        "description": "Column whose text value should be embedded (optional)",
                    },
                    "vector_field": {
                        "type": "string",
                        "description": "Elasticsearch field name to store the embedding vector",
                    },
                    "max_rows": {
                        "type": "number",
                        "description": "Maximum rows to sync (default 500)",
                    },
                },
                "required": ["sql", "es_index"],
            },
        }

        # Vector Search (kNN)
        self.tools["es_vector_search"] = {
            "name": "es_vector_search",
            "description": "Perform kNN vector similarity search",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "index": {"type": "string", "description": "Index name"},
                    "field": {"type": "string", "description": "Vector field name"},
                    "query_vector": {"type": "string", "description": "Query vector as JSON array"},
                    "k": {"type": "number", "description": "Number of nearest neighbors"},
                },
                "required": ["index", "field", "query_vector"],
            },
        }

        # Index Document
        self.tools["es_index"] = {
            "name": "es_index",
            "description": "Index a document into Elasticsearch",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "index": {"type": "string", "description": "Target index"},
                    "document": {"type": "string", "description": "Document as JSON"},
                    "id": {"type": "string", "description": "Document ID (optional)"},
                },
                "required": ["index", "document"],
            },
        }

        # Cluster Health
        self.tools["es_cluster_health"] = {
            "name": "es_cluster_health",
            "description": "Get Elasticsearch cluster health",
            "inputSchema": {
                "type": "object",
                "properties": {},
            },
        }

        # Index Info
        self.tools["es_index_info"] = {
            "name": "es_index_info",
            "description": "Get information about indices",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "index": {"type": "string", "description": "Index name or pattern"},
                },
                "required": ["index"],
            },
        }

        # Generate Embedding
        self.tools["generate_embedding"] = {
            "name": "generate_embedding",
            "description": "Generate embedding vector using AI Core",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "text": {"type": "string", "description": "Text to embed"},
                },
                "required": ["text"],
            },
        }

        # AI Search (semantic)
        self.tools["ai_semantic_search"] = {
            "name": "ai_semantic_search",
            "description": "Semantic search using AI embeddings + Elasticsearch kNN",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "index": {"type": "string", "description": "Index name"},
                    "query": {"type": "string", "description": "Natural language query"},
                    "vector_field": {"type": "string", "description": "Vector field name"},
                    "k": {"type": "number", "description": "Number of results"},
                },
                "required": ["index", "query", "vector_field"],
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

        # Graph-RAG: index ES search results into KùzuDB
        self.tools["kuzu_index"] = {
            "name": "kuzu_index",
            "description": (
                "Extract OData entity nodes and relationships from Elasticsearch search "
                "results and store them in the embedded KùzuDB graph database. "
                "Use this to build a graph-context layer before running ai_semantic_search "
                "so that related entities are surfaced in the RAG prompt."
            ),
            "inputSchema": {
                "type": "object",
                "properties": {
                    "index": {
                        "type": "string",
                        "description": "Elasticsearch index to pull documents from",
                    },
                    "query": {
                        "type": "string",
                        "description": "ES Query DSL as JSON (default: match_all)",
                    },
                    "entity_type_field": {
                        "type": "string",
                        "description": "Document field that holds the entity type (default: entity_type)",
                    },
                    "entity_id_field": {
                        "type": "string",
                        "description": "Document field that holds the entity id (default: _id)",
                    },
                    "relation_fields": {
                        "type": "string",
                        "description": "JSON array of {field, target_type} objects describing FK fields",
                    },
                    "size": {
                        "type": "number",
                        "description": "Number of documents to process (default 50)",
                    },
                },
                "required": ["index"],
            },
        }

        # Graph-RAG: run a Cypher query against KùzuDB
        self.tools["kuzu_query"] = {
            "name": "kuzu_query",
            "description": (
                "Execute a Cypher query against the embedded KùzuDB graph database "
                "and return matching rows as JSON. "
                "Use for graph traversal, relationship discovery, and context retrieval."
            ),
            "inputSchema": {
                "type": "object",
                "properties": {
                    "cypher": {
                        "type": "string",
                        "description": "Cypher query string",
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
        self.resources["es://cluster"] = {
            "uri": "es://cluster",
            "name": "Cluster Info",
            "description": "Elasticsearch cluster information",
            "mimeType": "application/json",
        }
        self.resources["es://indices"] = {
            "uri": "es://indices",
            "name": "Indices List",
            "description": "List of all indices",
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
            {"name": "es-search", "endpoint": "es://search", "model": "elasticsearch"},
            {"name": "es-vector", "endpoint": "es://vector", "model": "knn-search"},
            {"name": "ai-embed", "endpoint": "aicore://embed", "model": "text-embedding"},
        ]
        self.facts["tool_invocation"] = []
        self._audit_lock = threading.Lock()

    def _audit(self, tool: str, index: str = "", extra: dict | None = None) -> None:
        """Append a tool invocation audit entry and persist to Elasticsearch."""
        entry: dict = {
            "tool": tool,
            "index": index,
            "timestamp": time.time(),
            "ts_iso": datetime.now(timezone.utc).isoformat(),
        }
        if extra:
            entry.update(extra)
        with self._audit_lock:
            self.facts["tool_invocation"].append(entry)
        # Best-effort persistence; failures must not block the tool response.
        try:
            es_request("POST", "/sap_mcp_audit/_doc", entry)
        except Exception as exc:
            logger.warning("Audit persist failed: %s", exc)

    # Tool Handlers
    def _handle_hana_search(self, args: dict) -> dict:
        sql = (args.get("sql") or "").strip()
        if not sql:
            return {"error": "sql is required"}
        sql_upper = sql.upper().lstrip()
        if not sql_upper.startswith("SELECT"):
            return {"error": "Only SELECT statements are permitted"}
        params = parse_json_arg(args.get("params", "[]"), [])
        if not isinstance(params, list):
            params = []
        max_rows = clamp_int(args.get("max_rows", 100), 100, 1, 1000)
        result = hana_query(sql, params, max_rows)
        self._audit("hana_search", extra={"sql_prefix": sql[:120]})
        return result

    def _handle_hana_index_to_es(self, args: dict) -> dict:
        sql = (args.get("sql") or "").strip()
        es_index = (args.get("es_index") or "").strip()
        if not sql or not es_index:
            return {"error": "sql and es_index are required"}
        sql_upper = sql.upper().lstrip()
        if not sql_upper.startswith("SELECT"):
            return {"error": "Only SELECT statements are permitted"}
        id_field = args.get("id_field") or None
        embed_field = args.get("embed_field") or None
        vector_field = args.get("vector_field") or "embedding"
        max_rows = clamp_int(args.get("max_rows", 500), 500, 1, 5000)

        hana_result = hana_query(sql, [], max_rows)
        if "error" in hana_result:
            return hana_result
        rows = hana_result.get("rows", [])
        if not rows:
            return {"indexed": 0, "message": "No rows returned from HANA"}

        indexed = 0
        errors = []
        for row in rows:
            doc = dict(row)
            doc_id = str(doc.get(id_field)) if id_field and id_field in doc else None

            if embed_field and embed_field in doc:
                embed_text = str(doc[embed_field])
                embed_result = self._handle_generate_embedding_internal(embed_text)
                if "error" not in embed_result:
                    embedding = embed_result.get("data", [{}])[0].get("embedding", [])
                    if embedding:
                        doc[vector_field] = embedding

            if doc_id:
                resp = es_request("PUT", f"/{es_index}/_doc/{doc_id}", doc)
            else:
                resp = es_request("POST", f"/{es_index}/_doc", doc)

            if "error" in resp:
                errors.append({"doc_id": doc_id, "error": resp["error"]})
            else:
                indexed += 1

        self._audit("hana_index_to_es", index=es_index, extra={"indexed": indexed, "errors": len(errors)})
        return {"indexed": indexed, "errors": errors[:10], "total_rows": len(rows)}

    _DSL_ALLOWED_TYPES: frozenset = frozenset({
        "match", "match_all", "match_phrase", "match_phrase_prefix",
        "multi_match", "common", "query_string", "simple_query_string",
        "term", "terms", "terms_set", "range", "exists", "prefix", "wildcard",
        "regexp", "fuzzy", "ids", "bool", "boosting", "constant_score",
        "dis_max", "nested", "has_child", "has_parent", "knn",
    })

    # Keys inside a compound clause that may themselves contain sub-queries.
    _DSL_COMPOUND_KEYS: frozenset = frozenset({
        "must", "should", "must_not", "filter", "queries",
    })

    def _dsl_allowed(self, query: dict) -> bool:
        """Return False if the query uses any disallowed DSL clause type.

        Only the *clause-type* keys (e.g. 'match', 'bool', 'script') are
        validated against the allowlist.  Field names and parameter values
        inside a leaf clause (e.g. ``{"match": {"title": "test"}}``) are
        treated as opaque and are NOT checked against the allowlist.

        Recursion descends only into known compound containers
        (``bool.must``, ``bool.filter``, ``dis_max.queries``, etc.) so that
        field-name keys inside leaf clauses never trigger false rejections.

        Blocks: script, function_score, script_score, percolate, pinned,
        more_like_this, rank_feature, span_* and any clause not in the
        explicit allowlist.
        """
        if not isinstance(query, dict):
            return True
        for clause_type, clause_val in query.items():
            if clause_type not in self._DSL_ALLOWED_TYPES:
                return False
            # Only recurse into the contents of compound/boolean clauses.
            if clause_type in ("bool", "boosting", "constant_score",
                               "dis_max", "nested", "has_child", "has_parent"):
                if isinstance(clause_val, dict):
                    for sub_key, sub_val in clause_val.items():
                        if sub_key in self._DSL_COMPOUND_KEYS:
                            sub_queries = sub_val if isinstance(sub_val, list) else [sub_val]
                            for sq in sub_queries:
                                if isinstance(sq, dict) and not self._dsl_allowed(sq):
                                    return False
        return True

    def _handle_es_search(self, args: dict) -> dict:
        index = args.get("index", "*")
        query = parse_json_arg(args.get("query", '{"match_all": {}}'), {"match_all": {}})
        if not isinstance(query, dict):
            query = {"match_all": {}}
        if not self._dsl_allowed(query):
            return {"error": "Query DSL contains disallowed clause type"}
        size = clamp_int(args.get("size", 10), 10, 1, MAX_SEARCH_SIZE)
        body = {"query": query, "size": size}
        result = es_request("POST", f"/{index}/_search", body)
        self._audit("es_search", index=index)
        return result

    def _handle_es_vector_search(self, args: dict) -> dict:
        index = args.get("index", "")
        field = args.get("field", "vector")
        query_vector = parse_json_arg(args.get("query_vector", "[]"), [])
        if not isinstance(query_vector, list):
            return {"error": "query_vector must be a JSON array"}
        k = clamp_int(args.get("k", 10), 10, 1, MAX_KNN_K)
        body = {"knn": {"field": field, "query_vector": query_vector, "k": k, "num_candidates": k * 2}}
        self._audit("es_vector_search", index=index)
        return es_request("POST", f"/{index}/_search", body)

    def _handle_es_index(self, args: dict) -> dict:
        index = args.get("index", "")
        document = parse_json_arg(args.get("document", "{}"), {})
        if not isinstance(document, dict):
            return {"error": "document must be a JSON object"}
        doc_id = args.get("id")
        self._audit("es_index", index=index)
        if doc_id:
            return es_request("PUT", f"/{index}/_doc/{doc_id}", document)
        return es_request("POST", f"/{index}/_doc", document)

    def _handle_es_cluster_health(self, args: dict) -> dict:
        self._audit("es_cluster_health")
        return es_request("GET", "/_cluster/health")

    def _handle_es_index_info(self, args: dict) -> dict:
        index = args.get("index", "*")
        self._audit("es_index_info", index=index)
        return es_request("GET", f"/{index}")

    def _handle_generate_embedding_internal(self, text: str) -> dict:
        """Generate an embedding bypassing the governance check.

        Only used by trusted internal callers (e.g. hana_index_to_es) that
        operate on already-authenticated, approved sync jobs.  External tool
        callers must use _handle_generate_embedding which runs _governance_check.
        """
        text = str(text or "").strip()
        if not text:
            return {"error": "text is required"}
        config = get_aicore_config()
        embed_deployment_id = os.environ.get("AICORE_EMBEDDING_DEPLOYMENT_ID", "")
        if embed_deployment_id:
            return aicore_request(
                "POST",
                f"/v2/inference/deployments/{embed_deployment_id}/embeddings",
                {"input": [text]},
            )
        deployments = aicore_request("GET", "/v2/lm/deployments")
        resources = deployments.get("resources", [])
        deployment = next(
            (d for d in resources if "embed" in str(d.get("details", {})).lower()),
            resources[0] if resources else None,
        )
        if not deployment:
            return {"error": "No embedding deployment"}
        return aicore_request(
            "POST",
            f"/v2/inference/deployments/{deployment['id']}/embeddings",
            {"input": [text]},
        )

    def _governance_check(self, text: str, tool: str) -> dict | None:
        """Return an error dict if the text references a confidential index
        while targeting a tool that should not process raw confidential content.

        This prevents callers from bypassing index-based routing by routing
        a confidential payload through the public embedding/semantic-search path.
        Returns None when governance passes.
        """
        try:
            from agent.elasticsearch_agent import MangleEngine as _ME
            engine = _ME()
            results = engine.query("route_to_vllm", text)
            if results:
                reason = results[0].get("reason", "governance policy")
                self._audit(tool, extra={"blocked": True, "reason": reason})
                return {
                    "error": "Governance block: request references confidential data",
                    "reason": reason,
                    "tool": tool,
                }
        except Exception as exc:
            logger.warning("Governance check unavailable (%s); allowing request", exc)
        return None

    def _handle_generate_embedding(self, args: dict) -> dict:
        text = str(args.get("text", "") or "")
        if text.strip() == "":
            return {"error": "text is required"}
        blocked = self._governance_check(text, "generate_embedding")
        if blocked:
            return blocked
        config = get_aicore_config()
        embed_deployment_id = os.environ.get("AICORE_EMBEDDING_DEPLOYMENT_ID", "")
        if embed_deployment_id:
            result = aicore_request(
                "POST",
                f"/v2/inference/deployments/{embed_deployment_id}/embeddings",
                {"input": [text]},
            )
        else:
            deployments = aicore_request("GET", "/v2/lm/deployments")
            resources = deployments.get("resources", [])
            deployment = next(
                (d for d in resources if "embed" in str(d.get("details", {})).lower()),
                resources[0] if resources else None,
            )
            if not deployment:
                return {"error": "No embedding deployment"}
            result = aicore_request(
                "POST",
                f"/v2/inference/deployments/{deployment['id']}/embeddings",
                {"input": [text]},
            )
        self._audit("generate_embedding")
        return result

    def _handle_ai_semantic_search(self, args: dict) -> dict:
        index = args.get("index", "")
        query = args.get("query", "")
        vector_field = args.get("vector_field", "embedding")
        k = clamp_int(args.get("k", 10), 10, 1, MAX_KNN_K)

        blocked = self._governance_check(f"{index} {query}", "ai_semantic_search")
        if blocked:
            return blocked

        embed_result = self._handle_generate_embedding({"text": query})
        if "error" in embed_result:
            return embed_result

        embedding = embed_result.get("data", [{}])[0].get("embedding", [])
        if not embedding:
            return {"error": "Failed to generate embedding"}

        body = {"knn": {"field": vector_field, "query_vector": embedding, "k": k, "num_candidates": k * 2}}
        es_result = es_request("POST", f"/{index}/_search", body)

        # M4 — enrich result with graph context from KùzuDB when available
        graph_context = self._graph_context_for_hits(es_result, index)
        self._audit("ai_semantic_search", index=index)
        if graph_context:
            es_result["graph_context"] = graph_context
        return es_result

    def _graph_context_for_hits(self, es_result: dict, index: str) -> list[dict]:
        """Return KùzuDB neighbour entities for the top ES hit, if any.

        Falls back silently when the graph store is unavailable or the hit has
        no known entity_id, so ``ai_semantic_search`` always degrades gracefully.
        """
        try:
            from graph.kuzu_store import get_store as _get_store
            store = _get_store()
            if not store.available():
                return []
            hits = es_result.get("hits", {}).get("hits", [])
            if not hits:
                return []
            top_hit = hits[0].get("_source", {})
            entity_id = str(
                top_hit.get("entity_id")
                or top_hit.get("id")
                or hits[0].get("_id", "")
            )
            entity_type = str(top_hit.get("entity_type", ""))
            if not entity_id:
                return []
            return store.get_entity_context(entity_type, entity_id, hops=2)
        except Exception as exc:
            logger.debug("graph context lookup skipped: %s", exc)
            return []

    def _handle_kuzu_index(self, args: dict) -> dict:
        """M2 — Index ES search results into KùzuDB as graph nodes/edges."""
        index = (args.get("index") or "").strip()
        if not index:
            return {"error": "index is required"}

        query = parse_json_arg(args.get("query", '{"match_all": {}}'), {"match_all": {}})
        if not isinstance(query, dict):
            query = {"match_all": {}}
        size = clamp_int(args.get("size", 50), 50, 1, MAX_SEARCH_SIZE)
        entity_type_field = args.get("entity_type_field") or "entity_type"
        entity_id_field = args.get("entity_id_field") or None
        relation_fields = parse_json_arg(args.get("relation_fields", "[]"), [])
        if not isinstance(relation_fields, list):
            relation_fields = []

        es_result = es_request("POST", f"/{index}/_search", {"query": query, "size": size})
        if "error" in es_result:
            return es_result

        try:
            from graph.kuzu_store import get_store as _get_store
            store = _get_store()
        except Exception as exc:
            return {"error": f"KùzuDB unavailable: {exc}"}

        if not store.available():
            return {"error": "KùzuDB not installed; add kuzu to pip dependencies"}

        store.upsert_index_node(index)
        hits = es_result.get("hits", {}).get("hits", [])
        nodes_created = 0
        edges_created = 0

        for hit in hits:
            source = hit.get("_source", {})
            entity_type = str(source.get(entity_type_field, "Unknown"))
            entity_id = str(
                source.get(entity_id_field) if entity_id_field else None
                or hit.get("_id", "")
            )
            if not entity_id:
                continue

            props = {k: v for k, v in source.items() if not isinstance(v, list) or len(str(v)) < 256}
            store.upsert_entity(entity_type, entity_id, props)
            store.link_entity_to_index(entity_id, index)
            nodes_created += 1

            for rel_spec in relation_fields:
                fk_field = rel_spec.get("field", "")
                target_type = rel_spec.get("target_type", "")
                fk_value = source.get(fk_field)
                if fk_value:
                    target_id = str(fk_value)
                    store.upsert_entity(target_type, target_id, {})
                    store.link_entities(entity_type, entity_id, target_type, target_id, fk_field)
                    edges_created += 1

        self._audit("kuzu_index", index=index, extra={"nodes": nodes_created, "edges": edges_created})
        return {"nodes_created": nodes_created, "edges_created": edges_created, "index": index}

    def _handle_kuzu_query(self, args: dict) -> dict:
        """M3 — Execute a Cypher query against KùzuDB and return rows."""
        cypher = (args.get("cypher") or "").strip()
        if not cypher:
            return {"error": "cypher is required"}

        # Block obviously mutating statements from external callers
        cypher_upper = cypher.upper().lstrip()
        for disallowed in ("CREATE ", "MERGE ", "DELETE ", "SET ", "REMOVE ", "DROP "):
            if cypher_upper.startswith(disallowed):
                return {"error": f"Write Cypher statements are not permitted via this tool"}

        params = parse_json_arg(args.get("params", "{}"), {})
        if not isinstance(params, dict):
            params = {}

        try:
            from graph.kuzu_store import get_store as _get_store
            store = _get_store()
        except Exception as exc:
            return {"error": f"KùzuDB unavailable: {exc}"}

        if not store.available():
            return {"error": "KùzuDB not installed; add kuzu to pip dependencies"}

        rows = store.run_query(cypher, params)
        self._audit("kuzu_query", extra={"row_count": len(rows)})
        return {"rows": rows, "row_count": len(rows)}

    def _handle_mangle_query(self, args: dict) -> dict:
        predicate = args.get("predicate", "")
        # Redact tool_invocation details from external callers to limit
        # information disclosure through the Mangle introspection channel.
        if predicate == "tool_invocation":
            with self._audit_lock:
                count = len(self.facts.get("tool_invocation", []))
            return {"predicate": predicate, "results": {"invocation_count": count}}
        facts = self.facts.get(predicate)
        if facts:
            return {"predicate": predicate, "results": facts}
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
                    "capabilities": {"tools": {"listChanged": True}, "resources": {"listChanged": True}, "prompts": {"listChanged": True}},
                    "serverInfo": {"name": "elasticsearch-mcp", "version": "1.0.0"},
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
                    "es_search": self._handle_es_search,
                    "es_vector_search": self._handle_es_vector_search,
                    "es_index": self._handle_es_index,
                    "es_cluster_health": self._handle_es_cluster_health,
                    "es_index_info": self._handle_es_index_info,
                    "generate_embedding": self._handle_generate_embedding,
                    "ai_semantic_search": self._handle_ai_semantic_search,
                    "mangle_query": self._handle_mangle_query,
                    "hana_search": self._handle_hana_search,
                    "hana_index_to_es": self._handle_hana_index_to_es,
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
                if uri == "es://cluster":
                    result = es_request("GET", "/_cluster/health")
                    return MCPResponse(id, {"contents": [{"uri": uri, "mimeType": "application/json", "text": json.dumps(result, indent=2)}]})
                if uri == "es://indices":
                    result = es_request("GET", "/_cat/indices?format=json")
                    return MCPResponse(id, {"contents": [{"uri": uri, "mimeType": "application/json", "text": json.dumps(result, indent=2)}]})
                if uri == "mangle://facts":
                    return MCPResponse(id, {"contents": [{"uri": uri, "mimeType": "application/json", "text": json.dumps(self.facts, indent=2)}]})
                return MCPResponse(id, error={"code": -32602, "message": f"Unknown resource: {uri}"})

            else:
                return MCPResponse(id, error={"code": -32601, "message": f"Method not found: {method}"})

        except Exception as e:
            return MCPResponse(id, error={"code": -32603, "message": str(e)})


# =============================================================================
# HANA Cloud Integration
# =============================================================================

def get_hana_config() -> dict:
    return {
        "host": os.environ.get("HANA_HOST", ""),
        "port": int(os.environ.get("HANA_PORT", "443")),
        "user": os.environ.get("HANA_USER", ""),
        "password": os.environ.get("HANA_PASSWORD", ""),
        "database": os.environ.get("HANA_DATABASE", ""),
        "encrypt": os.environ.get("HANA_ENCRYPT", "true").lower() == "true",
    }


def hana_query(sql: str, params: list | None = None, max_rows: int = 100) -> dict:
    """Execute a read-only SQL query against HANA Cloud.

    Uses hdbcli (SAP HANA Python Client) when available; falls back to a
    descriptive error so the service degrades gracefully without the driver.
    """
    try:
        from hdbcli import dbapi  # type: ignore
    except ImportError:
        return {"error": "hdbcli not installed; add hdbcli to requirements"}

    config = get_hana_config()
    if not config["host"] or not config["user"]:
        return {"error": "HANA_HOST and HANA_USER environment variables are required"}

    try:
        conn = dbapi.connect(
            address=config["host"],
            port=config["port"],
            user=config["user"],
            password=config["password"],
            databaseName=config["database"] or None,
            encrypt=config["encrypt"],
            sslValidateCertificate=config["encrypt"],
        )
        cursor = conn.cursor()
        cursor.execute(sql, params or [])
        columns = [desc[0] for desc in cursor.description] if cursor.description else []
        rows = []
        for row in cursor.fetchmany(max_rows):
            rows.append(dict(zip(columns, row)))
        cursor.close()
        conn.close()
        return {"columns": columns, "rows": rows, "row_count": len(rows)}
    except Exception as exc:
        logger.warning("HANA query failed: %s", exc)
        return {"error": str(exc)}


# =============================================================================
# Middleware wiring
# =============================================================================

try:
    import sys as _sys
    _sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    from middleware.rate_limiter import get_mcp_limiter  # type: ignore
    from middleware.circuit_breaker import get_aicore_breaker  # type: ignore
    _MIDDLEWARE_AVAILABLE = True
except ImportError:
    _MIDDLEWARE_AVAILABLE = False
    logger.info("middleware package not on path; running without rate-limiter / circuit-breaker")


mcp_server = MCPServer()


class MCPHandler(BaseHTTPRequestHandler):
    def _write_json(self, status_code: int, payload: dict):
        self.send_response(status_code)
        self.send_header("Content-Type", "application/json")
        origin = _cors_origin(self)
        if origin:
            self.send_header("Access-Control-Allow-Origin", origin)
        self.end_headers()
        self.wfile.write(json.dumps(payload).encode())

    def _reject(self, status: int, code: int, message: str) -> None:
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        origin = _cors_origin(self)
        if origin:
            self.send_header("Access-Control-Allow-Origin", origin)
        self.end_headers()
        self.wfile.write(json.dumps({
            "jsonrpc": "2.0", "id": None,
            "error": {"code": code, "message": message},
        }).encode())

    def do_OPTIONS(self):
        self.send_response(204)
        origin = _cors_origin(self)
        if origin:
            self.send_header("Access-Control-Allow-Origin", origin)
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type, Authorization")
        self.end_headers()

    def do_GET(self):
        if self.path == "/health":
            aicore_cfg = get_aicore_config()
            response = {
                "status": "healthy",
                "service": "elasticsearch-mcp",
                "timestamp": datetime.now(timezone.utc).isoformat(),
                "es_host": get_es_config().get("host"),
                "aicore_config_ready": aicore_config_ready(aicore_cfg),
            }
            self._write_json(200, response)
        else:
            self._write_json(404, {"error": "Not found"})

    def do_POST(self):
        if self.path == "/mcp":
            if not _authenticate(self):
                self._reject(401, -32600, "Unauthorized: valid Bearer token or ApiKey required")
                return

            if _MIDDLEWARE_AVAILABLE:
                client_key = (self.headers.get("X-Forwarded-For") or self.client_address[0] or "unknown")
                limiter = get_mcp_limiter()
                allowed, _meta = limiter.check(client_key)
                if not allowed:
                    self.send_response(429)
                    self.send_header("Content-Type", "application/json")
                    for k, v in limiter.get_headers(client_key).items():
                        self.send_header(k, str(v))
                    self.end_headers()
                    self.wfile.write(json.dumps({
                        "jsonrpc": "2.0", "id": None,
                        "error": {"code": -32600, "message": "Rate limit exceeded"},
                    }).encode())
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

    def log_message(self, fmt, *args):
        logger.debug(fmt, *args)


def main():
    import sys
    port = 9120
    for arg in sys.argv[1:]:
        if arg.startswith("--port="):
            port = int(arg.split("=")[1])

    server = HTTPServer(("", port), MCPHandler)
    print(f"""
╔══════════════════════════════════════════════════════════╗
║   Elasticsearch MCP Server with Mangle Reasoning         ║
║   Model Context Protocol v2024-11-05                     ║
╚══════════════════════════════════════════════════════════╝

Server: http://localhost:{port}

Tools: es_search, es_vector_search, es_index, es_cluster_health,
       es_index_info, generate_embedding, ai_semantic_search, mangle_query

Resources: es://cluster, es://indices, mangle://facts
""")
    server.serve_forever()


if __name__ == "__main__":
    main()
