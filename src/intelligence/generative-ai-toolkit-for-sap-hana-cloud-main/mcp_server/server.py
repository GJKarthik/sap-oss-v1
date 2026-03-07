# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2024 SAP SE
"""
HANA AI Toolkit MCP Server

Model Context Protocol server with Mangle reasoning integration.
Provides tools for HANA Cloud AI operations: vector store, RAG, agents, memory.
"""

import json
import os
from http.server import HTTPServer, BaseHTTPRequestHandler
from typing import Any
import urllib.request
import urllib.error

MAX_REQUEST_BYTES = int(os.environ.get("MCP_MAX_REQUEST_BYTES", str(1024 * 1024)))
MAX_TOOL_TOKENS = int(os.environ.get("MCP_MAX_TOOL_TOKENS", "8192"))
MAX_TOP_K = int(os.environ.get("MCP_MAX_TOP_K", "100"))
MAX_DOCS_PER_CALL = int(os.environ.get("MCP_MAX_DOCS_PER_CALL", "1000"))
MAX_REMOTE_ENDPOINTS = int(os.environ.get("MCP_MAX_REMOTE_ENDPOINTS", "25"))
MAX_REMOTE_INDEX_DOCS = int(os.environ.get("MCP_MAX_REMOTE_INDEX_DOCS", "50"))
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


def config_ready(config: dict) -> bool:
    return all(config.get(k) for k in ("client_id", "client_secret", "auth_url", "base_url"))


_cached_token = {"token": None, "expires_at": 0}


def get_access_token(config: dict) -> str:
    import time
    import base64
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
    except:
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
            os.environ.get("HANA_TOOLKIT_MCP_ENDPOINT", f"http://localhost:{os.environ.get('MCP_PORT', '9130')}/mcp")
        )
        self.vector_mcp_endpoint = normalize_mcp_endpoint(
            os.environ.get("HANA_TOOLKIT_VECTOR_MCP_ENDPOINT", "http://localhost:9120/mcp")
        )
        self.agent_mcp_endpoint = normalize_mcp_endpoint(
            os.environ.get("HANA_TOOLKIT_AGENT_MCP_ENDPOINT", "http://localhost:9180/mcp")
        )
        self.remote_mcp_endpoints = get_remote_mcp_endpoints("HANA_TOOLKIT_REMOTE_MCP_ENDPOINTS")
        self._register_tools()
        self._register_resources()
        self._initialize_facts()

    def _register_tools(self):
        # Chat Completion
        self.tools["hana_chat"] = {
            "name": "hana_chat",
            "description": "Chat completion via HANA AI Toolkit",
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

        # Vector Store Operations
        self.tools["hana_vector_add"] = {
            "name": "hana_vector_add",
            "description": "Add documents to HANA vector store",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "table_name": {"type": "string", "description": "Vector table name"},
                    "documents": {"type": "string", "description": "JSON array of documents"},
                    "embeddings": {"type": "string", "description": "JSON array of embeddings (optional)"},
                },
                "required": ["table_name", "documents"],
            },
        }

        self.tools["hana_vector_search"] = {
            "name": "hana_vector_search",
            "description": "Search HANA vector store for similar documents",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "table_name": {"type": "string", "description": "Vector table name"},
                    "query": {"type": "string", "description": "Search query"},
                    "top_k": {"type": "number", "description": "Number of results"},
                },
                "required": ["table_name", "query"],
            },
        }

        # RAG
        self.tools["hana_rag"] = {
            "name": "hana_rag",
            "description": "Retrieval-Augmented Generation using HANA vector store",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "query": {"type": "string", "description": "User query"},
                    "table_name": {"type": "string", "description": "Vector table name"},
                    "top_k": {"type": "number", "description": "Number of context documents"},
                },
                "required": ["query", "table_name"],
            },
        }

        # Embeddings
        self.tools["hana_embed"] = {
            "name": "hana_embed",
            "description": "Generate embeddings",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "input": {"type": "string", "description": "Text to embed"},
                    "model": {"type": "string", "description": "Embedding model"},
                },
                "required": ["input"],
            },
        }

        # Agent
        self.tools["hana_agent_run"] = {
            "name": "hana_agent_run",
            "description": "Run an AI agent with tools",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "task": {"type": "string", "description": "Task description"},
                    "tools": {"type": "string", "description": "JSON array of tool names"},
                    "max_iterations": {"type": "number", "description": "Max agent iterations"},
                },
                "required": ["task"],
            },
        }

        # Memory
        self.tools["hana_memory_store"] = {
            "name": "hana_memory_store",
            "description": "Store data in HANA memory store",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "key": {"type": "string", "description": "Memory key"},
                    "value": {"type": "string", "description": "Value to store"},
                    "session_id": {"type": "string", "description": "Session ID"},
                },
                "required": ["key", "value"],
            },
        }

        self.tools["hana_memory_retrieve"] = {
            "name": "hana_memory_retrieve",
            "description": "Retrieve data from HANA memory store",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "key": {"type": "string", "description": "Memory key"},
                    "session_id": {"type": "string", "description": "Session ID"},
                },
                "required": ["key"],
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

    def _register_resources(self):
        self.resources["hana://tables"] = {
            "uri": "hana://tables",
            "name": "Vector Tables",
            "description": "List of HANA vector tables",
            "mimeType": "application/json",
        }
        self.resources["hana://memory"] = {
            "uri": "hana://memory",
            "name": "Memory Store",
            "description": "HANA memory store contents",
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
            {"name": "hana-toolkit-mcp", "endpoint": self.local_mcp_endpoint, "model": "hana-ai-toolkit-mcp"},
            {"name": "elasticsearch-mcp", "endpoint": self.vector_mcp_endpoint, "model": "vector-index"},
            {"name": "vllm-mcp", "endpoint": self.agent_mcp_endpoint, "model": "agent-inference"},
            {"name": "hana-chat", "endpoint": "hana://chat", "model": "claude-3.5-sonnet"},
            {"name": "hana-vector", "endpoint": "hana://vector", "model": "hana-vector-engine"},
            {"name": "hana-rag", "endpoint": "hana://rag", "model": "rag-pipeline"},
            {"name": "hana-agent", "endpoint": "hana://agent", "model": "agent-executor"},
        ]
        for idx, endpoint in enumerate(self.remote_mcp_endpoints):
            self.facts["service_registry"].append({"name": f"remote-mcp-{idx + 1}", "endpoint": endpoint, "model": "federated"})
        self.facts["tool_invocation"] = []
        self.facts["memory_store"] = {}

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
    def _handle_hana_chat(self, args: dict) -> dict:
        config = get_config()
        messages = parse_json_arg(args.get("messages", "[]"), [])
        if not isinstance(messages, list) or len(messages) == 0:
            return {"error": "messages must be a non-empty JSON array"}
        max_tokens = clamp_int(args.get("max_tokens", 1024), 1024, 1, MAX_TOOL_TOKENS)
        deployments = aicore_request(config, "GET", "/v2/lm/deployments")
        resources = deployments.get("resources", [])
        if not resources:
            return {"error": "No deployment available"}
        deployment = resources[0]
        is_anthropic = "anthropic" in str(deployment.get("details", {})).lower()
        self.facts["tool_invocation"].append({"tool": "hana_chat", "deployment": deployment["id"], "timestamp": __import__("time").time()})
        if is_anthropic:
            result = aicore_request(config, "POST", f"/v2/inference/deployments/{deployment['id']}/invoke", {
                "anthropic_version": "bedrock-2023-05-31",
                "max_tokens": max_tokens,
                "messages": messages,
            })
            return {"content": result.get("content", [{}])[0].get("text", ""), "model": deployment["id"]}
        result = aicore_request(config, "POST", f"/v2/inference/deployments/{deployment['id']}/chat/completions", {
            "messages": messages,
            "max_tokens": max_tokens,
        })
        return result

    def _handle_hana_vector_add(self, args: dict) -> dict:
        documents = parse_json_arg(args.get("documents", "[]"), [])
        if not isinstance(documents, list):
            return {"error": "documents must be a JSON array"}
        table_name = str(args.get("table_name", "") or "").strip()
        if table_name == "":
            return {"error": "table_name is required"}

        total_documents = len(documents)
        documents_added = min(total_documents, MAX_DOCS_PER_CALL)
        limited_documents = documents[:documents_added]
        indexed_documents = min(documents_added, MAX_REMOTE_INDEX_DOCS)

        indexed_count = 0
        federation_source = None
        for endpoint in self._iter_federated_mcp_endpoints([self.vector_mcp_endpoint]):
            current_indexed = 0
            for idx, document in enumerate(limited_documents[:indexed_documents]):
                doc_body = document if isinstance(document, dict) else {"text": str(document)}
                try:
                    call_mcp_tool(endpoint, "es_index", {"index": table_name, "id": f"{table_name}-{idx}", "document": json.dumps(doc_body)})
                    current_indexed += 1
                except Exception:
                    break
            if current_indexed > 0:
                indexed_count = current_indexed
                federation_source = endpoint
                break

        status = "federated" if indexed_count > 0 else "buffered-local"
        return {
            "table_name": table_name,
            "documents_added": documents_added,
            "indexed_remotely": indexed_count,
            "truncated": total_documents > documents_added,
            "status": status,
            "source": federation_source,
        }

    def _handle_hana_vector_search(self, args: dict) -> dict:
        top_k = clamp_int(args.get("top_k", 10), 10, 1, MAX_TOP_K)
        table_name = str(args.get("table_name", "") or "").strip()
        query = str(args.get("query", "") or "")
        if table_name == "" or query.strip() == "":
            return {"error": "table_name and query are required"}

        delegation = self._federated_mcp_call(
            "ai_semantic_search",
            {"index": table_name, "query": query, "k": top_k},
            preferred=[self.vector_mcp_endpoint],
        )
        if delegation:
            return {
                "table_name": table_name,
                "query": query,
                "top_k": top_k,
                "status": "federated",
                "source": delegation["source"],
                "result": delegation["result"],
            }

        return {"table_name": table_name, "query": query, "top_k": top_k, "results": [], "status": "degraded-no-remote"}

    def _handle_hana_rag(self, args: dict) -> dict:
        query = str(args.get("query", "") or "")
        table_name = str(args.get("table_name", "") or "").strip()
        top_k = clamp_int(args.get("top_k", 5), 5, 1, MAX_TOP_K)
        if query.strip() == "" or table_name == "":
            return {"error": "query and table_name are required"}

        search_result = self._handle_hana_vector_search({"table_name": table_name, "query": query, "top_k": top_k})
        context_docs = []
        if isinstance(search_result, dict):
            remote = search_result.get("result")
            if isinstance(remote, dict):
                hits = remote.get("hits", {})
                if isinstance(hits, dict):
                    raw_hits = hits.get("hits", [])
                    if isinstance(raw_hits, list):
                        context_docs = raw_hits[:top_k]

        if len(context_docs) == 0:
            return {
                "query": query,
                "table_name": table_name,
                "context_docs": [],
                "answer": "No context documents available from vector backend.",
                "status": "degraded-no-context",
            }

        prompt = "Use the provided context to answer the user query."
        chat_result = self._handle_hana_chat({
            "messages": json.dumps([
                {"role": "system", "content": prompt},
                {"role": "user", "content": f"Query: {query}\nContext: {json.dumps(context_docs)}"},
            ]),
            "max_tokens": 768,
        })
        answer = ""
        if isinstance(chat_result, dict):
            answer = str(chat_result.get("content", "")) or str(chat_result.get("choices", [{}])[0].get("message", {}).get("content", ""))

        return {
            "query": query,
            "table_name": table_name,
            "context_docs": context_docs,
            "answer": answer or "RAG response generated with retrieval context.",
            "status": "federated" if search_result.get("status") == "federated" else "degraded-fallback",
        }

    def _handle_hana_embed(self, args: dict) -> dict:
        config = get_config()
        input_text = str(args.get("input", "") or "")
        if input_text.strip() == "":
            return {"error": "input is required"}
        deployments = aicore_request(config, "GET", "/v2/lm/deployments")
        resources = deployments.get("resources", [])
        deployment = next((d for d in resources if "embed" in str(d.get("details", {})).lower()), resources[0] if resources else None)
        if not deployment:
            return {"error": "No embedding deployment"}
        return aicore_request(config, "POST", f"/v2/inference/deployments/{deployment['id']}/embeddings", {"input": [input_text]})

    def _handle_hana_agent_run(self, args: dict) -> dict:
        tools = parse_json_arg(args.get("tools", "[]"), [])
        if not isinstance(tools, list):
            return {"error": "tools must be a JSON array"}
        task = str(args.get("task", "") or "").strip()
        if task == "":
            return {"error": "task is required"}

        max_iterations = clamp_int(args.get("max_iterations", 3), 3, 1, MAX_TOP_K)
        delegation = self._federated_mcp_call(
            "vllm_chat",
            {
                "messages": json.dumps([
                    {"role": "system", "content": "You are an autonomous task execution agent."},
                    {"role": "user", "content": f"Task: {task}\nTools: {json.dumps(tools[:MAX_TOP_K])}\nMax iterations: {max_iterations}"},
                ]),
                "max_tokens": 1024,
            },
            preferred=[self.agent_mcp_endpoint],
        )
        if delegation:
            return {
                "task": task,
                "tools": tools[:MAX_TOP_K],
                "iterations": max_iterations,
                "status": "federated",
                "source": delegation["source"],
                "result": delegation["result"],
            }

        return {"task": task, "tools": tools[:MAX_TOP_K], "iterations": max_iterations, "status": "degraded-no-agent-backend"}

    def _handle_hana_memory_store(self, args: dict) -> dict:
        key = args.get("key", "")
        value = args.get("value", "")
        session_id = args.get("session_id", "default")
        if session_id not in self.facts["memory_store"]:
            self.facts["memory_store"][session_id] = {}
        self.facts["memory_store"][session_id][key] = value
        return {"key": key, "session_id": session_id, "status": "stored"}

    def _handle_hana_memory_retrieve(self, args: dict) -> dict:
        key = args.get("key", "")
        session_id = args.get("session_id", "default")
        value = self.facts["memory_store"].get(session_id, {}).get(key)
        return {"key": key, "session_id": session_id, "value": value, "found": value is not None}

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
            preferred=[self.vector_mcp_endpoint, self.agent_mcp_endpoint],
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
                    "capabilities": {"tools": {"listChanged": True}, "resources": {"listChanged": True}, "prompts": {"listChanged": True}},
                    "serverInfo": {"name": "hana-ai-toolkit-mcp", "version": "1.0.0"},
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
                    "hana_chat": self._handle_hana_chat,
                    "hana_vector_add": self._handle_hana_vector_add,
                    "hana_vector_search": self._handle_hana_vector_search,
                    "hana_rag": self._handle_hana_rag,
                    "hana_embed": self._handle_hana_embed,
                    "hana_agent_run": self._handle_hana_agent_run,
                    "hana_memory_store": self._handle_hana_memory_store,
                    "hana_memory_retrieve": self._handle_hana_memory_retrieve,
                    "mangle_query": self._handle_mangle_query,
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
                if uri == "hana://memory":
                    return MCPResponse(id, {"contents": [{"uri": uri, "mimeType": "application/json", "text": json.dumps(self.facts.get("memory_store", {}), indent=2)}]})
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
            from datetime import datetime, timezone
            cfg = get_config()
            ready = config_ready(cfg)
            response = {
                "status": "healthy" if ready else "degraded",
                "service": "hana-ai-toolkit-mcp",
                "timestamp": datetime.now(timezone.utc).isoformat(),
                "config_ready": ready,
            }
            if not ready:
                response["config_error"] = "Missing one or more required AI Core environment variables"
            self._write_json(200, response)
        else:
            self._write_json(404, {"error": "Not found"})

    def do_POST(self):
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


def main():
    import sys
    port = 9130
    for arg in sys.argv[1:]:
        if arg.startswith("--port="):
            port = int(arg.split("=")[1])

    server = HTTPServer(("", port), MCPHandler)
    print(f"""
╔══════════════════════════════════════════════════════════╗
║   HANA AI Toolkit MCP Server with Mangle Reasoning       ║
║   Model Context Protocol v2024-11-05                     ║
╚══════════════════════════════════════════════════════════╝

Server: http://localhost:{port}

Tools: hana_chat, hana_vector_add, hana_vector_search, hana_rag,
       hana_embed, hana_agent_run, hana_memory_store,
       hana_memory_retrieve, mangle_query

Resources: hana://tables, hana://memory, mangle://facts
""")
    server.serve_forever()


if __name__ == "__main__":
    main()
