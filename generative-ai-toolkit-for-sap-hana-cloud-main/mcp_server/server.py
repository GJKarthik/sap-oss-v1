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
            {"name": "hana-chat", "endpoint": "hana://chat", "model": "claude-3.5-sonnet"},
            {"name": "hana-vector", "endpoint": "hana://vector", "model": "hana-vector-engine"},
            {"name": "hana-rag", "endpoint": "hana://rag", "model": "rag-pipeline"},
            {"name": "hana-agent", "endpoint": "hana://agent", "model": "agent-executor"},
        ]
        self.facts["tool_invocation"] = []
        self.facts["memory_store"] = {}

    # Tool Handlers
    def _handle_hana_chat(self, args: dict) -> dict:
        config = get_config()
        messages = json.loads(args.get("messages", "[]"))
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
                "max_tokens": args.get("max_tokens", 1024),
                "messages": messages,
            })
            return {"content": result.get("content", [{}])[0].get("text", ""), "model": deployment["id"]}
        result = aicore_request(config, "POST", f"/v2/inference/deployments/{deployment['id']}/chat/completions", {
            "messages": messages,
            "max_tokens": args.get("max_tokens"),
        })
        return result

    def _handle_hana_vector_add(self, args: dict) -> dict:
        return {
            "table_name": args.get("table_name", ""),
            "documents_added": len(json.loads(args.get("documents", "[]"))),
            "status": "Placeholder - connect to HANA Cloud",
        }

    def _handle_hana_vector_search(self, args: dict) -> dict:
        return {
            "table_name": args.get("table_name", ""),
            "query": args.get("query", ""),
            "top_k": args.get("top_k", 10),
            "results": [],
            "status": "Placeholder - connect to HANA Cloud",
        }

    def _handle_hana_rag(self, args: dict) -> dict:
        return {
            "query": args.get("query", ""),
            "table_name": args.get("table_name", ""),
            "context_docs": [],
            "answer": "RAG pipeline placeholder - connect to HANA Cloud",
        }

    def _handle_hana_embed(self, args: dict) -> dict:
        config = get_config()
        input_text = args.get("input", "")
        deployments = aicore_request(config, "GET", "/v2/lm/deployments")
        resources = deployments.get("resources", [])
        deployment = next((d for d in resources if "embed" in str(d.get("details", {})).lower()), resources[0] if resources else None)
        if not deployment:
            return {"error": "No embedding deployment"}
        return aicore_request(config, "POST", f"/v2/inference/deployments/{deployment['id']}/embeddings", {"input": [input_text]})

    def _handle_hana_agent_run(self, args: dict) -> dict:
        return {
            "task": args.get("task", ""),
            "tools": json.loads(args.get("tools", "[]")),
            "iterations": 0,
            "result": "Agent placeholder - implement agent logic",
        }

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
        facts = self.facts.get(predicate)
        if facts:
            return {"predicate": predicate, "results": facts}
        return {"predicate": predicate, "results": [], "message": "Unknown predicate"}

    def handle_request(self, request: MCPRequest) -> MCPResponse:
        method = request.method
        params = request.params
        id = request.id

        try:
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


class MCPHandler(BaseHTTPRequestHandler):
    def do_OPTIONS(self):
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.end_headers()

    def do_GET(self):
        if self.path == "/health":
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Access-Control-Allow-Origin", "*")
            self.end_headers()
            from datetime import datetime, timezone
            response = {"status": "healthy", "service": "hana-ai-toolkit-mcp", "timestamp": datetime.now(timezone.utc).isoformat()}
            self.wfile.write(json.dumps(response).encode())
        else:
            self.send_response(404)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps({"error": "Not found"}).encode())

    def do_POST(self):
        if self.path == "/mcp":
            content_length = int(self.headers.get("Content-Length", 0))
            body = self.rfile.read(content_length).decode()
            try:
                data = json.loads(body)
                request = MCPRequest(data)
                response = mcp_server.handle_request(request)
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Access-Control-Allow-Origin", "*")
                self.end_headers()
                self.wfile.write(json.dumps(response.to_dict()).encode())
            except json.JSONDecodeError:
                self.send_response(400)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(json.dumps({"jsonrpc": "2.0", "id": None, "error": {"code": -32700, "message": "Parse error"}}).encode())
        else:
            self.send_response(404)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps({"error": "Not found"}).encode())

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