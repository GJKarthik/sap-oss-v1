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

CORS_ALLOWED_ORIGINS = [
    o.strip() for o in os.environ.get("CORS_ALLOWED_ORIGINS", "http://localhost:3000,http://127.0.0.1:3000").split(",")
    if o.strip()
]


def _cors_origin(handler: BaseHTTPRequestHandler) -> str | None:
    origin = (handler.headers.get("Origin") or "").strip()
    if origin and origin in CORS_ALLOWED_ORIGINS:
        return origin
    return CORS_ALLOWED_ORIGINS[0] if CORS_ALLOWED_ORIGINS else None


MAX_REQUEST_BYTES = int(os.environ.get("MCP_MAX_REQUEST_BYTES", str(1024 * 1024)))
MAX_TOOL_TOKENS = int(os.environ.get("MCP_MAX_TOOL_TOKENS", "8192"))
MAX_BATCH_SIZE = int(os.environ.get("MCP_MAX_BATCH_SIZE", "64"))


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


def clamp_float(value: Any, default: float, min_value: float, max_value: float) -> float:
    try:
        parsed = float(value)
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


def config_ready(config: dict) -> bool:
    return bool(config.get("base_url"))


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
        messages = parse_json_arg(args.get("messages", "[]"), [])
        if not isinstance(messages, list) or len(messages) == 0:
            return {"error": "messages must be a non-empty JSON array"}
        body = {
            "model": args.get("model", "default"),
            "messages": messages,
            "max_tokens": clamp_int(args.get("max_tokens", 1024), 1024, 1, MAX_TOOL_TOKENS),
        }
        if args.get("temperature"):
            body["temperature"] = clamp_float(args["temperature"], 0.7, 0.0, 2.0)
        return vllm_request("POST", "/v1/chat/completions", body)

    def _handle_vllm_generate(self, args: dict) -> dict:
        body = {
            "model": args.get("model", "default"),
            "prompt": args.get("prompt", ""),
            "max_tokens": clamp_int(args.get("max_tokens", 256), 256, 1, MAX_TOOL_TOKENS),
        }
        if args.get("temperature"):
            body["temperature"] = clamp_float(args["temperature"], 0.7, 0.0, 2.0)
        if args.get("n"):
            body["n"] = clamp_int(args["n"], 1, 1, 16)
        return vllm_request("POST", "/v1/completions", body)

    def _handle_vllm_list_models(self, args: dict) -> dict:
        return vllm_request("GET", "/v1/models")

    def _handle_vllm_model_info(self, args: dict) -> dict:
        model = args.get("model", "")
        return vllm_request("GET", f"/v1/models/{model}")

    def _handle_vllm_batch(self, args: dict) -> dict:
        prompts = parse_json_arg(args.get("prompts", "[]"), [])
        if not isinstance(prompts, list):
            return {"error": "prompts must be a JSON array"}
        prompts = prompts[:MAX_BATCH_SIZE]
        results = []
        for prompt in prompts:
            body = {
                "model": args.get("model", "default"),
                "prompt": prompt,
                "max_tokens": clamp_int(args.get("max_tokens", 256), 256, 1, MAX_TOOL_TOKENS),
            }
            results.append(vllm_request("POST", "/v1/completions", body))
        return {"results": results, "count": len(results)}

    def _handle_vllm_embed(self, args: dict) -> dict:
        input_data = parse_json_arg(args.get("input", ""), [args.get("input", "")])
        if isinstance(input_data, str):
            input_data = [input_data]
        if not isinstance(input_data, list):
            return {"error": "input must be a string or JSON array"}
        input_data = input_data[:MAX_BATCH_SIZE]
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
            if request.jsonrpc != "2.0":
                return MCPResponse(id, error={"code": -32600, "message": "Invalid Request: jsonrpc must be '2.0'"})
            if not isinstance(params, dict):
                return MCPResponse(id, error={"code": -32600, "message": "Invalid Request: params must be an object"})

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
                if args is None:
                    args = {}
                if not isinstance(args, dict):
                    return MCPResponse(id, error={"code": -32602, "message": "Invalid params: arguments must be an object"})
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
            cfg = get_vllm_config()
            ready = config_ready(cfg)
            response = {
                "status": "healthy" if ready else "degraded",
                "service": "vllm-mcp",
                "timestamp": datetime.now(timezone.utc).isoformat(),
                "config_ready": ready,
            }
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
