"""
World Monitor MCP Server

Model Context Protocol server with Mangle reasoning integration.
Provides tools for monitoring and observability operations.
"""

import json
import os
from http.server import HTTPServer, BaseHTTPRequestHandler
from typing import Any
import urllib.request
from urllib.parse import urlparse

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
MAX_LOG_LIMIT = int(os.environ.get("MCP_MAX_LOG_LIMIT", "500"))
MAX_HEALTH_TIMEOUT = int(os.environ.get("MCP_MAX_HEALTH_TIMEOUT", "30"))
MAX_REFRESH_SERVICES = int(os.environ.get("MCP_MAX_REFRESH_SERVICES", "25"))


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
# MCP Server Implementation
# =============================================================================

class MCPServer:
    def __init__(self):
        self.tools = {}
        self.resources = {}
        self.facts = {}
        self.metrics = {}
        self._register_tools()
        self._register_resources()
        self._initialize_facts()

    def _register_tools(self):
        # Get Metrics
        self.tools["get_metrics"] = {
            "name": "get_metrics",
            "description": "Get monitoring metrics",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "namespace": {"type": "string", "description": "Metric namespace"},
                    "metric_name": {"type": "string", "description": "Specific metric name"},
                },
            },
        }

        # Record Metric
        self.tools["record_metric"] = {
            "name": "record_metric",
            "description": "Record a metric value",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "name": {"type": "string", "description": "Metric name"},
                    "value": {"type": "number", "description": "Metric value"},
                    "labels": {"type": "string", "description": "Labels as JSON object"},
                },
                "required": ["name", "value"],
            },
        }

        # Health Check
        self.tools["health_check"] = {
            "name": "health_check",
            "description": "Perform health check on a service",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "service_url": {"type": "string", "description": "Service URL to check"},
                    "timeout": {"type": "number", "description": "Timeout in seconds"},
                },
                "required": ["service_url"],
            },
        }

        # List Services
        self.tools["list_services"] = {
            "name": "list_services",
            "description": "List registered services",
            "inputSchema": {"type": "object", "properties": {}},
        }

        # Refresh Services
        self.tools["refresh_services"] = {
            "name": "refresh_services",
            "description": "Refresh health status for registered services",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "timeout": {"type": "number", "description": "Timeout in seconds for each health check"},
                    "limit": {"type": "number", "description": "Max number of services to refresh"},
                },
            },
        }

        # Get Alerts
        self.tools["get_alerts"] = {
            "name": "get_alerts",
            "description": "Get active alerts",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "severity": {"type": "string", "description": "Filter by severity (critical, warning, info)"},
                },
            },
        }

        # Create Alert
        self.tools["create_alert"] = {
            "name": "create_alert",
            "description": "Create an alert",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "name": {"type": "string", "description": "Alert name"},
                    "message": {"type": "string", "description": "Alert message"},
                    "severity": {"type": "string", "description": "Severity level"},
                },
                "required": ["name", "message"],
            },
        }

        # Get Logs
        self.tools["get_logs"] = {
            "name": "get_logs",
            "description": "Query logs",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "service": {"type": "string", "description": "Service name"},
                    "level": {"type": "string", "description": "Log level"},
                    "limit": {"type": "number", "description": "Max logs to return"},
                },
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
        self.resources["monitor://metrics"] = {
            "uri": "monitor://metrics",
            "name": "Metrics",
            "description": "Current metrics",
            "mimeType": "application/json",
        }
        self.resources["monitor://alerts"] = {
            "uri": "monitor://alerts",
            "name": "Alerts",
            "description": "Active alerts",
            "mimeType": "application/json",
        }
        self.resources["monitor://services"] = {
            "uri": "monitor://services",
            "name": "Services",
            "description": "Registered services",
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
            {"name": "ai-sdk-mcp", "endpoint": "http://localhost:9090/mcp", "health_url": "http://localhost:9090/health", "status": "unknown"},
            {"name": "cap-llm-mcp", "endpoint": "http://localhost:9100/mcp", "health_url": "http://localhost:9100/health", "status": "unknown"},
            {"name": "data-cleaning-mcp", "endpoint": "http://localhost:9110/mcp", "health_url": "http://localhost:9110/health", "status": "unknown"},
            {"name": "elasticsearch-mcp", "endpoint": "http://localhost:9120/mcp", "health_url": "http://localhost:9120/health", "status": "unknown"},
            {"name": "hana-toolkit-mcp", "endpoint": "http://localhost:9130/mcp", "health_url": "http://localhost:9130/health", "status": "unknown"},
            {"name": "langchain-mcp", "endpoint": "http://localhost:9140/mcp", "health_url": "http://localhost:9140/health", "status": "unknown"},
            {"name": "odata-vocab-mcp", "endpoint": "http://localhost:9150/mcp", "health_url": "http://localhost:9150/health", "status": "unknown"},
            {"name": "ui5-ngx-mcp", "endpoint": "http://localhost:9160/mcp", "health_url": "http://localhost:9160/health", "status": "unknown"},
            {"name": "world-monitor-mcp", "endpoint": "http://localhost:9170/mcp", "health_url": "http://localhost:9170/health", "status": "unknown"},
            {"name": "vllm-mcp", "endpoint": "http://localhost:9180/mcp", "health_url": "http://localhost:9180/health", "status": "unknown"},
            {"name": "ai-core-streaming-mcp", "endpoint": "http://localhost:9190/mcp", "health_url": "http://localhost:9190/health", "status": "unknown"},
            {"name": "ai-core-pal-mcp", "endpoint": "http://localhost:9881/mcp", "health_url": "http://localhost:9881/health", "status": "unknown"},
            {"name": "mangle-query-service", "endpoint": "grpc://localhost:50051", "status": "unchecked"},
        ]
        self.facts["alerts"] = []
        self.facts["tool_invocation"] = []
        self.metrics = {}

    # Tool Handlers
    def _handle_get_metrics(self, args: dict) -> dict:
        namespace = args.get("namespace", "")
        metric_name = args.get("metric_name", "")
        if namespace:
            filtered = {k: v for k, v in self.metrics.items() if k.startswith(namespace)}
            return {"namespace": namespace, "metrics": filtered}
        if metric_name:
            return {"metric": metric_name, "value": self.metrics.get(metric_name)}
        return {"metrics": self.metrics, "count": len(self.metrics)}

    def _handle_record_metric(self, args: dict) -> dict:
        name = args.get("name", "")
        value = args.get("value", 0)
        labels = parse_json_arg(args.get("labels", "{}"), {})
        if not isinstance(labels, dict):
            labels = {}
        import time
        self.metrics[name] = {"value": value, "labels": labels, "timestamp": time.time()}
        return {"name": name, "value": value, "status": "recorded"}

    def _handle_health_check(self, args: dict) -> dict:
        service_url = str(args.get("service_url", "") or "")
        timeout = clamp_int(args.get("timeout", 5), 5, 1, MAX_HEALTH_TIMEOUT)
        parsed = urlparse(service_url)
        if parsed.scheme not in ("http", "https") or not parsed.netloc:
            return {"url": service_url, "status": "invalid", "error": "service_url must be a valid http(s) URL"}
        try:
            req = urllib.request.Request(service_url, method="GET")
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                return {"url": service_url, "status": "healthy", "code": resp.status}
        except Exception as e:
            return {"url": service_url, "status": "unhealthy", "error": str(e)}

    def _handle_list_services(self, args: dict) -> dict:
        return {"services": self.facts["service_registry"], "count": len(self.facts["service_registry"])}

    def _derive_health_url(self, service: dict) -> str:
        explicit = service.get("health_url")
        if isinstance(explicit, str) and explicit.strip():
            return explicit
        endpoint = service.get("endpoint")
        if not isinstance(endpoint, str):
            return ""
        if endpoint.startswith("http://") or endpoint.startswith("https://"):
            if endpoint.endswith("/mcp"):
                return endpoint[:-4] + "/health"
            return endpoint.rstrip("/") + "/health"
        return ""

    def _handle_refresh_services(self, args: dict) -> dict:
        timeout = clamp_int(args.get("timeout", 3), 3, 1, MAX_HEALTH_TIMEOUT)
        limit = clamp_int(args.get("limit", len(self.facts["service_registry"])), len(self.facts["service_registry"]), 1, MAX_REFRESH_SERVICES)
        services = self.facts["service_registry"][:limit]

        import time
        healthy = 0
        unhealthy = 0
        unchecked = 0

        for service in services:
            health_url = self._derive_health_url(service)
            service["last_checked"] = time.time()

            if not health_url:
                service["status"] = "unchecked"
                service["error"] = "No HTTP health endpoint available"
                unchecked += 1
                continue

            result = self._handle_health_check({"service_url": health_url, "timeout": timeout})
            service["status"] = result.get("status", "unknown")
            service["health_url"] = health_url
            service["health_code"] = result.get("code")
            service["error"] = result.get("error")

            if service["status"] == "healthy":
                healthy += 1
            elif service["status"] == "unhealthy":
                unhealthy += 1
            else:
                unchecked += 1

        return {
            "services_refreshed": len(services),
            "healthy": healthy,
            "unhealthy": unhealthy,
            "unchecked": unchecked,
            "services": self.facts["service_registry"],
        }

    def _handle_get_alerts(self, args: dict) -> dict:
        severity = args.get("severity", "")
        alerts = self.facts["alerts"]
        if severity:
            alerts = [a for a in alerts if a.get("severity") == severity]
        return {"alerts": alerts, "count": len(alerts)}

    def _handle_create_alert(self, args: dict) -> dict:
        import time
        alert = {
            "name": args.get("name", ""),
            "message": args.get("message", ""),
            "severity": args.get("severity", "warning"),
            "timestamp": time.time(),
        }
        self.facts["alerts"].append(alert)
        return {"alert": alert, "status": "created"}

    def _handle_get_logs(self, args: dict) -> dict:
        limit = clamp_int(args.get("limit", 100), 100, 1, MAX_LOG_LIMIT)
        return {
            "service": args.get("service", "all"),
            "level": args.get("level", "all"),
            "limit": limit,
            "logs": [],
            "note": "Connect to actual log aggregator",
        }

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
                    "serverInfo": {"name": "world-monitor-mcp", "version": "1.0.0"},
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
                    "get_metrics": self._handle_get_metrics,
                    "record_metric": self._handle_record_metric,
                    "health_check": self._handle_health_check,
                    "list_services": self._handle_list_services,
                    "refresh_services": self._handle_refresh_services,
                    "get_alerts": self._handle_get_alerts,
                    "create_alert": self._handle_create_alert,
                    "get_logs": self._handle_get_logs,
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
                if uri == "monitor://metrics":
                    return MCPResponse(id, {"contents": [{"uri": uri, "mimeType": "application/json", "text": json.dumps(self.metrics, indent=2)}]})
                if uri == "monitor://alerts":
                    return MCPResponse(id, {"contents": [{"uri": uri, "mimeType": "application/json", "text": json.dumps(self.facts["alerts"], indent=2)}]})
                if uri == "monitor://services":
                    return MCPResponse(id, {"contents": [{"uri": uri, "mimeType": "application/json", "text": json.dumps(self.facts["service_registry"], indent=2)}]})
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
            response = {
                "status": "healthy",
                "service": "world-monitor-mcp",
                "timestamp": datetime.now(timezone.utc).isoformat(),
                "registered_services": len(mcp_server.facts.get("service_registry", [])),
                "active_alerts": len(mcp_server.facts.get("alerts", [])),
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
    port = 9170
    for arg in sys.argv[1:]:
        if arg.startswith("--port="):
            port = int(arg.split("=")[1])

    server = HTTPServer(("", port), MCPHandler)
    print(f"""
╔══════════════════════════════════════════════════════════╗
║   World Monitor MCP Server with Mangle Reasoning         ║
║   Model Context Protocol v2024-11-05                     ║
╚══════════════════════════════════════════════════════════╝

Server: http://localhost:{port}

Tools: get_metrics, record_metric, health_check, list_services, refresh_services,
       get_alerts, create_alert, get_logs, mangle_query

Resources: monitor://metrics, monitor://alerts, monitor://services, mangle://facts
""")
    server.serve_forever()


if __name__ == "__main__":
    main()
