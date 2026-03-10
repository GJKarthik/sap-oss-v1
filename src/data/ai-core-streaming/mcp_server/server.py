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

try:
    from graph.kuzu_store import get_kuzu_store as _get_kuzu_store
except ImportError:
    try:
        from mcp_server.graph.kuzu_store import get_kuzu_store as _get_kuzu_store
    except ImportError:
        _get_kuzu_store = None  # type: ignore[assignment]

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
MAX_STREAM_EVENTS = int(os.environ.get("MCP_MAX_STREAM_EVENTS", "1000"))


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

        # Graph-RAG: index streaming entities into KùzuDB
        self.tools["kuzu_index"] = {
            "name": "kuzu_index",
            "description": (
                "Index AI Core streaming entities into the embedded KùzuDB graph database. "
                "Stores Deployment nodes, StreamSession nodes, RoutingDecision nodes, and their "
                "relationships (SERVED_BY, ROUTED_AS, HANDLES). "
                "Call before stream_status to enable graph-context enrichment."
            ),
            "inputSchema": {
                "type": "object",
                "properties": {
                    "deployments": {
                        "type": "string",
                        "description": (
                            "JSON array of deployment definitions: "
                            "[{deployment_id, model_name?, resource_group?, status?, "
                            "handles_decision?: string}]"
                        ),
                    },
                    "streams": {
                        "type": "string",
                        "description": (
                            "JSON array of stream session definitions: "
                            "[{stream_id, deployment_id?, status?, security_class?, "
                            "served_by?: string, routed_as?: string}]"
                        ),
                    },
                    "routing_decisions": {
                        "type": "string",
                        "description": (
                            "JSON array of routing decision definitions: "
                            "[{decision_id, security_class?, route?}]"
                        ),
                    },
                },
            },
        }

        # Graph-RAG: run a read-only Cypher query against KùzuDB
        self.tools["kuzu_query"] = {
            "name": "kuzu_query",
            "description": (
                "Execute a read-only Cypher query against the embedded KùzuDB graph database "
                "and return matching rows as JSON. "
                "Use for stream correlation, deployment lookup, routing analysis."
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
        import time
        self.facts["tool_invocation"].append({"tool": "streaming_chat", "deployment": deployment["id"], "timestamp": time.time()})
        if is_anthropic:
            result = aicore_request(config, "POST", f"/v2/inference/deployments/{deployment['id']}/invoke", {
                "anthropic_version": "bedrock-2023-05-31",
                "max_tokens": max_tokens,
                "messages": messages,
                "stream": True,
            })
            return {"content": result.get("content", [{}])[0].get("text", ""), "model": deployment["id"], "streaming": True}
        return aicore_request(
            config,
            "POST",
            f"/v2/inference/deployments/{deployment['id']}/chat/completions",
            {"messages": messages, "stream": True, "max_tokens": max_tokens},
        )

    def _handle_streaming_generate(self, args: dict) -> dict:
        config = get_config()
        prompt = str(args.get("prompt", "") or "")
        if prompt.strip() == "":
            return {"error": "prompt is required"}
        max_tokens = clamp_int(args.get("max_tokens", 256), 256, 1, MAX_TOOL_TOKENS)
        deployments = aicore_request(config, "GET", "/v2/lm/deployments")
        resources = deployments.get("resources", [])
        if not resources:
            return {"error": "No deployment available"}
        deployment = resources[0]
        return aicore_request(config, "POST", f"/v2/inference/deployments/{deployment['id']}/completions", {"prompt": prompt, "stream": True, "max_tokens": max_tokens})

    def _handle_list_deployments(self, args: dict) -> dict:
        config = get_config()
        return aicore_request(config, "GET", "/v2/lm/deployments")

    def _handle_stream_status(self, args: dict) -> dict:
        stream_id = args.get("stream_id", "")
        if stream_id:
            stream = self.streams.get(stream_id)
            if not stream:
                return {"error": f"Stream {stream_id} not found"}
            result = {"stream_id": stream_id, **stream}
            # M4 — attach graph context when KùzuDB has indexed data
            if _get_kuzu_store is not None:
                store = _get_kuzu_store()
                if store.available():
                    ctx = store.get_stream_context(stream_id)
                    if ctx:
                        result["graph_context"] = ctx
            return result

        # No stream_id — return all active streams with optional enrichment
        streams_out = []
        for sid, sdata in self.streams.items():
            entry = {"stream_id": sid, **sdata}
            if _get_kuzu_store is not None:
                store = _get_kuzu_store()
                if store.available():
                    ctx = store.get_stream_context(sid)
                    if ctx:
                        entry["graph_context"] = ctx
            streams_out.append(entry)
        return {"active_streams": streams_out, "count": len(streams_out)}

    def _handle_start_stream(self, args: dict) -> dict:
        import time
        import uuid
        stream_id = str(uuid.uuid4())[:8]
        config = parse_json_arg(args.get("config", "{}"), {})
        if not isinstance(config, dict):
            return {"error": "config must be a JSON object"}
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
        data = parse_json_arg(args.get("data", "{}"), {})
        if not isinstance(data, dict):
            return {"error": "data must be a JSON object"}
        if len(self.streams[stream_id]["events"]) >= MAX_STREAM_EVENTS:
            return {"error": f"Stream {stream_id} reached max events limit ({MAX_STREAM_EVENTS})"}
        event = {
            "type": args.get("event_type", ""),
            "data": data,
            "timestamp": time.time(),
        }
        self.streams[stream_id]["events"].append(event)
        return {"stream_id": stream_id, "event": event, "status": "published"}

    def _handle_kuzu_index(self, args: dict) -> dict:
        if _get_kuzu_store is None:
            return {"error": "KùzuDB not available; add 'kuzu>=0.7.0' to mcp_server/requirements.txt"}
        store = _get_kuzu_store()
        if not store.available():
            return {"error": "KùzuDB not installed; add 'kuzu>=0.7.0' to mcp_server/requirements.txt"}
        store.ensure_schema()

        deployments_indexed = 0
        streams_indexed = 0
        decisions_indexed = 0

        # Index routing decisions first (nodes referenced by others)
        raw_decisions = parse_json_arg(args.get("routing_decisions", "[]"), [])
        if not isinstance(raw_decisions, list):
            raw_decisions = []
        for rd in raw_decisions:
            if not isinstance(rd, dict):
                continue
            decision_id = str(rd.get("decision_id", "")).strip()
            if not decision_id:
                continue
            store.upsert_routing_decision(
                decision_id,
                security_class=str(rd.get("security_class", "public")),
                route=str(rd.get("route", "aicore")),
            )
            decisions_indexed += 1

        # Index deployments
        raw_deployments = parse_json_arg(args.get("deployments", "[]"), [])
        if not isinstance(raw_deployments, list):
            raw_deployments = []
        for dep in raw_deployments:
            if not isinstance(dep, dict):
                continue
            deployment_id = str(dep.get("deployment_id", "")).strip()
            if not deployment_id:
                continue
            store.upsert_deployment(
                deployment_id,
                model_name=str(dep.get("model_name", "")),
                resource_group=str(dep.get("resource_group", "default")),
                status=str(dep.get("status", "unknown")),
            )
            deployments_indexed += 1
            handles = str(dep.get("handles_decision", "")).strip()
            if handles:
                store.link_deployment_routing(deployment_id, handles)

        # Index stream sessions
        raw_streams = parse_json_arg(args.get("streams", "[]"), [])
        if not isinstance(raw_streams, list):
            raw_streams = []
        for ss in raw_streams:
            if not isinstance(ss, dict):
                continue
            stream_id = str(ss.get("stream_id", "")).strip()
            if not stream_id:
                continue
            store.upsert_stream(
                stream_id,
                deployment_id=str(ss.get("deployment_id", "")),
                status=str(ss.get("status", "active")),
                security_class=str(ss.get("security_class", "public")),
            )
            streams_indexed += 1
            served_by = str(ss.get("served_by", "") or ss.get("deployment_id", "")).strip()
            if served_by:
                store.link_session_deployment(stream_id, served_by)
            routed_as = str(ss.get("routed_as", "")).strip()
            if routed_as:
                store.link_session_routing(stream_id, routed_as)

        return {
            "deployments_indexed": deployments_indexed,
            "streams_indexed": streams_indexed,
            "decisions_indexed": decisions_indexed,
        }

    def _handle_kuzu_query(self, args: dict) -> dict:
        cypher = str(args.get("cypher", "") or "").strip()
        if not cypher:
            return {"error": "cypher is required"}
        upper = cypher.upper().lstrip()
        for disallowed in ("CREATE ", "MERGE ", "DELETE ", "SET ", "REMOVE ", "DROP "):
            if upper.startswith(disallowed):
                return {"error": "Write Cypher statements are not permitted via this tool"}
        params = parse_json_arg(args.get("params", "{}"), {})
        if not isinstance(params, dict):
            params = {}
        if _get_kuzu_store is None:
            return {"error": "KùzuDB not available; add 'kuzu>=0.7.0' to mcp_server/requirements.txt"}
        store = _get_kuzu_store()
        if not store.available():
            return {"error": "KùzuDB not installed; add 'kuzu>=0.7.0' to mcp_server/requirements.txt"}
        rows = store.run_query(cypher, params)
        return {"rows": rows, "row_count": len(rows)}

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
                    "serverInfo": {"name": "ai-core-streaming-mcp", "version": "1.0.0"},
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
                    "streaming_chat": self._handle_streaming_chat,
                    "streaming_generate": self._handle_streaming_generate,
                    "list_deployments": self._handle_list_deployments,
                    "stream_status": self._handle_stream_status,
                    "start_stream": self._handle_start_stream,
                    "stop_stream": self._handle_stop_stream,
                    "publish_event": self._handle_publish_event,
                    "mangle_query": self._handle_mangle_query,
                    "kuzu_index": self._handle_kuzu_index,
                    "kuzu_query": self._handle_kuzu_query,
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
                "service": "ai-core-streaming-mcp",
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
       mangle_query, kuzu_index, kuzu_query

Resources: streaming://deployments, streaming://active, mangle://facts
""")
    server.serve_forever()


if __name__ == "__main__":
    main()
