# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2023 SAP SE
"""
LangChain HANA Integration MCP Server

Model Context Protocol server for LangChain + HANA vector workflows.
Provides tools for LangChain + HANA Cloud operations.
"""

import json
import os
from http.server import HTTPServer, BaseHTTPRequestHandler
from socketserver import ThreadingMixIn
from typing import Any
import re
import urllib.request
import urllib.error

# HANA Cloud connection settings (same env vars as deploy/aicore and sap_openai_server)
HANA_HOST = os.environ.get("HANA_HOST", "")
HANA_PORT = int(os.environ.get("HANA_PORT", "443"))
HANA_USER = os.environ.get("HANA_USER", "")
HANA_PASSWORD = os.environ.get("HANA_PASSWORD", "")
HANA_SCHEMA = os.environ.get("HANA_SCHEMA", "AINUCLEUS")

_SAFE_IDENTIFIER_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]{0,126}$")

_hana_connection = None
_hana_lock = None  # initialized lazily after threading import


def _sanitize_identifier(name: str) -> str:
    """Validate and return a safe SQL identifier, or raise ValueError."""
    name = name.strip()
    if not _SAFE_IDENTIFIER_RE.match(name):
        raise ValueError(f"Invalid SQL identifier: {name!r}")
    return name


def _get_hana_connection():
    """Lazy singleton HANA connection via hdbcli. Returns None if unavailable."""
    global _hana_connection, _hana_lock
    if not HANA_HOST:
        return None
    if _hana_connection is not None:
        return _hana_connection
    if _hana_lock is None:
        _hana_lock = threading.Lock()
    with _hana_lock:
        if _hana_connection is not None:
            return _hana_connection
        try:
            from hdbcli import dbapi
            _hana_connection = dbapi.connect(
                address=HANA_HOST,
                port=HANA_PORT,
                user=HANA_USER,
                password=HANA_PASSWORD,
                encrypt=True,
            )
            return _hana_connection
        except Exception:
            return None


CORS_ALLOWED_ORIGINS = [
    o.strip() for o in os.environ.get("CORS_ALLOWED_ORIGINS", "http://localhost:3000,http://127.0.0.1:3000").split(",")
    if o.strip()
]


def _cors_origin(handler: BaseHTTPRequestHandler) -> str | None:
    origin = (handler.headers.get("Origin") or "").strip()
    if origin and origin in CORS_ALLOWED_ORIGINS:
        return origin
    return CORS_ALLOWED_ORIGINS[0] if CORS_ALLOWED_ORIGINS else None


MCP_API_KEY = os.environ.get("MCP_API_KEY", "")
MAX_REQUEST_BYTES = int(os.environ.get("MCP_MAX_REQUEST_BYTES", str(1024 * 1024)))
MAX_TOOL_TOKENS = int(os.environ.get("MCP_MAX_TOOL_TOKENS", "8192"))
MAX_TOP_K = int(os.environ.get("MCP_MAX_TOP_K", "100"))
MAX_DOCS_PER_CALL = int(os.environ.get("MCP_MAX_DOCS_PER_CALL", "1000"))
MAX_CHUNK_SIZE = int(os.environ.get("MCP_MAX_CHUNK_SIZE", "4000"))
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


def _recursive_split(text: str, separators: list, chunk_size: int, overlap: int) -> list:
    """Recursively split text using decreasing separator granularity.

    Separator is preserved at the end of each part (e.g. splitting on ". "
    keeps the period+space attached to the preceding chunk) so no text is lost.
    """
    if len(text) <= chunk_size:
        return [text] if text.strip() else []

    sep = separators[0] if separators else ""
    remaining_seps = separators[1:] if len(separators) > 1 else [""]

    if not sep:
        # Base case: hard character split with overlap
        chunks = []
        step = max(chunk_size - overlap, 1)
        for i in range(0, len(text), step):
            chunk = text[i:i + chunk_size]
            if chunk.strip():
                chunks.append(chunk)
            if i + chunk_size >= len(text):
                break
        return chunks

    # Split then re-attach separator to each part so no text is lost.
    # "A. B. C" split on ". " → raw ["A", "B", "C"] → ["A. ", "B. ", "C"]
    raw_parts = text.split(sep)
    parts = []
    for i, p in enumerate(raw_parts):
        parts.append(p + sep if i < len(raw_parts) - 1 else p)

    chunks = []
    current = ""

    for part in parts:
        candidate = current + part
        if len(candidate) <= chunk_size:
            current = candidate
        else:
            if current.strip():
                chunks.append(current)
            # If this single part exceeds chunk_size, recurse with finer separator
            if len(part) > chunk_size:
                chunks.extend(_recursive_split(part, remaining_seps, chunk_size, overlap))
                current = ""
            else:
                # Start new chunk with overlap from previous
                if overlap > 0 and current:
                    tail = current[-overlap:]
                    current = tail + part if tail.strip() else part
                else:
                    current = part

    if current.strip():
        chunks.append(current)

    return chunks


import threading

_rerank_model = None
_rerank_model_name = os.environ.get("RERANK_MODEL", "cross-encoder/ms-marco-MiniLM-L-6-v2")
_rerank_lock = threading.Lock()


def _get_rerank_model():
    global _rerank_model
    if _rerank_model is not None:
        return _rerank_model
    with _rerank_lock:
        # Double-check after acquiring lock
        if _rerank_model is not None:
            return _rerank_model
        try:
            from sentence_transformers import CrossEncoder
            _rerank_model = CrossEncoder(_rerank_model_name)
            return _rerank_model
        except ImportError:
            return None
        except Exception:
            return None


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


def config_ready(config: dict) -> bool:
    return all(config.get(k) for k in ("client_id", "client_secret", "auth_url", "base_url"))


_cached_token = {"token": None, "expires_at": 0}
_token_lock = threading.Lock()


def get_access_token(config: dict) -> str:
    import time
    import base64
    if _cached_token["token"] and time.time() < _cached_token["expires_at"]:
        return _cached_token["token"]
    with _token_lock:
        # Double-check after acquiring lock
        if _cached_token["token"] and time.time() < _cached_token["expires_at"]:
            return _cached_token["token"]
        if not config["auth_url"]:
            return ""
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
        except Exception:
            return ""


def aicore_request(config: dict, method: str, path: str, body: dict = None) -> Any:
    token = get_access_token(config)
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
        self.local_mcp_endpoint = normalize_mcp_endpoint(
            os.environ.get("LANGCHAIN_MCP_ENDPOINT", f"http://localhost:{os.environ.get('MCP_PORT', '9140')}/mcp")
        )
        self.hana_mcp_endpoint = normalize_mcp_endpoint(
            os.environ.get("LANGCHAIN_HANA_MCP_ENDPOINT", "http://localhost:9130/mcp")
        )
        self.odata_mcp_endpoint = normalize_mcp_endpoint(
            os.environ.get("LANGCHAIN_ODATA_MCP_ENDPOINT", "http://localhost:9150/mcp")
        )
        self.remote_mcp_endpoints = get_remote_mcp_endpoints("LANGCHAIN_REMOTE_MCP_ENDPOINTS")
        self._register_tools()
        self._register_resources()
        self._initialize_facts()

    def _register_tools(self):
        # LLM Chat
        self.tools["langchain_chat"] = {
            "name": "langchain_chat",
            "description": "Chat completion via LangChain + HANA",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "messages": {"type": "string", "description": "JSON array of messages [{role, content}]"},
                    "model": {"type": "string", "description": "Model ID"},
                    "max_tokens": {"type": "number", "description": "Maximum tokens"},
                },
                "required": ["messages"],
            },
        }

        # Vector Store
        self.tools["langchain_vector_store"] = {
            "name": "langchain_vector_store",
            "description": "Create or get HANA vector store for LangChain",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "table_name": {"type": "string", "description": "Vector table name"},
                    "embedding_model": {"type": "string", "description": "Embedding model to use"},
                },
                "required": ["table_name"],
            },
        }

        # Add Documents
        self.tools["langchain_add_documents"] = {
            "name": "langchain_add_documents",
            "description": "Add documents to HANA vector store",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "table_name": {"type": "string", "description": "Vector table name"},
                    "documents": {"type": "string", "description": "JSON array of documents"},
                    "metadatas": {"type": "string", "description": "JSON array of metadata (optional)"},
                },
                "required": ["table_name", "documents"],
            },
        }

        # Similarity Search
        self.tools["langchain_similarity_search"] = {
            "name": "langchain_similarity_search",
            "description": "Similarity search in HANA vector store",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "table_name": {"type": "string", "description": "Vector table name"},
                    "query": {"type": "string", "description": "Search query"},
                    "k": {"type": "number", "description": "Number of results"},
                    "filter": {"type": "string", "description": "Metadata filter (JSON)"},
                },
                "required": ["table_name", "query"],
            },
        }

        # RAG Chain
        self.tools["langchain_rag_chain"] = {
            "name": "langchain_rag_chain",
            "description": "Run RAG chain with HANA retriever",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "query": {"type": "string", "description": "User query"},
                    "table_name": {"type": "string", "description": "Vector table for retrieval"},
                    "k": {"type": "number", "description": "Number of context docs"},
                },
                "required": ["query", "table_name"],
            },
        }

        # Embeddings
        self.tools["langchain_embeddings"] = {
            "name": "langchain_embeddings",
            "description": "Generate embeddings using LangChain",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "texts": {"type": "string", "description": "JSON array of texts"},
                    "model": {"type": "string", "description": "Embedding model"},
                },
                "required": ["texts"],
            },
        }

        # Document Loader
        self.tools["langchain_load_documents"] = {
            "name": "langchain_load_documents",
            "description": "Load documents using LangChain loaders",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "source": {"type": "string", "description": "Document source (file path, URL)"},
                    "loader_type": {"type": "string", "description": "Loader type (pdf, web, text)"},
                },
                "required": ["source"],
            },
        }

        # Text Splitter
        self.tools["langchain_split_text"] = {
            "name": "langchain_split_text",
            "description": "Split text using sentence-aware recursive splitter (paragraph → sentence → word boundaries)",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "text": {"type": "string", "description": "Text to split"},
                    "chunk_size": {"type": "number", "description": "Target chunk size in characters (default 1000, max 4000)"},
                    "chunk_overlap": {"type": "number", "description": "Overlap between chunks in characters (default 200)"},
                },
                "required": ["text"],
            },
        }

        # Cross-Encoder Reranking
        self.tools["rerank_results"] = {
            "name": "rerank_results",
            "description": "Rerank documents using cross-encoder for improved retrieval precision",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "query": {"type": "string", "description": "Search query"},
                    "documents": {"type": "string", "description": "JSON array of {content, score}"},
                    "top_k": {"type": "number", "description": "Max results to return (default 5)"},
                },
                "required": ["query", "documents"],
            },
        }

    def _register_resources(self):
        self.resources["langchain://vectorstores"] = {
            "uri": "langchain://vectorstores",
            "name": "Vector Stores",
            "description": "Available HANA vector stores",
            "mimeType": "application/json",
        }
        self.resources["langchain://chains"] = {
            "uri": "langchain://chains",
            "name": "Chains",
            "description": "Available LangChain chains",
            "mimeType": "application/json",
        }
        self.resources["langchain://governance-facts"] = {
            "uri": "langchain://governance-facts",
            "name": "Governance Facts",
            "description": "Local MCP service registry and vector-store metadata",
            "mimeType": "application/json",
        }

    def _initialize_facts(self):
        self.facts["service_registry"] = [
            {"name": "langchain-mcp", "endpoint": self.local_mcp_endpoint, "model": "langchain-hana-mcp"},
            {"name": "hana-toolkit-mcp", "endpoint": self.hana_mcp_endpoint, "model": "hana-ai-toolkit-mcp"},
            {"name": "odata-vocab-mcp", "endpoint": self.odata_mcp_endpoint, "model": "odata-vocab-mcp"},
            {"name": "langchain-chat", "endpoint": "lc://chat", "model": os.environ.get("LANGCHAIN_CHAT_MODEL", "claude-3.5-sonnet")},
            {"name": "langchain-vector", "endpoint": "lc://vector", "model": "hana-vector"},
            {"name": "langchain-rag", "endpoint": "lc://rag", "model": "rag-chain"},
            {"name": "langchain-embed", "endpoint": "lc://embed", "model": "text-embedding"},
        ]
        for idx, endpoint in enumerate(self.remote_mcp_endpoints):
            self.facts["service_registry"].append({"name": f"remote-mcp-{idx + 1}", "endpoint": endpoint, "model": "federated"})
        self.facts["tool_invocation"] = []
        self.facts["vector_stores"] = []

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
    def _handle_langchain_chat(self, args: dict) -> dict:
        config = get_config()
        if not config_ready(config):
            return {"error": "AI Core not configured"}
        messages = parse_json_arg(args.get("messages", "[]"), [])
        if not isinstance(messages, list) or len(messages) == 0:
            return {"error": "messages must be a non-empty JSON array"}
        max_tokens = clamp_int(args.get("max_tokens", 1024), 1024, 1, MAX_TOOL_TOKENS)
        deployment_id = os.environ.get("AICORE_CHAT_DEPLOYMENT_ID", "").strip()
        if not deployment_id:
            return {"error": "AICORE_CHAT_DEPLOYMENT_ID is not configured"}
        self.facts["tool_invocation"].append({"tool": "langchain_chat", "deployment": deployment_id, "timestamp": __import__("time").time()})
        return aicore_request(config, "POST", f"/v2/inference/deployments/{deployment_id}/chat/completions", {"messages": messages, "max_tokens": max_tokens})

    def _embed_texts(self, texts: list) -> list | None:
        """Embed texts via AI Core. Returns list of float vectors, or None on failure."""
        config = get_config()
        if not config_ready(config):
            return None
        deployment_id = os.environ.get("AICORE_EMBEDDING_DEPLOYMENT_ID", "").strip()
        if not deployment_id:
            return None
        result = aicore_request(config, "POST", f"/v2/inference/deployments/{deployment_id}/embeddings", {"input": texts})
        data = result.get("data")
        if not isinstance(data, list):
            return None
        return [item.get("embedding", []) for item in data if isinstance(item, dict)]

    def _handle_langchain_vector_store(self, args: dict) -> dict:
        table_name = str(args.get("table_name", "") or "").strip()
        if table_name == "":
            return {"error": "table_name is required"}
        embedding_model = str(args.get("embedding_model", "default") or "default")
        existing = next((v for v in self.facts["vector_stores"] if v.get("table_name") == table_name), None)
        if existing:
            existing["embedding_model"] = embedding_model
        else:
            self.facts["vector_stores"].append({"table_name": table_name, "embedding_model": embedding_model, "documents_added": 0})

        # L1 — try direct HANA connection
        conn = _get_hana_connection()
        if conn is not None:
            try:
                schema = _sanitize_identifier(HANA_SCHEMA)
                safe_table = _sanitize_identifier(table_name)
                cur = conn.cursor()
                try:
                    cur.execute(f'SELECT COUNT(*) FROM "{schema}"."{safe_table}"')
                    row_count = cur.fetchone()[0]
                finally:
                    cur.close()
                return {
                    "table_name": table_name,
                    "embedding_model": embedding_model,
                    "status": "created/retrieved",
                    "backend": "hana",
                    "row_count": row_count,
                }
            except ValueError as e:
                return {"error": str(e)}
            except Exception:
                pass  # fall through to local stub

        # L2 — local stub
        return {"table_name": table_name, "embedding_model": embedding_model, "status": "created/retrieved", "backend": "local"}

    def _handle_langchain_add_documents(self, args: dict) -> dict:
        docs = parse_json_arg(args.get("documents", "[]"), [])
        if not isinstance(docs, list):
            return {"error": "documents must be a JSON array"}
        table_name = str(args.get("table_name", "") or "").strip()
        if table_name == "":
            return {"error": "table_name is required"}

        total_documents = len(docs)
        documents_added = min(total_documents, MAX_DOCS_PER_CALL)
        docs = docs[:documents_added]

        # L1 — try federation
        delegation = self._federated_mcp_call(
            "hana_vector_add",
            {"table_name": table_name, "documents": json.dumps(docs)},
            preferred=[self.hana_mcp_endpoint],
        )
        if delegation:
            return {
                "table_name": table_name,
                "documents_added": documents_added,
                "truncated": total_documents > documents_added,
                "status": "federated",
                "source": delegation["source"],
                "result": delegation["result"],
            }

        # L2 — try direct HANA connection
        conn = _get_hana_connection()
        if conn is not None and documents_added > 0:
            try:
                schema = _sanitize_identifier(HANA_SCHEMA)
                safe_table = _sanitize_identifier(table_name)
                texts = [str(d.get("content", d) if isinstance(d, dict) else d) for d in docs]
                metadatas = [json.dumps(d.get("metadata", {})) if isinstance(d, dict) else "{}" for d in docs]
                embeddings = self._embed_texts(texts)
                if embeddings and len(embeddings) == len(texts):
                    sql = (
                        f'INSERT INTO "{schema}"."{safe_table}" '
                        f'("VEC_TEXT", "VEC_META", "VEC_VECTOR") '
                        f'VALUES (?, ?, TO_REAL_VECTOR(?))'
                    )
                    cur = conn.cursor()
                    try:
                        for i in range(len(texts)):
                            cur.execute(sql, (texts[i], metadatas[i], str(embeddings[i])))
                    finally:
                        cur.close()
                    for store in self.facts.get("vector_stores", []):
                        if store.get("table_name") == table_name:
                            store["documents_added"] = int(store.get("documents_added", 0)) + documents_added
                            break
                    return {
                        "table_name": table_name,
                        "documents_added": documents_added,
                        "truncated": total_documents > documents_added,
                        "status": "hana",
                    }
            except ValueError as e:
                return {"error": str(e)}
            except Exception:
                pass  # fall through to local stub

        # L3 — local stub
        for store in self.facts.get("vector_stores", []):
            if store.get("table_name") == table_name:
                store["documents_added"] = int(store.get("documents_added", 0)) + documents_added
                break
        return {
            "table_name": table_name,
            "documents_added": documents_added,
            "truncated": total_documents > documents_added,
            "status": "buffered-local",
        }

    def _handle_langchain_similarity_search(self, args: dict) -> dict:
        k = clamp_int(args.get("k", 4), 4, 1, MAX_TOP_K)
        table_name = str(args.get("table_name", "") or "").strip()
        query = str(args.get("query", "") or "")
        if table_name == "" or query.strip() == "":
            return {"error": "table_name and query are required"}

        # L1 — try federation
        delegation = self._federated_mcp_call(
            "hana_vector_search",
            {"table_name": table_name, "query": query, "top_k": k},
            preferred=[self.hana_mcp_endpoint],
        )
        if delegation:
            remote_result = delegation["result"]
            return {
                "table_name": table_name,
                "query": query,
                "k": k,
                "status": "federated",
                "source": delegation["source"],
                "result": remote_result,
            }

        # L2 — try direct HANA connection
        conn = _get_hana_connection()
        if conn is not None:
            try:
                schema = _sanitize_identifier(HANA_SCHEMA)
                safe_table = _sanitize_identifier(table_name)
                embeddings = self._embed_texts([query])
                if embeddings and len(embeddings) > 0:
                    query_vec = str(embeddings[0])
                    sql = (
                        f'SELECT TOP {int(k)} '
                        f'"VEC_TEXT", "VEC_META", '
                        f'COSINE_SIMILARITY("VEC_VECTOR", TO_REAL_VECTOR(?)) AS "SCORE" '
                        f'FROM "{schema}"."{safe_table}" '
                        f'ORDER BY "SCORE" DESC'
                    )
                    cur = conn.cursor()
                    try:
                        cur.execute(sql, (query_vec,))
                        rows = cur.fetchall()
                    finally:
                        cur.close()
                    results = []
                    for row in rows:
                        meta = {}
                        if row[1]:
                            try:
                                meta = json.loads(row[1])
                            except (json.JSONDecodeError, TypeError):
                                pass
                        results.append({"content": row[0], "metadata": meta, "score": float(row[2])})
                    return {
                        "table_name": table_name,
                        "query": query,
                        "k": k,
                        "results": results,
                        "status": "hana",
                    }
            except ValueError as e:
                return {"error": str(e)}
            except Exception:
                pass  # fall through to degraded

        # L3 — degraded stub
        return {"table_name": table_name, "query": query, "k": k, "results": [], "status": "degraded-no-remote"}

    def _handle_langchain_rag_chain(self, args: dict) -> dict:
        query = str(args.get("query", "") or "")
        table_name = str(args.get("table_name", "") or "").strip()
        top_k = clamp_int(args.get("k", 4), 4, 1, MAX_TOP_K)
        if query.strip() == "" or table_name == "":
            return {"error": "query and table_name are required"}

        delegation = self._federated_mcp_call(
            "hana_rag",
            {"query": query, "table_name": table_name, "top_k": top_k},
            preferred=[self.hana_mcp_endpoint],
        )
        if delegation:
            remote_result = delegation["result"]
            if isinstance(remote_result, dict):
                remote_result.setdefault("status", "federated")
                remote_result.setdefault("source", delegation["source"])
                base = remote_result
            else:
                base = {
                    "query": query,
                    "table_name": table_name,
                    "status": "federated",
                    "source": delegation["source"],
                    "result": remote_result,
                }
        else:
            search_result = self._handle_langchain_similarity_search({"table_name": table_name, "query": query, "k": top_k})
            fallback_context = search_result.get("result", search_result.get("results", []))
            if not isinstance(fallback_context, list):
                fallback_context = []
            search_status = search_result.get("status", "degraded-no-remote")

            # If we got real results (from HANA or federation), generate an answer via chat
            if fallback_context and search_status in ("hana", "federated"):
                context_text = "\n\n".join(
                    doc.get("content", "") if isinstance(doc, dict) else str(doc)
                    for doc in fallback_context
                )
                chat_result = self._handle_langchain_chat({
                    "messages": json.dumps([
                        {"role": "system", "content": f"Answer the user's question using ONLY the following context documents. If the context does not contain the answer, say so.\n\n{context_text}"},
                        {"role": "user", "content": query},
                    ]),
                    "max_tokens": MAX_TOOL_TOKENS,
                })
                answer = chat_result.get("content", chat_result.get("choices", [{}])[0].get("message", {}).get("content", "")) if not chat_result.get("error") else f"Retrieval succeeded but chat failed: {chat_result.get('error')}"
                base = {
                    "query": query,
                    "table_name": table_name,
                    "context_docs": fallback_context,
                    "answer": answer,
                    "status": f"rag-{search_status}",
                }
            else:
                base = {
                    "query": query,
                    "table_name": table_name,
                    "context_docs": fallback_context,
                    "answer": "No retrieval backend available; returning empty context.",
                    "status": "degraded-fallback",
                }

        return base

    def _handle_langchain_embeddings(self, args: dict) -> dict:
        config = get_config()
        if not config_ready(config):
            return {"error": "AI Core not configured"}
        texts = parse_json_arg(args.get("texts", "[]"), [])
        if not isinstance(texts, list):
            return {"error": "texts must be a JSON array"}
        if len(texts) > MAX_DOCS_PER_CALL:
            texts = texts[:MAX_DOCS_PER_CALL]
        deployment_id = os.environ.get("AICORE_EMBEDDING_DEPLOYMENT_ID", "").strip()
        if not deployment_id:
            return {"error": "AICORE_EMBEDDING_DEPLOYMENT_ID is not configured"}
        return aicore_request(config, "POST", f"/v2/inference/deployments/{deployment_id}/embeddings", {"input": texts})

    def _handle_langchain_load_documents(self, args: dict) -> dict:
        source = str(args.get("source", "") or "").strip()
        loader_type = str(args.get("loader_type", "auto") or "auto")
        if source == "":
            return {"error": "source is required"}

        delegation = self._federated_mcp_call(
            "get_rag_context",
            {"query": source, "include_annotations": loader_type != "text"},
            preferred=[self.odata_mcp_endpoint],
        )
        if delegation:
            return {
                "source": source,
                "loader_type": loader_type,
                "status": "federated",
                "federated_source": delegation["source"],
                "result": delegation["result"],
            }

        # Local file loading restricted to allowed directories (prevent path traversal)
        _allowed_dirs = [d.strip() for d in os.environ.get("MCP_ALLOWED_FILE_DIRS", "").split(",") if d.strip()]
        if os.path.isfile(source) and _allowed_dirs:
            resolved = os.path.realpath(source)
            if not any(resolved.startswith(os.path.realpath(d) + os.sep) for d in _allowed_dirs):
                return {"error": f"Access denied: '{source}' is outside allowed directories"}
            try:
                with open(resolved, "r", encoding="utf-8", errors="ignore") as f:
                    text = f.read(MAX_CHUNK_SIZE)
                return {
                    "source": source,
                    "loader_type": loader_type,
                    "documents": [{"content": text, "metadata": {"source": source}}],
                    "status": "loaded-local-file",
                }
            except OSError as e:
                return {"error": f"failed to read source file: {e}"}

        return {"source": source, "loader_type": loader_type, "documents": [], "status": "metadata-only"}

    def _handle_langchain_split_text(self, args: dict) -> dict:
        text = args.get("text", "")
        if not text:
            return {"chunks": 0, "chunk_size": 0, "overlap": 0, "texts": []}

        chunk_size = clamp_int(args.get("chunk_size", 1000), 1000, 1, MAX_CHUNK_SIZE)
        overlap = clamp_int(args.get("chunk_overlap", 200), 200, 0, chunk_size - 1)

        # Sentence-aware recursive splitting: try paragraph → sentence → word → char
        separators = ["\n\n", "\n", ". ", "! ", "? ", "; ", ", ", " ", ""]
        chunks = _recursive_split(text, separators, chunk_size, overlap)

        return {
            "chunks": len(chunks),
            "chunk_size": chunk_size,
            "overlap": overlap,
            "texts": chunks,
        }

    def _handle_rerank_results(self, args: dict) -> dict:
        query = str(args.get("query", "") or "").strip()
        if not query:
            return {"error": "query is required"}
        docs = parse_json_arg(args.get("documents", "[]"), [])
        if not isinstance(docs, list) or len(docs) == 0:
            return {"error": "documents must be a non-empty JSON array of {content, score}"}
        top_k = clamp_int(args.get("top_k", 5), 5, 1, MAX_TOP_K)

        model = _get_rerank_model()
        if model is None:
            # Graceful fallback: return documents in original order
            return {
                "documents": docs[:top_k],
                "reranked": False,
                "reason": "sentence-transformers not available",
            }

        pairs = []
        for doc in docs:
            content = doc.get("content", "") if isinstance(doc, dict) else str(doc)
            pairs.append((query, content))

        try:
            scores = model.predict(pairs)
            scored_docs = []
            for i, doc in enumerate(docs):
                entry = dict(doc) if isinstance(doc, dict) else {"content": str(doc)}
                entry["rerank_score"] = float(scores[i])
                entry["original_score"] = entry.get("score", 0)
                scored_docs.append(entry)
            scored_docs.sort(key=lambda d: d["rerank_score"], reverse=True)
            return {"documents": scored_docs[:top_k], "reranked": True}
        except Exception as e:
            return {
                "documents": docs[:top_k],
                "reranked": False,
                "reason": str(e),
            }

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
                    "serverInfo": {"name": "langchain-hana-mcp", "version": "1.0.0"},
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
                    "langchain_chat": self._handle_langchain_chat,
                    "langchain_vector_store": self._handle_langchain_vector_store,
                    "langchain_add_documents": self._handle_langchain_add_documents,
                    "langchain_similarity_search": self._handle_langchain_similarity_search,
                    "langchain_rag_chain": self._handle_langchain_rag_chain,
                    "langchain_embeddings": self._handle_langchain_embeddings,
                    "langchain_load_documents": self._handle_langchain_load_documents,
                    "langchain_split_text": self._handle_langchain_split_text,
                    "rerank_results": self._handle_rerank_results,
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
                if uri == "langchain://governance-facts":
                    return MCPResponse(id, {"contents": [{"uri": uri, "mimeType": "application/json", "text": json.dumps(self.facts, indent=2)}]})
                if uri == "langchain://vectorstores":
                    return MCPResponse(id, {"contents": [{"uri": uri, "mimeType": "application/json", "text": json.dumps(self.facts.get("vector_stores", []), indent=2)}]})
                return MCPResponse(id, error={"code": -32602, "message": f"Unknown resource: {uri}"})

            else:
                return MCPResponse(id, error={"code": -32601, "message": f"Method not found: {method}"})

        except Exception as e:
            return MCPResponse(id, error={"code": -32603, "message": str(e)})


# =============================================================================
# HTTP Server
# =============================================================================

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
            from datetime import datetime, timezone
            cfg = get_config()
            ready = config_ready(cfg)
            response = {
                "status": "healthy" if ready else "degraded",
                "service": "langchain-hana-mcp",
                "timestamp": datetime.now(timezone.utc).isoformat(),
                "config_ready": ready,
            }
            if not ready:
                response["config_error"] = "Missing one or more required AI Core environment variables"
            self._write_json(200, response)
        else:
            self._write_json(404, {"error": "Not found"})

    def _check_auth(self) -> bool:
        """Validate API key if MCP_API_KEY is configured. Returns True if authorized."""
        if not MCP_API_KEY:
            return True  # No key configured — allow (dev mode)
        auth = self.headers.get("Authorization", "")
        if auth == f"Bearer {MCP_API_KEY}":
            return True
        self._write_json(401, {"jsonrpc": "2.0", "id": None, "error": {"code": -32600, "message": "Unauthorized: invalid or missing API key"}})
        return False

    def do_POST(self):
        if not self._check_auth():
            return
        if self.path == "/mcp":
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
        pass


class ThreadedHTTPServer(ThreadingMixIn, HTTPServer):
    """Handle requests in separate threads for concurrent access."""
    daemon_threads = True


def main():
    import sys
    port = 9140
    for arg in sys.argv[1:]:
        if arg.startswith("--port="):
            port = int(arg.split("=")[1])

    server = ThreadedHTTPServer(("", port), MCPHandler)
    print(f"""
╔══════════════════════════════════════════════════════════╗
║   LangChain HANA Integration MCP Server                  ║
║   Model Context Protocol v2024-11-05                     ║
╚══════════════════════════════════════════════════════════╝

Server: http://localhost:{port}

Tools: langchain_chat, langchain_vector_store, langchain_add_documents,
       langchain_similarity_search, langchain_rag_chain, langchain_embeddings,
       langchain_load_documents, langchain_split_text, rerank_results

Resources: langchain://vectorstores, langchain://chains, langchain://governance-facts
""")
    server.serve_forever()


if __name__ == "__main__":
    main()
