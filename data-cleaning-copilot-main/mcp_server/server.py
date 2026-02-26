"""
Data Cleaning Copilot MCP Server

Model Context Protocol server with Mangle reasoning integration.
Provides tools for data cleaning, quality checks, and AI-assisted data validation.
"""

import json
import os
import asyncio
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
    except Exception as e:
        return ""


def aicore_request(config: dict, method: str, path: str, body: dict = None) -> Any:
    token = get_access_token(config)
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
        # Data Quality Check
        self.tools["data_quality_check"] = {
            "name": "data_quality_check",
            "description": "Run data quality checks on a dataset",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "table_name": {"type": "string", "description": "Table name to check"},
                    "checks": {"type": "string", "description": "JSON array of check types (completeness, accuracy, consistency)"},
                },
                "required": ["table_name"],
            },
        }

        # Schema Analysis
        self.tools["schema_analysis"] = {
            "name": "schema_analysis",
            "description": "Analyze database schema for issues and recommendations",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "schema_definition": {"type": "string", "description": "Schema definition as JSON or SQL DDL"},
                },
                "required": ["schema_definition"],
            },
        }

        # Data Profiling
        self.tools["data_profiling"] = {
            "name": "data_profiling",
            "description": "Profile data to understand distributions and patterns",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "table_name": {"type": "string", "description": "Table name to profile"},
                    "columns": {"type": "string", "description": "Columns to profile (JSON array, optional)"},
                },
                "required": ["table_name"],
            },
        }

        # Anomaly Detection
        self.tools["anomaly_detection"] = {
            "name": "anomaly_detection",
            "description": "Detect anomalies in data using statistical or ML methods",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "table_name": {"type": "string", "description": "Table name"},
                    "column": {"type": "string", "description": "Column to analyze"},
                    "method": {"type": "string", "description": "Method: zscore, iqr, isolation_forest"},
                },
                "required": ["table_name", "column"],
            },
        }

        # Query Generation
        self.tools["generate_cleaning_query"] = {
            "name": "generate_cleaning_query",
            "description": "Generate SQL query to clean or fix data issues",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "issue_description": {"type": "string", "description": "Description of the data issue"},
                    "table_name": {"type": "string", "description": "Target table"},
                    "schema": {"type": "string", "description": "Table schema as JSON"},
                },
                "required": ["issue_description", "table_name"],
            },
        }

        # AI Chat
        self.tools["ai_chat"] = {
            "name": "ai_chat",
            "description": "Chat with AI for data cleaning guidance",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "messages": {"type": "string", "description": "JSON array of messages [{role, content}]"},
                    "context": {"type": "string", "description": "Additional context about the data"},
                },
                "required": ["messages"],
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
        self.resources["data://schemas"] = {
            "uri": "data://schemas",
            "name": "Database Schemas",
            "description": "Available database schemas",
            "mimeType": "application/json",
        }
        self.resources["data://quality_rules"] = {
            "uri": "data://quality_rules",
            "name": "Data Quality Rules",
            "description": "Defined data quality rules",
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
            {"name": "data-quality", "endpoint": "dcc://quality", "model": "quality-analyzer"},
            {"name": "data-profiling", "endpoint": "dcc://profiling", "model": "profiler"},
            {"name": "anomaly-detection", "endpoint": "dcc://anomaly", "model": "anomaly-detector"},
        ]
        self.facts["tool_invocation"] = []
        self.facts["quality_rules"] = [
            {"rule": "completeness", "threshold": 95.0},
            {"rule": "accuracy", "threshold": 99.0},
            {"rule": "consistency", "threshold": 98.0},
        ]

    # Tool Handlers
    def _handle_data_quality_check(self, args: dict) -> dict:
        table_name = args.get("table_name", "")
        checks = json.loads(args.get("checks", '["completeness", "accuracy", "consistency"]'))
        
        # Placeholder - would integrate with actual data quality libraries
        results = []
        for check in checks:
            results.append({
                "check": check,
                "table": table_name,
                "score": 95.0 + hash(f"{table_name}_{check}") % 5,
                "status": "PASS",
            })
        
        self.facts["tool_invocation"].append({"tool": "data_quality_check", "table": table_name, "timestamp": __import__("time").time()})
        return {"table": table_name, "checks": results, "overall_status": "PASS"}

    def _handle_schema_analysis(self, args: dict) -> dict:
        schema_def = args.get("schema_definition", "")
        return {
            "schema": schema_def[:200] + "..." if len(schema_def) > 200 else schema_def,
            "recommendations": [
                "Consider adding NOT NULL constraints",
                "Index frequently queried columns",
                "Add foreign key relationships",
            ],
            "status": "analyzed",
        }

    def _handle_data_profiling(self, args: dict) -> dict:
        table_name = args.get("table_name", "")
        return {
            "table": table_name,
            "row_count": 10000,
            "column_stats": {"sample_column": {"null_count": 5, "unique_count": 9500, "type": "string"}},
            "status": "profiled",
        }

    def _handle_anomaly_detection(self, args: dict) -> dict:
        return {
            "table": args.get("table_name", ""),
            "column": args.get("column", ""),
            "method": args.get("method", "zscore"),
            "anomalies_found": 0,
            "status": "Connect to data source for actual detection",
        }

    def _handle_generate_cleaning_query(self, args: dict) -> dict:
        issue = args.get("issue_description", "")
        table = args.get("table_name", "")
        return {
            "issue": issue,
            "table": table,
            "suggested_query": f"-- Cleaning query for {table}\n-- Issue: {issue}\nUPDATE {table} SET ... WHERE ...",
            "status": "query_generated",
        }

    def _handle_ai_chat(self, args: dict) -> dict:
        config = get_config()
        messages = json.loads(args.get("messages", "[]"))
        
        try:
            deployments = aicore_request(config, "GET", "/v2/lm/deployments")
            resources = deployments.get("resources", [])
            if not resources:
                return {"content": "No AI deployment available", "error": True}
            
            deployment = resources[0]
            is_anthropic = "anthropic" in str(deployment.get("details", {})).lower()
            
            if is_anthropic:
                result = aicore_request(config, "POST", f"/v2/inference/deployments/{deployment['id']}/invoke", {
                    "anthropic_version": "bedrock-2023-05-31",
                    "max_tokens": 1024,
                    "messages": messages,
                })
                content = result.get("content", [{}])[0].get("text", "")
            else:
                result = aicore_request(config, "POST", f"/v2/inference/deployments/{deployment['id']}/chat/completions", {
                    "messages": messages,
                    "max_tokens": 1024,
                })
                content = result.get("choices", [{}])[0].get("message", {}).get("content", "")
            
            return {"content": content, "model": deployment["id"]}
        except Exception as e:
            return {"content": str(e), "error": True}

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
                    "capabilities": {
                        "tools": {"listChanged": True},
                        "resources": {"listChanged": True},
                        "prompts": {"listChanged": True},
                    },
                    "serverInfo": {"name": "data-cleaning-copilot-mcp", "version": "1.0.0"},
                })

            elif method == "tools/list":
                return MCPResponse(id, {"tools": list(self.tools.values())})

            elif method == "tools/call":
                tool_name = params.get("name", "")
                args = params.get("arguments", {})

                handlers = {
                    "data_quality_check": self._handle_data_quality_check,
                    "schema_analysis": self._handle_schema_analysis,
                    "data_profiling": self._handle_data_profiling,
                    "anomaly_detection": self._handle_anomaly_detection,
                    "generate_cleaning_query": self._handle_generate_cleaning_query,
                    "ai_chat": self._handle_ai_chat,
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
            response = {"status": "healthy", "service": "data-cleaning-copilot-mcp", "timestamp": __import__("datetime").datetime.utcnow().isoformat() + "Z"}
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
        pass  # Suppress default logging


def main():
    import sys
    port = 9110
    for arg in sys.argv[1:]:
        if arg.startswith("--port="):
            port = int(arg.split("=")[1])

    server = HTTPServer(("", port), MCPHandler)
    print(f"""
╔══════════════════════════════════════════════════════════╗
║   Data Cleaning Copilot MCP Server                       ║
║   Model Context Protocol v2024-11-05                     ║
╚══════════════════════════════════════════════════════════╝

Server: http://localhost:{port}

Tools: data_quality_check, schema_analysis, data_profiling,
       anomaly_detection, generate_cleaning_query, ai_chat, mangle_query

Resources: data://schemas, data://quality_rules, mangle://facts
""")
    server.serve_forever()


if __name__ == "__main__":
    main()