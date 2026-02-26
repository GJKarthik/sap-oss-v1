"""
vLLM MCP Server

Model Context Protocol server with Mangle reasoning integration.
Provides tools for vLLM high-throughput LLM inference operations.
"""

import json
import os
from http.server import HTTPServer, BaseHTTPRequestHandler
from typing import Any
import urllib.request

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
# vLLM Configuration
# =============================================================================

def get_vllm_config() -> dict:
    return {
        "base_url": os.environ.get("VLLM_BASE_URL", "http://localhost:8000"),
        "api_key": os.environ.get("VLLM_API_KEY", ""),
    }


def vllm_request(method: str, path: str, body: dict = None) -> Any:
    config = get_vllm_config()
    url = f"{config['base_url']}{path}"
    data = json.dumps(body).encode() if body else None
    headers = {"Content-Type": "application/json"}
    if config["api_key"]:
        headers["Authorization"] = f"Bearer {config['api_key']}"
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=120) as resp:
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
        self.tools["vllm_chat"] = {
            "name": "vllm_chat",
            "description": "High-throughput chat completion via vLLM",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "messages": {"type": "string", "description": "JSON array of messages [{role, content}]"},
                    "model": {"type": "string", "description": "Model name"},
                    "max_tokens": {"type": "number", "description": "Maximum tokens"},
                    "temperature": {"type": "number", "description": "Sampling temperature"},
                },
                "required": ["messages"],
            },
        }

        # Text Completion
        self.tools["vllm_generate"] = {
            "name": "vllm_generate",
            "description": "Text generation/completion via vLLM",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "prompt": {"type": "string", "description": "Text prompt"},
                    "model": {"type": "string", "description": "Model name"},
                    "max_tokens": {"type": "number", "description": "Maximum tokens"},
                    "temperature": {"type": "number", "description": "Sampling temperature"},
                    "n": {"type": "number", "description": "Number of completions"},
                },
                "required": ["prompt"],
            },
        }

        # List Models
        self.tools["vllm_list_models"] = {
            "name": "vllm_list_models",
            "description": "List available models on vLLM server",
            "inputSchema": {"type": "object", "properties": {}},
        }

        # Get Model Info
        self.tools["vllm_model_info"] = {
            "name": "vllm_model_info",
            "description": "Get information about a specific model",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "model": {"type": "string", "description": "Model name"},
                },
                "required": ["model"],
            },
        }

        # Batch Inference
        self.tools["vllm_batch"] = {
            "name": "vllm_batch",
            "description": "Batch inference for multiple prompts",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "prompts": {"type": "string", "description": "JSON array of prompts"},
                    "model": {"type": "string", "description": "Model name"},
                    "max_tokens": {"type": "number", "description": "Maximum tokens per completion"},
                },
                "required": ["prompts"],
            },
        }

        # Embeddings
        self.tools["vllm_embed"] = {
            "name": "vllm_embed",
            "description": "Generate embeddings via vLLM",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "input": {"type": "string", "description": "Text or JSON array of texts to embed"},
                    "model": {"type": "string", "description": "Embedding model name"},
                },
                "required": ["input"],
            },
        }

        # Server Stats
        self.tools["vllm_stats"] = {
            "name": "vllm_stats",
            "description": "Get vLLM server statistics and metrics",
            "inputSchema": {"type": "object", "properties": {}},
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
        self.resources["vllm://models"] = {
            "uri": "vllm://models",
            "name": "Available Models",
            "description": "List of available vLLM models",
            "mimeType": "application/json",
        }
        self.resources["vllm://stats"] = {
            "uri": "vllm://stats",
            "name": "Server Stats",
            "description": "vLLM server statistics",
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
            {"name": "vllm-inference", "endpoint": "vllm://inference", "model": "vllm-engine"},
            {"name": "vllm-embed", "endpoint": "vllm://embed", "model": "embedding-engine"},
        ]
        self.facts["tool_invocation"] = []

    # Tool Handlers
    def _handle_vllm_chat(self, args: dict) -> dict:
        messages = json.loads(args.get("messages", "[]"))
        body = {
            "model": args.get("model", "default"),
            "messages": messages,
            "max_tokens": args.get("max_tokens", 1024),
        }
        if args.get("temperature"):
            body["temperature"] = args["temperature"]
        return vllm_request("POST", "/v1/chat/completions", body)

    def _handle_vllm_generate(self, args: dict) -> dict:
        body = {
            "model": args.get("model", "default"),
            "prompt": args.get("prompt", ""),
            "max_tokens": args.get("max_tokens", 256),
        }
        if args.get("temperature"):
            body["temperature"] = args["temperature"]
        if args.get("n"):
            body["n"] = args["n"]
        return vllm_request("POST", "/v1/completions", body)

    def _handle_vllm_list_models(self, args: dict) -> dict:
        return vllm_request("GET", "/v1/models")

    def _handle_vllm_model_info(self, args: dict) -> dict:
        model = args.get("model", "")
        return vllm_request("GET", f"/v1/models/{model}")

    def _handle_vllm_batch(self, args: dict) -> dict:
        prompts = json.loads(args.get("prompts", "[]"))
        results = []
        for prompt in prompts:
            body = {
                "model": args.get("model", "default"),
                "prompt": prompt,
                "max_tokens": args.get("max_tokens", 256),
            }
            results.append(vllm_request("POST", "/v1/completions", body))
        return {"results": results, "count": len(results)}

    def _handle_vllm_embed(self, args: dict) -> dict:
        input_data = args.get("input", "")
        try:
            input_data = json.loads(input_data)
        except:
            input_data = [input_data]
        body = {"model": args.get("model", "default"), "input": input_data}
        return vllm_request("POST", "/v1/embeddings", body)

    def _handle_vllm_stats(self, args: dict) -> dict:
        return vllm_request("GET", "/metrics")

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
                    "serverInfo": {"name": "vllm-mcp", "version": "1.0.0"},
                })

            elif method == "tools/list":
                return MCPResponse(id, {"tools": list(self.tools.values())})

            elif method == "tools/call":
                tool_name = params.get("name", "")
                args = params.get("arguments", {})
                handlers = {
                    "vllm_chat": self._handle_vllm_chat,
                    "vllm_generate": self._handle_vllm_generate,
                    "vllm_list_models": self._handle_vllm_list_models,
                    "vllm_model_info": self._handle_vllm_model_info,
                    "vllm_batch": self._handle_vllm_batch,
                    "vllm_embed": self._handle_vllm_embed,
                    "vllm_stats": self._handle_vllm_stats,
                    "mangle_query": self._handle_mangle_query,
                }
                handler = handlers.get(tool_name)
                if not handler:
                    return MCPResponse(id, error={"code": -32602, "message": f"Unknown tool: {tool_name}"})
                result = handler(args)
                import time
                self.facts["tool_invocation"].append({"tool": tool_name, "timestamp": time.time()})
                return MCPResponse(id, {"content": [{"type": "text", "text": json.dumps(result, indent=2)}]})

            elif method == "resources/list":
                return MCPResponse(id, {"resources": list(self.resources.values())})

            elif method == "resources/read":
                uri = params.get("uri", "")
                if uri == "vllm://models":
                    result = vllm_request("GET", "/v1/models")
                    return MCPResponse(id, {"contents": [{"uri": uri, "mimeType": "application/json", "text": json.dumps(result, indent=2)}]})
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
            response = {"status": "healthy", "service": "vllm-mcp", "timestamp": datetime.now(timezone.utc).isoformat()}
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
    port = 9180
    for arg in sys.argv[1:]:
        if arg.startswith("--port="):
            port = int(arg.split("=")[1])

    server = HTTPServer(("", port), MCPHandler)
    print(f"""
╔══════════════════════════════════════════════════════════╗
║   vLLM MCP Server with Mangle Reasoning                  ║
║   Model Context Protocol v2024-11-05                     ║
╚══════════════════════════════════════════════════════════╝

Server: http://localhost:{port}

Tools: vllm_chat, vllm_generate, vllm_list_models, vllm_model_info,
       vllm_batch, vllm_embed, vllm_stats, mangle_query

Resources: vllm://models, vllm://stats, mangle://facts
""")
    server.serve_forever()


if __name__ == "__main__":
    main()