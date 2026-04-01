"""A2A Delegation MCP Server for Elastic Agent Builder specialists."""

import json
import os
import sys
from typing import Any, Dict, Optional

from dotenv import load_dotenv

# Add parent directory to path for imports (matches existing MCP server pattern)
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

load_dotenv()

DEFAULT_KIBANA_URL = "https://my-elasticsearch-project-ce925b.kb.us-east-1.aws.elastic.cloud:443"
DEFAULT_HOST = "0.0.0.0"
DEFAULT_PORT = 8001
REQUEST_TIMEOUT_SECONDS = 120

SPECIALISTS = [
    {
        "tool_name": "delegate_to_oecd_tax_expert",
        "agent_id": "oecd-tax-expert",
        "name": "OECD Tax Expert",
        "description": "Delegate a tax policy question to the OECD Tax Expert. Use when you receive questions about OECD rules, Pillar One/Two, BEPS, transfer pricing, model tax conventions, or international tax policy.",
    },
    {
        "tool_name": "delegate_to_financial_analyst",
        "agent_id": "financial-analyst",
        "name": "Financial Analyst",
        "description": "Delegate a financial analysis question to the Financial Analyst. Use when you receive questions about Elastic NV revenue, earnings, financial statements, or company performance.",
    },
    {
        "tool_name": "delegate_to_macro_strategist",
        "agent_id": "global-macro-strategist",
        "name": "Global Macro Strategist",
        "description": "Delegate a macroeconomic question to the Global Macro Strategist. Use when you receive questions about economic trends, market forecasts, country risk, or sector analysis.",
    },
    {
        "tool_name": "delegate_to_schema_navigator",
        "agent_id": "data-schema-navigator",
        "name": "Data Schema Navigator",
        "description": "Delegate a data/schema question to the Data Schema Navigator. Use when you receive questions about table structures, field definitions, data dictionaries, or HANA schemas.",
    },
    {
        "tool_name": "delegate_to_quant_analyst",
        "agent_id": "quantitative-analyst",
        "name": "Quantitative Analyst",
        "description": "Delegate a quantitative analysis question to the Quantitative Analyst. Use when you receive questions about forecasting, time series, anomaly detection, or statistical analysis.",
    },
]
SPECIALISTS_BY_TOOL = {specialist["tool_name"]: specialist for specialist in SPECIALISTS}

try:
    from mcp.server.fastmcp import FastMCP

    HAS_FASTMCP = True
except ImportError:
    HAS_FASTMCP = False
    print("Warning: fastmcp not available, using HTTP fallback")

if HAS_FASTMCP:
    try:
        mcp = FastMCP("a2a-delegation-server", version="1.0.0")
    except TypeError:
        mcp = FastMCP("a2a-delegation-server")


def get_kibana_url() -> str:
    return os.getenv("KIBANA_URL", DEFAULT_KIBANA_URL).rstrip("/")


def get_api_key() -> Optional[str]:
    return os.getenv("ES_API_KEY") or os.getenv("ELASTICSEARCH_API_KEY")


def extract_response_text(body: Any) -> str:
    if isinstance(body, str):
        return body.strip()
    if isinstance(body, list):
        parts = [extract_response_text(item) for item in body]
        return "\n".join(part for part in parts if part)
    if isinstance(body, dict):
        for key in ("message", "content", "text", "output", "response"):
            if key in body:
                text = extract_response_text(body[key])
                if text:
                    return text
    return ""


def build_converse_input(question: str, context: Optional[str] = None) -> str:
    if not context:
        return question
    return f"Delegating agent context:\n{context.strip()}\n\nQuestion:\n{question.strip()}"


def delegate_to_specialist(agent_id: str, question: str, context: Optional[str] = None) -> str:
    if not question or not question.strip():
        return "Error: question is required."

    api_key = get_api_key()
    if not api_key:
        return "Error: ES_API_KEY or ELASTICSEARCH_API_KEY is required."

    try:
        import requests
    except ImportError:
        return "Error: the requests package is required to call Kibana."

    try:
        response = requests.post(
            f"{get_kibana_url()}/api/agent_builder/converse",
            headers={
                "Authorization": f"ApiKey {api_key}",
                "kbn-xsrf": "true",
                "Content-Type": "application/json",
            },
            json={"agent_id": agent_id, "input": build_converse_input(question, context)},
            timeout=REQUEST_TIMEOUT_SECONDS,
        )
    except requests.Timeout:
        return f"Error: delegation to {agent_id} timed out after {REQUEST_TIMEOUT_SECONDS} seconds."
    except requests.RequestException as exc:
        return f"Error: delegation request to {agent_id} failed: {exc}"

    body: Any = None
    if response.content:
        try:
            body = response.json()
        except ValueError:
            body = response.text.strip()

    if response.status_code >= 400:
        detail = body if isinstance(body, str) else json.dumps(body, ensure_ascii=False)
        return f"Error: Kibana returned HTTP {response.status_code} for {agent_id}: {detail or response.reason}"

    text = extract_response_text(body)
    if text:
        return text
    return json.dumps(body, indent=2, ensure_ascii=False) if body is not None else ""


def list_specialists() -> Dict[str, Any]:
    return {
        "specialists": [
            {
                "tool_name": specialist["tool_name"],
                "agent_id": specialist["agent_id"],
                "name": specialist["name"],
                "description": specialist["description"],
            }
            for specialist in SPECIALISTS
        ],
        "count": len(SPECIALISTS),
    }


if HAS_FASTMCP:
    @mcp.tool()
    def delegate_to_oecd_tax_expert(question: str, context: Optional[str] = None) -> str:
        """Delegate a tax policy question to the OECD Tax Expert."""
        return delegate_to_specialist("oecd-tax-expert", question, context)


    @mcp.tool()
    def delegate_to_financial_analyst(question: str, context: Optional[str] = None) -> str:
        """Delegate a financial analysis question to the Financial Analyst."""
        return delegate_to_specialist("financial-analyst", question, context)


    @mcp.tool()
    def delegate_to_macro_strategist(question: str, context: Optional[str] = None) -> str:
        """Delegate a macroeconomic question to the Global Macro Strategist."""
        return delegate_to_specialist("global-macro-strategist", question, context)


    @mcp.tool()
    def delegate_to_schema_navigator(question: str, context: Optional[str] = None) -> str:
        """Delegate a data/schema question to the Data Schema Navigator."""
        return delegate_to_specialist("data-schema-navigator", question, context)


    @mcp.tool()
    def delegate_to_quant_analyst(question: str, context: Optional[str] = None) -> str:
        """Delegate a quantitative analysis question to the Quantitative Analyst."""
        return delegate_to_specialist("quantitative-analyst", question, context)


    @mcp.tool()
    def list_available_specialists() -> Dict[str, Any]:
        """List delegation specialists and their tool descriptions."""
        return list_specialists()


def create_http_server():
    """Create a simple HTTP server exposing MCP-compatible endpoints."""
    from http.server import BaseHTTPRequestHandler

    class MCPHandler(BaseHTTPRequestHandler):
        def _send_json(self, payload: Dict[str, Any], status_code: int = 200):
            self.send_response(status_code)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps(payload).encode())

        def do_GET(self):
            if self.path == "/health":
                self._send_json(
                    {
                        "status": "ok",
                        "service": "a2a-delegation-server",
                        "tools": len(get_tools_list()["tools"]),
                    }
                )
            elif self.path in {"/tools", "/mcp/tools"}:
                self._send_json(get_tools_list())
            else:
                self._send_json({"error": "Not found"}, 404)

        def do_POST(self):
            if self.path != "/mcp":
                self._send_json({"error": "Not found"}, 404)
                return

            content_len = int(self.headers.get("Content-Length", 0))
            body = json.loads(self.rfile.read(content_len))
            method = body.get("method", "")
            request_id = body.get("id", 1)

            if method == "tools/list":
                result = get_tools_list()
            elif method == "tools/call":
                tool_name = body.get("params", {}).get("name")
                args = body.get("params", {}).get("arguments", {})
                result = dispatch_tool(tool_name, args)
            elif method == "initialize":
                result = {
                    "protocolVersion": "2024-11-05",
                    "serverInfo": {"name": "a2a-delegation-server", "version": "1.0.0"},
                    "capabilities": {"tools": {}},
                }
            elif method == "notifications/initialized":
                result = {}
            else:
                tool_name = body.get("params", {}).get("name")
                args = body.get("params", {}).get("arguments", {})
                result = dispatch_tool(tool_name, args)

            self._send_json({"jsonrpc": "2.0", "id": request_id, "result": result})

    return MCPHandler


def get_tools_list() -> Dict[str, Any]:
    tool_entries = []
    for specialist in SPECIALISTS:
        tool_entries.append(
            {
                "name": specialist["tool_name"],
                "description": specialist["description"],
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "question": {"type": "string", "description": "Question to delegate to the specialist."},
                        "context": {"type": "string", "description": "Optional additional context from the delegating agent."},
                    },
                    "required": ["question"],
                },
            }
        )
    tool_entries.append(
        {
            "name": "list_available_specialists",
            "description": "List the available specialist agents and when to delegate to them.",
            "inputSchema": {"type": "object", "properties": {}},
        }
    )
    return {"tools": tool_entries}


def wrap_mcp_content(result: Any) -> Dict[str, Any]:
    text = result if isinstance(result, str) else json.dumps(result, indent=2, ensure_ascii=False)
    return {"content": [{"type": "text", "text": text}]}


def dispatch_tool(tool_name: Optional[str], args: Dict[str, Any]) -> Dict[str, Any]:
    if tool_name == "list_available_specialists":
        return wrap_mcp_content(list_specialists())
    if tool_name in SPECIALISTS_BY_TOOL:
        specialist = SPECIALISTS_BY_TOOL[tool_name]
        result = delegate_to_specialist(
            specialist["agent_id"],
            args.get("question", ""),
            args.get("context"),
        )
        return wrap_mcp_content(result)
    return wrap_mcp_content(f"Error: unknown tool: {tool_name}")


def run_http_server(host: str, port: int):
    from http.server import HTTPServer

    handler = create_http_server()
    server = HTTPServer((host, port), handler)
    print(f"HTTP Server running at http://{host}:{port}")
    print(f"Health: http://{host}:{port}/health")
    print(f"Tools:  http://{host}:{port}/tools")
    print(f"MCP:    POST http://{host}:{port}/mcp")
    server.serve_forever()


def main():
    host = os.getenv("A2A_MCP_HOST", DEFAULT_HOST)
    port = int(os.getenv("A2A_MCP_PORT", os.getenv("PORT", str(DEFAULT_PORT))))

    print("=" * 60)
    print("A2A Delegation MCP Server")
    print("=" * 60)
    print(f"Host: {host}")
    print(f"Port: {port}")
    print(f"Kibana URL: {get_kibana_url()}")
    print(f"Tools: {len(get_tools_list()['tools'])}")
    print("=" * 60)
    run_http_server(host, port)


if __name__ == "__main__":
    main()