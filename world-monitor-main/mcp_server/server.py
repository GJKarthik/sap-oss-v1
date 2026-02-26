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
            {"name": "ai-sdk-mcp", "endpoint": "http://localhost:9090/mcp", "status": "unknown"},
            {"name": "cap-llm-mcp", "endpoint": "http://localhost:9100/mcp", "status": "unknown"},
            {"name": "data-cleaning-mcp", "endpoint": "http://localhost:9110/mcp", "status": "unknown"},
            {"name": "elasticsearch-mcp", "endpoint": "http://localhost:9120/mcp", "status": "unknown"},
            {"name": "hana-toolkit-mcp", "endpoint": "http://localhost:9130/mcp", "status": "unknown"},
            {"name": "langchain-mcp", "endpoint": "http://localhost:9140/mcp", "status": "unknown"},
            {"name": "odata-vocab-mcp", "endpoint": "http://localhost:9150/mcp", "status": "unknown"},
            {"name": "ui5-ngx-mcp", "endpoint": "http://localhost:9160/mcp", "status": "unknown"},
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
        labels = json.loads(args.get("labels", "{}"))
        import time
        self.metrics[name] = {"value": value, "labels": labels, "timestamp": time.time()}
        return {"name": name, "value": value, "status": "recorded"}

    def _handle_health_check(self, args: dict) -> dict:
        service_url = args.get("service_url", "")
        timeout = args.get("timeout", 5)
        try:
            req = urllib.request.Request(service_url, method="GET")
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                return {"url": service_url, "status": "healthy", "code": resp.status}
        except Exception as e:
            return {"url": service_url, "status": "unhealthy", "error": str(e)}

    def _handle_list_services(self, args: dict) -> dict:
        return {"services": self.facts["service_registry"], "count": len(self.facts["service_registry"])}

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
        return {
            "service": args.get("service", "all"),
            "level": args.get("level", "all"),
            "limit": args.get("limit", 100),
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
                handlers = {
                    "get_metrics": self._handle_get_metrics,
                    "record_metric": self._handle_record_metric,
                    "health_check": self._handle_health_check,
                    "list_services": self._handle_list_services,
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
            response = {"status": "healthy", "service": "world-monitor-mcp", "timestamp": datetime.now(timezone.utc).isoformat()}
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

Tools: get_metrics, record_metric, health_check, list_services,
       get_alerts, create_alert, get_logs, mangle_query

Resources: monitor://metrics, monitor://alerts, monitor://services, mangle://facts
""")
    server.serve_forever()


if __name__ == "__main__":
    main()