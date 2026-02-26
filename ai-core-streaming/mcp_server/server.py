"""
AI Core Streaming MCP Server

Model Context Protocol server with Mangle reasoning integration.
Provides tools for streaming AI Core inference operations.
"""

import json
import os
from http.server import HTTPServer, BaseHTTPRequestHandler
from typing import Any
import urllib.request
import base64

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


def aicore_request(config: dict, method: str, path: str, body: dict = None, stream: bool = False) -> Any:
    token = get_access_token(config)
    if not token:
        return {"error": "No AI Core token"}
    url = f"{config['base_url']}{path}"
    data = json.dumps(body).encode() if body else None
    headers = {
        "Authorization": f"Bearer {token}",
        "AI-Resource-Group": config["resource_group"],
        "Content-Type": "application/json",
    }
    if stream:
        headers["Accept"] = "text/event-stream"
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
        self.streams = {}
        self._register_tools()
        self._register_resources()
        self._initialize_facts()

    def _register_tools(self):
        # Streaming Chat
        self.tools["streaming_chat"] = {
            "name": "streaming_chat",
            "description": "Stream chat completion from AI Core",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "messages": {"type": "string", "description": "JSON array of messages [{role, content}]"},
                    "model": {"type": "string", "description": "Model/deployment ID"},
                    "max_tokens": {"type": "number", "description": "Maximum tokens"},
                },
                "required": ["messages"],
            },
        }

        # Streaming Generate
        self.tools["streaming_generate"] = {
            "name": "streaming_generate",
            "description": "Stream text generation from AI Core",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "prompt": {"type": "string", "description": "Text prompt"},
                    "model": {"type": "string", "description": "Model/deployment ID"},
                    "max_tokens": {"type": "number", "description": "Maximum tokens"},
                },
                "required": ["prompt"],
            },
        }

        # List Deployments
        self.tools["list_deployments"] = {
            "name": "list_deployments",
            "description": "List available AI Core deployments",
            "inputSchema": {"type": "object", "properties": {}},
        }

        # Get Stream Status
        self.tools["stream_status"] = {
            "name": "stream_status",
            "description": "Get status of active streams",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "stream_id": {"type": "string", "description": "Stream ID (optional)"},
                },
            },
        }

        # Start Stream
        self.tools["start_stream"] = {
            "name": "start_stream",
            "description": "Start a new streaming session",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "deployment_id": {"type": "string", "description": "Deployment ID"},
                    "config": {"type": "string", "description": "Stream configuration as JSON"},
                },
                "required": ["deployment_id"],
            },
        }

        # Stop Stream
        self.tools["stop_stream"] = {
            "name": "stop_stream",
            "description": "Stop an active streaming session",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "stream_id": {"type": "string", "description": "Stream ID to stop"},
                },
                "required": ["stream_id"],
            },
        }

        # Event Stream Publish
        self.tools["publish_event"] = {
            "name": "publish_event",
            "description": "Publish an event to stream",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "stream_id": {"type": "string", "description": "Stream ID"},
                    "event_type": {"type": "string", "description": "Event type"},
                    "data": {"type": "string", "description": "Event data as JSON"},
                },
                "required": ["stream_id", "event_type", "data"],
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
        self.resources["streaming://deployments"] = {
            "uri": "streaming://deployments",
            "name": "Deployments",
            "description": "Available AI Core deployments",
            "mimeType": "application/json",
        }
        self.resources["streaming://active"] = {
            "uri": "streaming://active",
            "name": "Active Streams",
            "description": "Currently active streams",
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
            {"name": "streaming-chat", "endpoint": "streaming://chat", "model": "ai-core"},
            {"name": "streaming-generate", "endpoint": "streaming://generate", "model": "ai-core"},
        ]
        self.facts["tool_invocation"] = []
        self.facts["active_streams"] = []

    # Tool Handlers
    def _handle_streaming_chat(self, args: dict) -> dict:
        config = get_config()
        messages = json.loads(args.get("messages", "[]"))
        deployments = aicore_request(config, "GET", "/v2/lm/deployments")
        resources = deployments.get("resources", [])
        if not resources:
            return {"error": "No deployment available"}
        deployment = resources[0]
        is_anthropic = "anthropic" in str(deployment.get("details", {})).lower()
        import time
        self.facts["tool_invocation"].append({"tool": "streaming_chat", "deployment": deployment["id"], "timestamp": time.time()})
        if is_anthropic:
            result = aicore_request(config, "POST", f"/v2/inference/deployments/{deployment['id']}/invoke", {
                "anthropic_version": "bedrock-2023-05-31",
                "max_tokens": args.get("max_tokens", 1024),
                "messages": messages,
                "stream": True,
            })
            return {"content": result.get("content", [{}])[0].get("text", ""), "model": deployment["id"], "streaming": True}
        return aicore_request(config, "POST", f"/v2/inference/deployments/{deployment['id']}/chat/completions", {"messages": messages, "stream": True})

    def _handle_streaming_generate(self, args: dict) -> dict:
        config = get_config()
        prompt = args.get("prompt", "")
        deployments = aicore_request(config, "GET", "/v2/lm/deployments")
        resources = deployments.get("resources", [])
        if not resources:
            return {"error": "No deployment available"}
        deployment = resources[0]
        return aicore_request(config, "POST", f"/v2/inference/deployments/{deployment['id']}/completions", {"prompt": prompt, "stream": True, "max_tokens": args.get("max_tokens", 256)})

    def _handle_list_deployments(self, args: dict) -> dict:
        config = get_config()
        return aicore_request(config, "GET", "/v2/lm/deployments")

    def _handle_stream_status(self, args: dict) -> dict:
        stream_id = args.get("stream_id", "")
        if stream_id:
            stream = self.streams.get(stream_id)
            if stream:
                return {"stream_id": stream_id, **stream}
            return {"error": f"Stream {stream_id} not found"}
        return {"active_streams": list(self.streams.keys()), "count": len(self.streams)}

    def _handle_start_stream(self, args: dict) -> dict:
        import time
        import uuid
        stream_id = str(uuid.uuid4())[:8]
        config = json.loads(args.get("config", "{}"))
        self.streams[stream_id] = {
            "deployment_id": args.get("deployment_id", ""),
            "config": config,
            "started_at": time.time(),
            "status": "active",
            "events": [],
        }
        self.facts["active_streams"].append(stream_id)
        return {"stream_id": stream_id, "status": "started"}

    def _handle_stop_stream(self, args: dict) -> dict:
        stream_id = args.get("stream_id", "")
        if stream_id in self.streams:
            self.streams[stream_id]["status"] = "stopped"
            if stream_id in self.facts["active_streams"]:
                self.facts["active_streams"].remove(stream_id)
            return {"stream_id": stream_id, "status": "stopped"}
        return {"error": f"Stream {stream_id} not found"}

    def _handle_publish_event(self, args: dict) -> dict:
        import time
        stream_id = args.get("stream_id", "")
        if stream_id not in self.streams:
            return {"error": f"Stream {stream_id} not found"}
        event = {
            "type": args.get("event_type", ""),
            "data": json.loads(args.get("data", "{}")),
            "timestamp": time.time(),
        }
        self.streams[stream_id]["events"].append(event)
        return {"stream_id": stream_id, "event": event, "status": "published"}

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
                    "serverInfo": {"name": "ai-core-streaming-mcp", "version": "1.0.0"},
                })

            elif method == "tools/list":
                return MCPResponse(id, {"tools": list(self.tools.values())})

            elif method == "tools/call":
                tool_name = params.get("name", "")
                args = params.get("arguments", {})
                handlers = {
                    "streaming_chat": self._handle_streaming_chat,
                    "streaming_generate": self._handle_streaming_generate,
                    "list_deployments": self._handle_list_deployments,
                    "stream_status": self._handle_stream_status,
                    "start_stream": self._handle_start_stream,
                    "stop_stream": self._handle_stop_stream,
                    "publish_event": self._handle_publish_event,
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
                if uri == "streaming://active":
                    return MCPResponse(id, {"contents": [{"uri": uri, "mimeType": "application/json", "text": json.dumps(self.streams, indent=2)}]})
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
            response = {"status": "healthy", "service": "ai-core-streaming-mcp", "timestamp": datetime.now(timezone.utc).isoformat()}
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
    port = 9190
    for arg in sys.argv[1:]:
        if arg.startswith("--port="):
            port = int(arg.split("=")[1])

    server = HTTPServer(("", port), MCPHandler)
    print(f"""
╔══════════════════════════════════════════════════════════╗
║   AI Core Streaming MCP Server with Mangle Reasoning     ║
║   Model Context Protocol v2024-11-05                     ║
╚══════════════════════════════════════════════════════════╝

Server: http://localhost:{port}

Tools: streaming_chat, streaming_generate, list_deployments,
       stream_status, start_stream, stop_stream, publish_event,
       mangle_query

Resources: streaming://deployments, streaming://active, mangle://facts
""")
    server.serve_forever()


if __name__ == "__main__":
    main()