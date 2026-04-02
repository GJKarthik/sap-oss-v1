"""
Elasticsearch MCP Server — Kyma / sap-ai-services edition

Model Context Protocol server targeting the existing Elasticsearch instance
running on Kyma under sap-ai-services.  All Mangle, KùzuDB, HANA Cloud,
and OpenAI integrations have been removed.  Only pure ES + AI Core tooling
remains.

Tools
-----
es_search            – Search ES indices (Query DSL)
es_vector_search     – kNN vector similarity search
es_index             – Index a document
es_cluster_health    – Cluster health
es_index_info        – Index mappings / stats
generate_embedding   – AI Core embedding generation
ai_semantic_search   – Semantic search (AI Core embedding → ES kNN)

Resources
---------
es://cluster         – Cluster info
es://indices         – Index list
"""

import base64
import json
import logging
import os
import sys
import threading
import time
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, HTTPServer
from typing import Any
import urllib.request
import urllib.error

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s %(message)s",
    stream=sys.stdout,
)
logger = logging.getLogger("es-mcp")

# ---------------------------------------------------------------------------
# Auth / CORS configuration
# ---------------------------------------------------------------------------

XSUAA_PUBLIC_KEY: str = os.environ.get("XSUAA_PUBLIC_KEY", "")
XSUAA_VERIFY_TOKEN: bool = (
    os.environ.get("XSUAA_VERIFY_TOKEN", "true").lower() == "true"
)
MCP_API_KEY: str = os.environ.get("MCP_API_KEY", "")

CORS_ALLOWED_ORIGINS: list[str] = [
    o.strip()
    for o in os.environ.get(
        "CORS_ALLOWED_ORIGINS",
        "http://localhost:3000,http://127.0.0.1:3000",
    ).split(",")
    if o.strip()
]


def _cors_origin(handler: BaseHTTPRequestHandler) -> str | None:
    origin = (handler.headers.get("Origin") or "").strip()
    return origin if origin and origin in CORS_ALLOWED_ORIGINS else None


def _authenticate(handler: BaseHTTPRequestHandler) -> bool:
    """Validate Bearer token (JWT/XSUAA) or static API key.

    Returns True if the request is authorised.
    When XSUAA_VERIFY_TOKEN is false (dev/test mode) every request passes.
    """
    if not XSUAA_VERIFY_TOKEN:
        return True

    auth_header = (handler.headers.get("Authorization") or "").strip()
    if not auth_header:
        return False

    # Static API key shortcut (useful for internal Kyma service-to-service calls)
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
        # (allows local development without a full XSUAA setup)
        return bool(token)

    return False


# ---------------------------------------------------------------------------
# Safety limits
# ---------------------------------------------------------------------------

MAX_REQUEST_BYTES: int = int(os.environ.get("MCP_MAX_REQUEST_BYTES", str(1024 * 1024)))
MAX_SEARCH_SIZE: int = int(os.environ.get("MCP_MAX_SEARCH_SIZE", "100"))
MAX_KNN_K: int = int(os.environ.get("MCP_MAX_KNN_K", "100"))


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def clamp_int(value: Any, default: int, min_value: int, max_value: int) -> int:
    try:
        parsed = int(value)
    except (TypeError, ValueError):
        return default
    return max(min_value, min(max_value, parsed))


def parse_json_arg(value: Any, default: Any) -> Any:
    if isinstance(value, str):
        try:
            return json.loads(value)
        except json.JSONDecodeError:
            return default
    return value if value is not None else default


# ---------------------------------------------------------------------------
# MCP request / response wrappers
# ---------------------------------------------------------------------------

class MCPRequest:
    def __init__(self, data: dict):
        self.jsonrpc = data.get("jsonrpc", "2.0")
        self.id = data.get("id")
        self.method = data.get("method", "")
        self.params = data.get("params", {})


class MCPResponse:
    def __init__(self, id: Any, result: Any = None, error: dict | None = None):
        self.jsonrpc = "2.0"
        self.id = id
        self.result = result
        self.error = error

    def to_dict(self) -> dict:
        d: dict = {"jsonrpc": self.jsonrpc, "id": self.id}
        if self.error:
            d["error"] = self.error
        else:
            d["result"] = self.result
        return d


# ---------------------------------------------------------------------------
# Elasticsearch helpers
# ---------------------------------------------------------------------------

def get_es_config() -> dict:
    return {
        "host": os.environ.get(
            "ES_HOST",
            "http://elasticsearch-master.sap-ai-services.svc.cluster.local:9200",
        ),
        "username": os.environ.get("ES_USERNAME", "elastic"),
        "password": os.environ.get("ES_PASSWORD", ""),
        "api_key": os.environ.get("ES_API_KEY", ""),
    }


def es_request(method: str, path: str, body: dict | None = None) -> Any:
    config = get_es_config()
    url = f"{config['host']}{path}"
    data = json.dumps(body).encode() if body else None
    headers: dict = {"Content-Type": "application/json"}
    if config["api_key"]:
        headers["Authorization"] = f"ApiKey {config['api_key']}"
    elif config["password"]:
        creds = base64.b64encode(
            f"{config['username']}:{config['password']}".encode()
        ).decode()
        headers["Authorization"] = f"Basic {creds}"

    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return json.loads(resp.read().decode())
    except urllib.error.HTTPError as e:
        try:
            body_text = e.read().decode()
        except Exception:
            body_text = ""
        return {"error": f"HTTP {e.code}: {e.reason}", "status_code": e.code, "detail": body_text}
    except Exception as e:
        return {"error": str(e)}


# ---------------------------------------------------------------------------
# AI Core helpers
# ---------------------------------------------------------------------------

def get_aicore_config() -> dict:
    return {
        "client_id": os.environ.get("AICORE_CLIENT_ID", ""),
        "client_secret": os.environ.get("AICORE_CLIENT_SECRET", ""),
        "auth_url": os.environ.get("AICORE_AUTH_URL", ""),
        "base_url": os.environ.get(
            "AICORE_BASE_URL", os.environ.get("AICORE_SERVICE_URL", "")
        ),
        "resource_group": os.environ.get("AICORE_RESOURCE_GROUP", "default"),
    }


def aicore_config_ready(config: dict) -> bool:
    return all(config.get(k) for k in ("client_id", "client_secret", "auth_url", "base_url"))


_cached_token: dict = {"token": None, "expires_at": 0.0}
_token_lock = threading.Lock()


def get_aicore_token(config: dict) -> str:
    """Return a valid AI Core OAuth token, refreshing if expired."""
    with _token_lock:
        if _cached_token["token"] and time.time() < _cached_token["expires_at"]:
            return _cached_token["token"]  # type: ignore[return-value]
        if not config["auth_url"]:
            return ""
        creds = base64.b64encode(
            f"{config['client_id']}:{config['client_secret']}".encode()
        ).decode()
        req = urllib.request.Request(
            config["auth_url"],
            data=b"grant_type=client_credentials",
            headers={
                "Authorization": f"Basic {creds}",
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


def aicore_request(method: str, path: str, body: dict | None = None) -> Any:
    config = get_aicore_config()
    token = get_aicore_token(config)
    if not token:
        return {"error": "No AI Core token available — check AICORE_* env vars"}
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


# ---------------------------------------------------------------------------
# MCP Server
# ---------------------------------------------------------------------------

# Allowlist of safe Elasticsearch Query DSL clause types.
_DSL_ALLOWED_TYPES: frozenset = frozenset({
    "match", "match_all", "match_phrase", "match_phrase_prefix",
    "multi_match", "common", "query_string", "simple_query_string",
    "term", "terms", "terms_set", "range", "exists", "prefix", "wildcard",
    "regexp", "fuzzy", "ids", "bool", "boosting", "constant_score",
    "dis_max", "nested", "has_child", "has_parent", "knn",
})

_DSL_COMPOUND_KEYS: frozenset = frozenset({"must", "should", "must_not", "filter", "queries"})


def _dsl_allowed(query: dict) -> bool:
    """Return False if the query uses any disallowed DSL clause type.

    Blocks: script, function_score, script_score, percolate, pinned,
    more_like_this, rank_feature, span_* and any unknown clause type.
    """
    if not isinstance(query, dict):
        return True
    for clause_type, clause_val in query.items():
        if clause_type not in _DSL_ALLOWED_TYPES:
            return False
        if clause_type in ("bool", "boosting", "constant_score",
                           "dis_max", "nested", "has_child", "has_parent"):
            if isinstance(clause_val, dict):
                for sub_key, sub_val in clause_val.items():
                    if sub_key in _DSL_COMPOUND_KEYS:
                        sub_queries = sub_val if isinstance(sub_val, list) else [sub_val]
                        for sq in sub_queries:
                            if isinstance(sq, dict) and not _dsl_allowed(sq):
                                return False
    return True


class MCPServer:
    def __init__(self) -> None:
        self._audit_lock = threading.Lock()
        self._invocation_count: int = 0
        self._tools = self._build_tools()
        self._resources = self._build_resources()

    # ------------------------------------------------------------------
    # Tool / resource registries
    # ------------------------------------------------------------------

    def _build_tools(self) -> dict:
        return {
            "es_search": {
                "name": "es_search",
                "description": "Search Elasticsearch indices using Query DSL.",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "index": {"type": "string", "description": "Index name or pattern (e.g. 'my-index' or 'logs-*')"},
                        "query": {"type": "string", "description": "Query DSL as JSON string (default: match_all)"},
                        "size": {"type": "number", "description": "Max results to return (1–100, default 10)"},
                    },
                    "required": ["index"],
                },
            },
            "es_vector_search": {
                "name": "es_vector_search",
                "description": "Perform kNN vector similarity search against a dense_vector field.",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "index": {"type": "string", "description": "Index name"},
                        "field": {"type": "string", "description": "Dense vector field name"},
                        "query_vector": {"type": "string", "description": "Query vector as JSON array of floats"},
                        "k": {"type": "number", "description": "Number of nearest neighbours (default 10)"},
                    },
                    "required": ["index", "field", "query_vector"],
                },
            },
            "es_index": {
                "name": "es_index",
                "description": "Index (create or overwrite) a document in Elasticsearch.",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "index": {"type": "string", "description": "Target index name"},
                        "document": {"type": "string", "description": "Document body as JSON object"},
                        "id": {"type": "string", "description": "Document ID (optional; auto-generated if omitted)"},
                    },
                    "required": ["index", "document"],
                },
            },
            "es_cluster_health": {
                "name": "es_cluster_health",
                "description": "Return Elasticsearch cluster health (green/yellow/red, node counts, shard counts).",
                "inputSchema": {"type": "object", "properties": {}},
            },
            "es_index_info": {
                "name": "es_index_info",
                "description": "Return mappings and settings for an index or index pattern.",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "index": {"type": "string", "description": "Index name or pattern"},
                    },
                    "required": ["index"],
                },
            },
            "generate_embedding": {
                "name": "generate_embedding",
                "description": (
                    "Generate a text embedding vector using the configured AI Core deployment. "
                    "Returns the raw AI Core response including the embedding array."
                ),
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "text": {"type": "string", "description": "Text to embed"},
                    },
                    "required": ["text"],
                },
            },
            "ai_semantic_search": {
                "name": "ai_semantic_search",
                "description": (
                    "End-to-end semantic search: embeds the natural-language query via AI Core "
                    "and runs a kNN search against the specified Elasticsearch index."
                ),
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "index": {"type": "string", "description": "Elasticsearch index to search"},
                        "query": {"type": "string", "description": "Natural language query string"},
                        "vector_field": {"type": "string", "description": "Dense vector field to search (default: 'embedding')"},
                        "k": {"type": "number", "description": "Number of nearest neighbours to return (default 10)"},
                    },
                    "required": ["index", "query"],
                },
            },
        }

    def _build_resources(self) -> dict:
        return {
            "es://cluster": {
                "uri": "es://cluster",
                "name": "Cluster Info",
                "description": "Elasticsearch cluster health and metadata",
                "mimeType": "application/json",
            },
            "es://indices": {
                "uri": "es://indices",
                "name": "Indices List",
                "description": "List of all Elasticsearch indices",
                "mimeType": "application/json",
            },
        }

    # ------------------------------------------------------------------
    # Audit
    # ------------------------------------------------------------------

    def _audit(self, tool: str, index: str = "", extra: dict | None = None) -> None:
        """Append an invocation record and best-effort persist to ES."""
        with self._audit_lock:
            self._invocation_count += 1

        entry: dict = {
            "tool": tool,
            "index": index,
            "timestamp": time.time(),
            "ts_iso": datetime.now(timezone.utc).isoformat(),
        }
        if extra:
            entry.update(extra)

        try:
            es_request("POST", "/sap_mcp_audit/_doc", entry)
        except Exception as exc:
            logger.debug("Audit persist failed (non-fatal): %s", exc)

    # ------------------------------------------------------------------
    # Embedding helper
    # ------------------------------------------------------------------

    def _resolve_embedding_deployment(self) -> tuple[str, dict | None]:
        """Return (deployment_id, error_dict).

        Prefers the explicit AICORE_EMBEDDING_DEPLOYMENT_ID env var.
        Falls back to discovering the first 'embed' deployment dynamically.
        """
        explicit_id = os.environ.get("AICORE_EMBEDDING_DEPLOYMENT_ID", "")
        if explicit_id:
            return explicit_id, None

        resp = aicore_request("GET", "/v2/lm/deployments")
        if "error" in resp:
            return "", {"error": f"Could not list AI Core deployments: {resp['error']}"}

        resources = resp.get("resources", [])
        embed_dep = next(
            (d for d in resources if "embed" in str(d.get("details", {})).lower()),
            None,
        )
        if embed_dep:
            logger.warning(
                "AICORE_EMBEDDING_DEPLOYMENT_ID not set; selected deployment '%s' via heuristic.",
                embed_dep.get("id", ""),
            )
            return embed_dep["id"], None

        if resources:
            logger.warning(
                "No embedding deployment found via heuristic; falling back to first deployment '%s'. "
                "Set AICORE_EMBEDDING_DEPLOYMENT_ID to silence this warning.",
                resources[0].get("id", ""),
            )
            return resources[0]["id"], None

        return "", {"error": "No AI Core deployment available; set AICORE_EMBEDDING_DEPLOYMENT_ID"}

    # ------------------------------------------------------------------
    # Tool handlers
    # ------------------------------------------------------------------

    def _handle_es_search(self, args: dict) -> dict:
        index = (args.get("index") or "*").strip()
        raw_query = args.get("query", '{"match_all": {}}')
        query = parse_json_arg(raw_query, {"match_all": {}})
        if not isinstance(query, dict):
            query = {"match_all": {}}
        if not _dsl_allowed(query):
            return {"error": "Query DSL contains a disallowed clause type (e.g. script, function_score)"}
        size = clamp_int(args.get("size", 10), 10, 1, MAX_SEARCH_SIZE)
        result = es_request("POST", f"/{index}/_search", {"query": query, "size": size})
        self._audit("es_search", index=index)
        return result

    def _handle_es_vector_search(self, args: dict) -> dict:
        index = (args.get("index") or "").strip()
        field = (args.get("field") or "embedding").strip()
        query_vector = parse_json_arg(args.get("query_vector", "[]"), [])
        if not isinstance(query_vector, list):
            return {"error": "query_vector must be a JSON array of floats"}
        k = clamp_int(args.get("k", 10), 10, 1, MAX_KNN_K)
        body = {
            "knn": {
                "field": field,
                "query_vector": query_vector,
                "k": k,
                "num_candidates": k * 2,
            }
        }
        result = es_request("POST", f"/{index}/_search", body)
        self._audit("es_vector_search", index=index)
        return result

    def _handle_es_index(self, args: dict) -> dict:
        index = (args.get("index") or "").strip()
        if not index:
            return {"error": "index is required"}
        document = parse_json_arg(args.get("document", "{}"), {})
        if not isinstance(document, dict):
            return {"error": "document must be a JSON object"}
        doc_id = args.get("id")
        self._audit("es_index", index=index)
        if doc_id:
            return es_request("PUT", f"/{index}/_doc/{doc_id}", document)
        return es_request("POST", f"/{index}/_doc", document)

    def _handle_es_cluster_health(self, _args: dict) -> dict:
        self._audit("es_cluster_health")
        return es_request("GET", "/_cluster/health")

    def _handle_es_index_info(self, args: dict) -> dict:
        index = (args.get("index") or "*").strip()
        self._audit("es_index_info", index=index)
        return es_request("GET", f"/{index}")

    def _handle_generate_embedding(self, args: dict) -> dict:
        text = str(args.get("text") or "").strip()
        if not text:
            return {"error": "text is required"}
        deployment_id, err = self._resolve_embedding_deployment()
        if err:
            return err
        result = aicore_request(
            "POST",
            f"/v2/inference/deployments/{deployment_id}/v1/embeddings",
            {"input": [text]},
        )
        self._audit("generate_embedding")
        return result

    def _handle_ai_semantic_search(self, args: dict) -> dict:
        index = (args.get("index") or "").strip()
        query_text = str(args.get("query") or "").strip()
        if not index:
            return {"error": "index is required"}
        if not query_text:
            return {"error": "query is required"}
        vector_field = (args.get("vector_field") or "embedding").strip()
        k = clamp_int(args.get("k", 10), 10, 1, MAX_KNN_K)

        embed_result = self._handle_generate_embedding({"text": query_text})
        if "error" in embed_result:
            return embed_result

        embedding = embed_result.get("data", [{}])[0].get("embedding", [])
        if not embedding:
            return {"error": "AI Core returned an empty embedding — check deployment configuration"}

        body = {
            "knn": {
                "field": vector_field,
                "query_vector": embedding,
                "k": k,
                "num_candidates": k * 2,
            },
            "_source": {"excludes": [vector_field]},
        }
        es_result = es_request("POST", f"/{index}/_search", body)
        self._audit("ai_semantic_search", index=index)
        return es_result

    # ------------------------------------------------------------------
    # Dispatch
    # ------------------------------------------------------------------

    _HANDLERS = {
        "es_search": "_handle_es_search",
        "es_vector_search": "_handle_es_vector_search",
        "es_index": "_handle_es_index",
        "es_cluster_health": "_handle_es_cluster_health",
        "es_index_info": "_handle_es_index_info",
        "generate_embedding": "_handle_generate_embedding",
        "ai_semantic_search": "_handle_ai_semantic_search",
    }

    def handle_request(self, request: MCPRequest) -> MCPResponse:
        method = request.method
        params = request.params
        rid = request.id

        try:
            if request.jsonrpc != "2.0":
                return MCPResponse(rid, error={"code": -32600, "message": "Invalid Request: jsonrpc must be '2.0'"})
            if not isinstance(params, dict):
                return MCPResponse(rid, error={"code": -32600, "message": "Invalid Request: params must be an object"})

            # ── initialize ────────────────────────────────────────────────
            if method == "initialize":
                return MCPResponse(rid, {
                    "protocolVersion": "2024-11-05",
                    "capabilities": {
                        "tools": {"listChanged": True},
                        "resources": {"listChanged": True},
                        "prompts": {"listChanged": True},
                    },
                    "serverInfo": {"name": "es-mcp", "version": "1.0.0"},
                })

            # ── tools/list ────────────────────────────────────────────────
            elif method == "tools/list":
                return MCPResponse(rid, {"tools": list(self._tools.values())})

            # ── tools/call ────────────────────────────────────────────────
            elif method == "tools/call":
                tool_name = params.get("name", "")
                args = params.get("arguments") or {}
                if not isinstance(args, dict):
                    return MCPResponse(rid, error={"code": -32602, "message": "arguments must be an object"})

                handler_name = self._HANDLERS.get(tool_name)
                if not handler_name:
                    return MCPResponse(rid, error={"code": -32602, "message": f"Unknown tool: {tool_name}"})

                result = getattr(self, handler_name)(args)
                return MCPResponse(rid, {
                    "content": [{"type": "text", "text": json.dumps(result, indent=2)}]
                })

            # ── resources/list ────────────────────────────────────────────
            elif method == "resources/list":
                return MCPResponse(rid, {"resources": list(self._resources.values())})

            # ── resources/read ────────────────────────────────────────────
            elif method == "resources/read":
                uri = params.get("uri", "")
                if uri == "es://cluster":
                    data = es_request("GET", "/_cluster/health")
                    return MCPResponse(rid, {
                        "contents": [{"uri": uri, "mimeType": "application/json",
                                      "text": json.dumps(data, indent=2)}]
                    })
                if uri == "es://indices":
                    data = es_request("GET", "/_cat/indices?format=json")
                    return MCPResponse(rid, {
                        "contents": [{"uri": uri, "mimeType": "application/json",
                                      "text": json.dumps(data, indent=2)}]
                    })
                return MCPResponse(rid, error={"code": -32602, "message": f"Unknown resource: {uri}"})

            else:
                return MCPResponse(rid, error={"code": -32601, "message": f"Method not found: {method}"})

        except Exception as exc:
            logger.exception("Unhandled error in handle_request")
            return MCPResponse(rid, error={"code": -32603, "message": str(exc)})


# ---------------------------------------------------------------------------
# HTTP handler
# ---------------------------------------------------------------------------

_mcp_server = MCPServer()


class MCPHandler(BaseHTTPRequestHandler):
    def _write_json(self, status: int, payload: dict) -> None:
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        origin = _cors_origin(self)
        if origin:
            self.send_header("Access-Control-Allow-Origin", origin)
        self.end_headers()
        self.wfile.write(body)

    def _reject(self, status: int, code: int, message: str) -> None:
        self._write_json(status, {
            "jsonrpc": "2.0", "id": None,
            "error": {"code": code, "message": message},
        })

    def do_OPTIONS(self) -> None:  # preflight
        self.send_response(204)
        origin = _cors_origin(self)
        if origin:
            self.send_header("Access-Control-Allow-Origin", origin)
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type, Authorization")
        self.end_headers()

    def do_GET(self) -> None:
        if self.path == "/health":
            aicore_cfg = get_aicore_config()
            self._write_json(200, {
                "status": "healthy",
                "service": "es-mcp",
                "timestamp": datetime.now(timezone.utc).isoformat(),
                "es_host": get_es_config()["host"],
                "aicore_config_ready": aicore_config_ready(aicore_cfg),
            })
        else:
            self._write_json(404, {"error": "Not found"})

    def do_POST(self) -> None:
        if self.path != "/mcp":
            self._write_json(404, {"error": "Not found"})
            return

        if not _authenticate(self):
            self._reject(401, -32600, "Unauthorized: valid Bearer token or ApiKey required")
            return

        content_length = int(self.headers.get("Content-Length", 0))
        if content_length <= 0:
            self._reject(400, -32600, "Invalid Request: empty body")
            return
        if content_length > MAX_REQUEST_BYTES:
            self._reject(413, -32600, "Request body too large")
            return

        raw = self.rfile.read(content_length)
        try:
            text = raw.decode("utf-8")
        except UnicodeDecodeError:
            self._reject(400, -32700, "Invalid UTF-8 body")
            return

        try:
            data = json.loads(text)
        except json.JSONDecodeError:
            self._reject(400, -32700, "Parse error: invalid JSON")
            return

        if not isinstance(data, dict):
            self._reject(400, -32600, "Invalid Request: body must be a JSON object")
            return

        request = MCPRequest(data)
        response = _mcp_server.handle_request(request)
        self._write_json(200, response.to_dict())

    def log_message(self, fmt: str, *args: Any) -> None:  # silence access log spam
        logger.debug(fmt, *args)


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main() -> None:
    import argparse
    parser = argparse.ArgumentParser(description="ES MCP Server")
    parser.add_argument("--port", type=int, default=int(os.environ.get("PORT", "9120")))
    args = parser.parse_args()

    server = HTTPServer(("", args.port), MCPHandler)
    es_cfg = get_es_config()
    aicore_cfg = get_aicore_config()
    print(
        f"\n"
        f"╔══════════════════════════════════════════════════════╗\n"
        f"║  ES MCP Server — Kyma / sap-ai-services              ║\n"
        f"║  Model Context Protocol v2024-11-05                  ║\n"
        f"╚══════════════════════════════════════════════════════╝\n"
        f"\n"
        f"  Listening : http://0.0.0.0:{args.port}\n"
        f"  ES host   : {es_cfg['host']}\n"
        f"  AI Core   : {'configured' if aicore_config_ready(aicore_cfg) else 'NOT configured'}\n"
        f"\n"
        f"  Tools     : es_search  es_vector_search  es_index\n"
        f"              es_cluster_health  es_index_info\n"
        f"              generate_embedding  ai_semantic_search\n"
        f"\n"
        f"  Resources : es://cluster  es://indices\n"
    )
    logger.info("ES MCP Server started on port %d", args.port)
    server.serve_forever()


if __name__ == "__main__":
    main()