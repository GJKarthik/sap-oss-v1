"""
BTP PAL MCP Server - Exposes a consistent PAL/BTP MCP tool inventory.

16 Tools (order matters for LLM tool selection):
1. btp_registry_query - Query SCHEMA_REGISTRY
2. btp_search - Search fields across HANA + ES
3. pal_arima - Time series forecast (synthetic data)
4. pal_anomaly_detection - Anomaly detection (synthetic data)
5. pal_anomaly_from_table - Anomaly detection (real BTP table) ← RUN FIRST
6. pal_arima_from_table - Time series forecast (real BTP table) ← RUN SECOND
7. hana_tables - Discover PAL-suitable tables
8. list_domains - List domains from SCHEMA_REGISTRY
9. search_schema_registry - Search SCHEMA_REGISTRY fields
10. kuzu_query - Graph query placeholder (not available in this deployment)
11. delegate_to_oecd_tax_expert - Delegate to OECD tax specialist
12. delegate_to_financial_analyst - Delegate to financial specialist
13. delegate_to_macro_strategist - Delegate to macro specialist
14. delegate_to_schema_navigator - Delegate to schema specialist
15. delegate_to_quant_analyst - Delegate to quant specialist
16. list_available_specialists - List delegation specialists
"""

# NOTE: This module is the CANONICAL MCP server for Elastic Agent Builder
# integration in this repository. It implements MCP protocol version
# `2024-11-05` and exposes the same 16-tool inventory via both FastMCP
# (stdio transport) and the HTTP `/mcp` transport defined below. The Zig MCP
# implementation at `src/elasticclaw_analyser/zig/src/mcp/mcp.zig` is a
# separate internal prototype and is NOT the Agent Builder integration point.

import os
import sys
import json
import asyncio
from typing import Optional, Dict, Any, List

# Add parent directory to path for imports
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from dotenv import load_dotenv
load_dotenv()

# Import hana_client functions
try:
    from agent import hana_client
except ImportError:
    import hana_client

# Try to import fastmcp for MCP server
try:
    from mcp.server.fastmcp import FastMCP
    HAS_FASTMCP = True
except ImportError:
    HAS_FASTMCP = False
    print("Warning: fastmcp not available, using HTTP fallback")

# Initialize FastMCP server
if HAS_FASTMCP:
    try:
        mcp = FastMCP("btp-pal-server", version="1.0.0")
    except TypeError:
        # Older fastmcp version doesn't support version parameter
        mcp = FastMCP("btp-pal-server")


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


DEFAULT_KIBANA_URL = "https://my-elasticsearch-project-ce925b.kb.us-east-1.aws.elastic.cloud:443"

def get_kibana_url() -> str:
    """Get Kibana URL with fallback to default."""
    kibana_url = os.getenv("KIBANA_URL", DEFAULT_KIBANA_URL)
    return kibana_url.rstrip("/")


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
        return question.strip()
    return f"Delegating agent context:\n{context.strip()}\n\nQuestion:\n{question.strip()}"


def delegate_to_specialist(agent_id: str, question: str, context: Optional[str] = None) -> str:
    if not question or not question.strip():
        return "Error: question is required."

    kibana_url = get_kibana_url()

    api_key = get_api_key()
    if not api_key:
        return "Error: ES_API_KEY or ELASTICSEARCH_API_KEY is required."

    try:
        import requests
    except ImportError:
        return "Error: the requests package is required to call Kibana."

    try:
        response = requests.post(
            f"{kibana_url}/api/agent_builder/converse",
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


# ==============================================================================
# Tool 1: btp_registry_query - Query SCHEMA_REGISTRY
# ==============================================================================
if HAS_FASTMCP:
    @mcp.tool()
    def btp_registry_query(
        domain: Optional[str] = None,
        source_table: Optional[str] = None,
        wide_table: Optional[str] = None,
        limit: int = 200,
        offset: int = 0
    ) -> Dict[str, Any]:
        """
        Query BTP.SCHEMA_REGISTRY for field metadata.
        
        Args:
            domain: Filter by domain (ESG, GLA, TREASURY, etc.)
            source_table: Filter by source table
            wide_table: Filter by wide table
            limit: Max rows (default 200)
            offset: Pagination offset
        
        Returns:
            Dict with fields array and total count
        """
        if not hana_client.is_available():
            return {"error": "HANA not available"}
        
        rows = hana_client.query_schema_registry(
            domain=domain,
            source_table=source_table,
            wide_table=wide_table,
            limit=limit,
            offset=offset
        )
        return {"fields": rows, "total": len(rows)}


# ==============================================================================
# Tool 2: btp_search - Search fields
# ==============================================================================
if HAS_FASTMCP:
    @mcp.tool()
    def btp_search(
        query: str,
        domain: Optional[str] = None,
        wide_table: Optional[str] = None,
        limit: int = 50
    ) -> Dict[str, Any]:
        """
        Search SCHEMA_REGISTRY for fields matching query.
        
        Args:
            query: Search string (matches field names, descriptions)
            domain: Optional domain filter
            wide_table: Optional table filter
            limit: Max results
        
        Returns:
            Dict with hana results array
        """
        if not query:
            return {"error": "query is required"}
        
        if not hana_client.is_available():
            return {"error": "HANA not available"}
        
        rows = hana_client.search_schema_registry(
            query, domain=domain, wide_table=wide_table, limit=limit
        )
        return {"hana": rows, "query": query, "total": len(rows)}


# ==============================================================================
# Tool 3: pal_arima - Time series forecast (synthetic data input)
# ==============================================================================
if HAS_FASTMCP:
    @mcp.tool()
    def pal_arima(
        input_data: List[Dict[str, Any]],
        horizon: int = 12
    ) -> Dict[str, Any]:
        """
        Run PAL ARIMA time series forecasting on provided data.
        
        Args:
            input_data: Array of {"idx": int, "value": float} records
            horizon: Forecast periods (default 12)
        
        Returns:
            Forecast results with predictions
        """
        if not hana_client.is_available():
            return {"error": "HANA not available"}
        
        return hana_client.call_pal_arima(input_data, horizon=horizon)


# ==============================================================================
# Tool 4: pal_anomaly_detection - Anomaly detection (synthetic data input)
# ==============================================================================
if HAS_FASTMCP:
    @mcp.tool()
    def pal_anomaly_detection(
        input_data: List[Dict[str, Any]]
    ) -> Dict[str, Any]:
        """
        Run PAL anomaly detection on provided data.
        
        Args:
            input_data: Array of {"idx": int, "value": float} records
        
        Returns:
            Anomaly detection results with IQR statistics
        """
        if not hana_client.is_available():
            return {"error": "HANA not available"}
        
        return hana_client.call_pal_anomaly_detection(input_data)


# ==============================================================================
# Tool 5: pal_arima_from_table - Time series forecast (real BTP table)
# ==============================================================================
if HAS_FASTMCP:
    @mcp.tool()
    def pal_arima_from_table(
        table_name: str,
        value_column: str,
        order_by_column: Optional[str] = None,
        where_clause: Optional[str] = None,
        horizon: int = 12,
        limit: int = 1000
    ) -> Dict[str, Any]:
        """
        Run PAL ARIMA forecast directly on a BTP table.
        
        Args:
            table_name: Full table name (e.g., "BTP.FACT")
            value_column: Numeric column to forecast (e.g., "AMOUNT_USD")
            order_by_column: Date column for ordering (e.g., "PERIOD_DATE")
            where_clause: Optional SQL filter (e.g., "DOMAIN = 'GLA'")
            horizon: Forecast periods (default 12)
            limit: Max rows to read (default 1000)
        
        Returns:
            Forecast results with source metadata
        """
        if not table_name or not value_column:
            return {"error": "table_name and value_column are required"}
        
        if not hana_client.is_available():
            return {"error": "HANA not available"}
        
        return hana_client.call_pal_arima_from_table(
            table_name=table_name,
            value_column=value_column,
            order_by_column=order_by_column,
            where_clause=where_clause,
            horizon=horizon,
            limit=limit
        )


# ==============================================================================
# Tool 6: pal_anomaly_from_table - Anomaly detection (real BTP table)
# ==============================================================================
if HAS_FASTMCP:
    @mcp.tool()
    def pal_anomaly_from_table(
        table_name: str,
        value_column: str,
        id_column: Optional[str] = None,
        where_clause: Optional[str] = None,
        limit: int = 1000
    ) -> Dict[str, Any]:
        """
        Run PAL anomaly detection directly on a BTP table.
        
        Args:
            table_name: Full table name (e.g., "BTP.ESG_METRIC")
            value_column: Numeric column to analyze (e.g., "FINANCED_EMISSION")
            id_column: Optional ID column for row identity (e.g., "ESG_ID")
            where_clause: Optional SQL filter
            limit: Max rows to analyze (default 1000)
        
        Returns:
            Anomaly detection results with IQR statistics
        """
        if not table_name or not value_column:
            return {"error": "table_name and value_column are required"}
        
        if not hana_client.is_available():
            return {"error": "HANA not available"}
        
        return hana_client.call_pal_anomaly_from_table(
            table_name=table_name,
            value_column=value_column,
            id_column=id_column,
            where_clause=where_clause,
            limit=limit
        )


# ==============================================================================
# Tool 7: hana_tables - Discover PAL-suitable tables
# ==============================================================================
if HAS_FASTMCP:
    @mcp.tool()
    def hana_tables(
        schema: str = "BTP",
        include_columns: bool = True
    ) -> Dict[str, Any]:
        """
        Discover HANA tables with numeric columns suitable for PAL.
        
        Args:
            schema: Schema to scan (default "BTP")
            include_columns: Include column metadata (default True)
        
        Returns:
            List of tables with numeric/date columns and row counts
        """
        if not hana_client.is_available():
            return {"error": "HANA not available"}
        
        return hana_client.discover_pal_tables(schema=schema, include_columns=include_columns)


# ==============================================================================
# Tool 8: list_domains - List domains from SCHEMA_REGISTRY
# ==============================================================================
if HAS_FASTMCP:
    @mcp.tool()
    def list_domains() -> Dict[str, Any]:
        """
        List all domains from SCHEMA_REGISTRY.
        
        Returns:
            List of domain names
        """
        if not hana_client.is_available():
            return {"error": "HANA not available"}
        
        domains = hana_client.list_domains()
        return {"domains": domains, "count": len(domains)}


# ==============================================================================
# Tool 9: search_schema_registry - Search fields
# ==============================================================================
if HAS_FASTMCP:
    @mcp.tool()
    def search_schema_registry(
        query: str,
        domain: Optional[str] = None,
        limit: int = 50
    ) -> Dict[str, Any]:
        """
        Search SCHEMA_REGISTRY for matching fields.
        
        Args:
            query: Search term
            domain: Optional domain filter
            limit: Max results
        
        Returns:
            Matching field definitions
        """
        if not query:
            return {"error": "query is required"}
        
        if not hana_client.is_available():
            return {"error": "HANA not available"}
        
        rows = hana_client.search_schema_registry(query, domain=domain, limit=limit)
        return {"results": rows, "query": query, "count": len(rows)}


# ==============================================================================
# Tool 10: kuzu_query - Graph query placeholder
# ==============================================================================
if HAS_FASTMCP:
    @mcp.tool()
    def kuzu_query(cypher: str) -> Dict[str, Any]:
        """
        Placeholder for Kuzu graph queries.

        Args:
            cypher: Cypher query to execute

        Returns:
            Stub error until Kuzu is enabled in this deployment
        """
        return {"error": "Kuzu graph query not available in this deployment"}


# ==============================================================================
# Tools 11-16: Specialist delegation tools
# ==============================================================================
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


# ==============================================================================
# HTTP Fallback Server (if fastmcp not available)
# ==============================================================================
def create_http_server():
    """Create a simple HTTP server exposing tools via REST."""
    from http.server import HTTPServer, BaseHTTPRequestHandler
    import json
    
    class MCPHandler(BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path == "/health":
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(json.dumps({
                    "status": "ok",
                    "service": "btp-pal-server",
                    "tools": len(get_tools_list()["tools"]),
                    "hana_available": hana_client.is_available()
                }).encode())
            elif self.path == "/tools":
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                # Return full tool definitions including inputSchema for agent builders
                self.wfile.write(json.dumps(get_tools_list()).encode())
            else:
                self.send_response(404)
                self.end_headers()
        
        def do_POST(self):
            if self.path == "/mcp":
                content_len = int(self.headers.get("Content-Length", 0))
                body = json.loads(self.rfile.read(content_len))
                
                method = body.get("method", "")
                request_id = body.get("id", 1)
                
                # Handle MCP protocol methods
                if method == "tools/list":
                    # Return tool definitions with proper MCP schema
                    result = get_tools_list()
                elif method == "tools/call":
                    tool_name = body.get("params", {}).get("name")
                    args = body.get("params", {}).get("arguments", {})
                    result = dispatch_tool(tool_name, args)
                elif method == "initialize":
                    # MCP initialization handshake
                    result = {
                        "protocolVersion": "2024-11-05",
                        "serverInfo": {
                            "name": "btp-pal-server",
                            "version": "1.0.0"
                        },
                        "capabilities": {
                            "tools": {}
                        }
                    }
                elif method == "notifications/initialized":
                    result = {}
                else:
                    # Legacy: assume tools/call if method not specified
                    tool_name = body.get("params", {}).get("name")
                    args = body.get("params", {}).get("arguments", {})
                    result = dispatch_tool(tool_name, args)
                
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(json.dumps({
                    "jsonrpc": "2.0",
                    "id": request_id,
                    "result": result
                }).encode())
            else:
                self.send_response(404)
                self.end_headers()
    
    return MCPHandler


def get_tools_list() -> Dict[str, Any]:
    """Return tools list in MCP protocol format with inputSchema."""
    return {
        "tools": [
            {
                "name": "btp_registry_query",
                "description": "Query BTP.SCHEMA_REGISTRY for field metadata",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "domain": {"type": "string", "description": "Filter by domain (ESG, GLA, TREASURY, etc.)"},
                        "source_table": {"type": "string", "description": "Filter by source table"},
                        "wide_table": {"type": "string", "description": "Filter by wide table"},
                        "limit": {"type": "integer", "description": "Max rows (default 200)", "default": 200},
                        "offset": {"type": "integer", "description": "Pagination offset", "default": 0}
                    }
                }
            },
            {
                "name": "btp_search",
                "description": "Search SCHEMA_REGISTRY for fields matching query",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "query": {"type": "string", "description": "Search string (matches field names, descriptions)"},
                        "domain": {"type": "string", "description": "Optional domain filter"},
                        "wide_table": {"type": "string", "description": "Optional table filter"},
                        "limit": {"type": "integer", "description": "Max results", "default": 50}
                    },
                    "required": ["query"]
                }
            },
            {
                "name": "pal_arima",
                "description": "Run PAL ARIMA time series forecasting on provided data",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "input_data": {"type": "array", "items": {"type": "object"}, "description": "Array of {idx, value} records"},
                        "horizon": {"type": "integer", "description": "Forecast periods (default 12)", "default": 12}
                    },
                    "required": ["input_data"]
                }
            },
            {
                "name": "pal_anomaly_detection",
                "description": "Run PAL anomaly detection on provided data",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "input_data": {"type": "array", "items": {"type": "object"}, "description": "Array of {idx, value} records"}
                    },
                    "required": ["input_data"]
                }
            },
            {
                "name": "pal_anomaly_from_table",
                "description": "Run PAL anomaly detection directly on a BTP HANA table. REQUIRED: table_name AND value_column. For revenue analysis use table_name='BTP.FACT' and value_column='AMOUNT_USD'. For ESG analysis use table_name='BTP.ESG_METRIC' and value_column='FINANCED_EMISSION'. For client revenue use table_name='BTP.CLIENT_MI' and value_column='TOTAL_REVENUE'. Use IQR statistical method to identify outliers.",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "table_name": {"type": "string", "description": "REQUIRED. Full table name. Use BTP.FACT for revenue/financials, BTP.ESG_METRIC for ESG, BTP.CLIENT_MI for clients, BTP.TREASURY_POSITION for treasury"},
                        "value_column": {"type": "string", "description": "REQUIRED. Numeric column to analyze. Use AMOUNT_USD for revenue, FINANCED_EMISSION for ESG, TOTAL_REVENUE for clients"},
                        "where_clause": {"type": "string", "description": "Optional SQL filter without WHERE keyword, e.g. DOMAIN = 'GLA'"},
                        "id_column": {"type": "string", "description": "Optional ID column for row identity"},
                        "limit": {"type": "integer", "description": "Max rows to analyze (default 1000)", "default": 1000}
                    },
                    "required": ["table_name", "value_column"]
                }
            },
            {
                "name": "pal_arima_from_table",
                "description": "Run PAL ARIMA time-series forecast on BTP HANA table. REQUIRED: table_name + value_column. IMPORTANT: When user asks 'by entity' or 'group by X' or 'per region', YOU MUST use group_by_columns parameter! Examples: 'revenue by entity' -> group_by_columns=['ENTITY_CODE']. 'forecast by region' -> group_by_columns=['REGION']. 'analyse by client' -> group_by_columns=['CLIENT_CODE']. For BTP.FACT the available dimension columns are: ENTITY_CODE, DOMAIN, CLIENT_CODE, REGION.",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "table_name": {"type": "string", "description": "REQUIRED. Use BTP.FACT for revenue, BTP.ESG_METRIC for ESG"},
                        "value_column": {"type": "string", "description": "REQUIRED. Use AMOUNT_USD for revenue, FINANCED_EMISSION for ESG"},
                        "date_column": {"type": "string", "description": "Date column. Use PERIOD_DATE for BTP.FACT"},
                        "aggregate_function": {"type": "string", "description": "SUM, AVG, COUNT, MAX, MIN", "default": "SUM", "enum": ["SUM", "AVG", "COUNT", "MAX", "MIN"]},
                        "group_by_columns": {"type": "array", "items": {"type": "string"}, "description": "CRITICAL: When user says 'by entity' or 'group by' or 'per region', USE THIS! For BTP.FACT use: ENTITY_CODE, DOMAIN, CLIENT_CODE, or REGION. Example: ['ENTITY_CODE'] for 'by entity'."},
                        "where_clause": {"type": "string", "description": "SQL filter e.g. DOMAIN = 'GLA'"},
                        "horizon": {"type": "integer", "description": "Forecast periods", "default": 12},
                        "limit": {"type": "integer", "description": "Max rows", "default": 1000}
                    },
                    "required": ["table_name", "value_column"]
                }
            },
            {
                "name": "hana_tables",
                "description": "Discover HANA tables with numeric columns suitable for PAL",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "schema": {"type": "string", "description": "Schema to scan", "default": "BTP"},
                        "include_columns": {"type": "boolean", "description": "Include column metadata", "default": True}
                    }
                }
            },
            {
                "name": "list_domains",
                "description": "List all domains from SCHEMA_REGISTRY",
                "inputSchema": {
                    "type": "object",
                    "properties": {}
                }
            },
            {
                "name": "search_schema_registry",
                "description": "Search SCHEMA_REGISTRY for matching fields",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "query": {"type": "string", "description": "Search term"},
                        "domain": {"type": "string", "description": "Optional domain filter"},
                        "limit": {"type": "integer", "description": "Max results", "default": 50}
                    },
                    "required": ["query"]
                }
            },
            {
                "name": "kuzu_query",
                "description": "Execute Kuzu graph query (optional)",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "cypher": {"type": "string", "description": "Cypher query to execute"}
                    },
                    "required": ["cypher"]
                }
            },
            {
                "name": "delegate_to_oecd_tax_expert",
                "description": SPECIALISTS_BY_TOOL["delegate_to_oecd_tax_expert"]["description"],
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "question": {"type": "string", "description": "Question to delegate to the specialist."},
                        "context": {"type": "string", "description": "Optional additional context from the delegating agent."}
                    },
                    "required": ["question"]
                }
            },
            {
                "name": "delegate_to_financial_analyst",
                "description": SPECIALISTS_BY_TOOL["delegate_to_financial_analyst"]["description"],
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "question": {"type": "string", "description": "Question to delegate to the specialist."},
                        "context": {"type": "string", "description": "Optional additional context from the delegating agent."}
                    },
                    "required": ["question"]
                }
            },
            {
                "name": "delegate_to_macro_strategist",
                "description": SPECIALISTS_BY_TOOL["delegate_to_macro_strategist"]["description"],
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "question": {"type": "string", "description": "Question to delegate to the specialist."},
                        "context": {"type": "string", "description": "Optional additional context from the delegating agent."}
                    },
                    "required": ["question"]
                }
            },
            {
                "name": "delegate_to_schema_navigator",
                "description": SPECIALISTS_BY_TOOL["delegate_to_schema_navigator"]["description"],
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "question": {"type": "string", "description": "Question to delegate to the specialist."},
                        "context": {"type": "string", "description": "Optional additional context from the delegating agent."}
                    },
                    "required": ["question"]
                }
            },
            {
                "name": "delegate_to_quant_analyst",
                "description": SPECIALISTS_BY_TOOL["delegate_to_quant_analyst"]["description"],
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "question": {"type": "string", "description": "Question to delegate to the specialist."},
                        "context": {"type": "string", "description": "Optional additional context from the delegating agent."}
                    },
                    "required": ["question"]
                }
            },
            {
                "name": "list_available_specialists",
                "description": "List the available specialist agents and when to delegate to them.",
                "inputSchema": {
                    "type": "object",
                    "properties": {}
                }
            }
        ]
    }


def wrap_mcp_content(result: Any) -> Dict[str, Any]:
    """Wrap result in MCP content format for tools/call response."""
    text = result if isinstance(result, str) else json.dumps(result, indent=2, default=str)
    return {
        "content": [
            {"type": "text", "text": text}
        ]
    }


def dispatch_tool(tool_name: str, args: Dict[str, Any]) -> Dict[str, Any]:
    """Dispatch tool call to appropriate function and wrap in MCP content format."""
    
    if tool_name == "btp_registry_query":
        if not hana_client.is_available():
            return wrap_mcp_content({"error": "HANA not available"})
        rows = hana_client.query_schema_registry(
            domain=args.get("domain"),
            source_table=args.get("source_table"),
            wide_table=args.get("wide_table"),
            limit=args.get("limit", 200),
            offset=args.get("offset", 0)
        )
        return wrap_mcp_content({"fields": rows, "total": len(rows)})
    
    elif tool_name == "btp_search":
        if not hana_client.is_available():
            return wrap_mcp_content({"error": "HANA not available"})
        rows = hana_client.search_schema_registry(
            args.get("query", ""),
            domain=args.get("domain"),
            wide_table=args.get("wide_table"),
            limit=args.get("limit", 50)
        )
        return wrap_mcp_content({"hana": rows, "query": args.get("query"), "total": len(rows)})
    
    elif tool_name == "pal_arima":
        if not hana_client.is_available():
            return wrap_mcp_content({"error": "HANA not available"})
        result = hana_client.call_pal_arima(
            args.get("input_data", []),
            horizon=args.get("horizon", 12)
        )
        return wrap_mcp_content(result)
    
    elif tool_name == "pal_anomaly_detection":
        if not hana_client.is_available():
            return wrap_mcp_content({"error": "HANA not available"})
        result = hana_client.call_pal_anomaly_detection(args.get("input_data", []))
        return wrap_mcp_content(result)
    
    elif tool_name == "pal_arima_from_table":
        if not hana_client.is_available():
            return wrap_mcp_content({"error": "HANA not available"})
        result = hana_client.call_pal_arima_from_table(
            table_name=args.get("table_name") or args.get("table"),
            value_column=args.get("value_column"),
            date_column=args.get("date_column") or args.get("order_by_column"),
            aggregate_function=args.get("aggregate_function", "SUM"),
            group_by_columns=args.get("group_by_columns"),
            where_clause=args.get("where_clause") or args.get("filter"),
            horizon=args.get("horizon") or args.get("forecast_periods", 12),
            limit=args.get("limit", 1000)
        )
        return wrap_mcp_content(result)
    
    elif tool_name == "pal_anomaly_from_table":
        if not hana_client.is_available():
            return wrap_mcp_content({"error": "HANA not available"})
        result = hana_client.call_pal_anomaly_from_table(
            table_name=args.get("table_name"),
            value_column=args.get("value_column"),
            id_column=args.get("id_column"),
            where_clause=args.get("where_clause"),
            limit=args.get("limit", 1000)
        )
        return wrap_mcp_content(result)
    
    elif tool_name == "hana_tables":
        if not hana_client.is_available():
            return wrap_mcp_content({"error": "HANA not available"})
        result = hana_client.discover_pal_tables(
            schema=args.get("schema", "BTP"),
            include_columns=args.get("include_columns", True)
        )
        return wrap_mcp_content(result)
    
    elif tool_name == "list_domains":
        if not hana_client.is_available():
            return wrap_mcp_content({"error": "HANA not available"})
        domains = hana_client.list_domains()
        return wrap_mcp_content({"domains": domains, "count": len(domains)})
    
    elif tool_name == "search_schema_registry":
        if not hana_client.is_available():
            return wrap_mcp_content({"error": "HANA not available"})
        rows = hana_client.search_schema_registry(
            args.get("query", ""),
            domain=args.get("domain"),
            limit=args.get("limit", 50)
        )
        return wrap_mcp_content({"results": rows, "query": args.get("query"), "count": len(rows)})
    
    elif tool_name == "kuzu_query":
        # Graph query not implemented yet
        return wrap_mcp_content({"error": "Kuzu graph query not available in this deployment"})

    elif tool_name == "list_available_specialists":
        return wrap_mcp_content(list_specialists())

    elif tool_name in SPECIALISTS_BY_TOOL:
        specialist = SPECIALISTS_BY_TOOL[tool_name]
        result = delegate_to_specialist(
            specialist["agent_id"],
            args.get("question", ""),
            args.get("context"),
        )
        return wrap_mcp_content(result)
    
    else:
        return wrap_mcp_content({"error": f"Unknown tool: {tool_name}"})


# ==============================================================================
# Main entry point
# ==============================================================================
def run_http_health_server(host: str, port: int):
    """Run HTTP server for health checks and REST API."""
    from http.server import HTTPServer
    import threading
    
    handler = create_http_server()
    server = HTTPServer((host, port), handler)
    print(f"HTTP Server running at http://{host}:{port}")
    print(f"Health: http://{host}:{port}/health")
    print(f"Tools:  http://{host}:{port}/tools")
    print(f"MCP:    POST http://{host}:{port}/mcp")
    server.serve_forever()


def main():
    port = int(os.environ.get("MCPPAL_PORT", 8084))
    host = os.environ.get("MCPPAL_HOST", "0.0.0.0")
    
    print(f"=" * 60)
    print(f"BTP PAL MCP Server")
    print(f"=" * 60)
    print(f"Host: {host}")
    print(f"Port: {port}")
    print(f"HANA Available: {hana_client.is_available()}")
    print(f"Tools: {len(get_tools_list()['tools'])}")
    print(f"=" * 60)
    
    # Always run HTTP server for health checks (required by AWS App Runner)
    # MCP stdio transport can run alongside if needed
    print("Starting HTTP server (supports /health, /tools, /mcp endpoints)...")
    run_http_health_server(host, port)


if __name__ == "__main__":
    main()
