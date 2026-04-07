# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2024 SAP SE
"""
SAP OSS ai-core-pal MCP Server

FastMCP server exposing PAL algorithms as MCP tools:
  - pal_forecast: Time series forecasting
  - pal_anomaly: Anomaly detection
  - pal_clustering: K-Means clustering
  - pal_classification: Random Forest classification
  - pal_regression: Linear regression
  - hana_tables: Discover PAL-suitable tables
  - execute_sql: Execute SQL on HANA Cloud

Run: uvicorn mcp_server.btp_pal_mcp_server:app --host 0.0.0.0 --port 8084
"""
from __future__ import annotations

import datetime
import json
import logging
import os
import sys
from decimal import Decimal
from typing import Any, Dict, List, Optional

# Add parent directory to path for imports
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from dotenv import load_dotenv

load_dotenv()

logging.basicConfig(level=os.environ.get("LOG_LEVEL", "INFO"))
logger = logging.getLogger(__name__)


# ---------------------------------------------------------------------------
# Custom JSON encoder — handles HANA result types (date, datetime, Decimal)
# ---------------------------------------------------------------------------
class _HanaEncoder(json.JSONEncoder):
    def default(self, obj: Any) -> Any:
        if isinstance(obj, (datetime.date, datetime.datetime)):
            return obj.isoformat()
        if isinstance(obj, Decimal):
            return float(obj)
        if isinstance(obj, bytes):
            return obj.decode("utf-8", errors="replace")
        return super().default(obj)


def _json_dumps(obj: Any, **kwargs: Any) -> str:
    """json.dumps with HANA-safe encoder."""
    kwargs.setdefault("indent", 2)
    return json.dumps(obj, cls=_HanaEncoder, **kwargs)

# ---------------------------------------------------------------------------
# FastMCP / MCP imports
# ---------------------------------------------------------------------------
try:
    from mcp.server.fastmcp import FastMCP
    _MCP_AVAILABLE = True
except ImportError:
    _MCP_AVAILABLE = False
    logger.warning("fastmcp not installed - using fallback HTTP server")

# ---------------------------------------------------------------------------
# HANA client imports
# ---------------------------------------------------------------------------
try:
    from agent import hana_client
    _HANA_AVAILABLE = hana_client.is_available()
except ImportError:
    hana_client = None  # type: ignore
    _HANA_AVAILABLE = False
    logger.warning("hana_client not available")

# ---------------------------------------------------------------------------
# MCP Server Setup
# ---------------------------------------------------------------------------
if _MCP_AVAILABLE:
    mcp = FastMCP("ai-core-pal")
else:
    mcp = None

# ---------------------------------------------------------------------------
# MCP Tool: pal_forecast
# ---------------------------------------------------------------------------
def _pal_forecast_impl(
    table_name: str,
    value_column: str,
    date_column: Optional[str] = None,
    horizon: int = 12,
    alpha: float = 0.3,
) -> Dict[str, Any]:
    """Run PAL time series forecasting."""
    if not _HANA_AVAILABLE:
        return {"status": "error", "error": "HANA not configured"}
    
    return hana_client.call_pal_forecast_from_table(
        table_name=table_name,
        value_column=value_column,
        date_column=date_column,
        horizon=horizon,
        alpha=alpha,
    )

if mcp:
    @mcp.tool()
    def pal_forecast(
        table_name: str,
        value_column: str,
        date_column: Optional[str] = None,
        horizon: int = 12,
        alpha: float = 0.3,
    ) -> str:
        """
        Run PAL Single Exponential Smoothing forecast on a HANA table.
        
        Args:
            table_name: Full table name e.g. "AINUCLEUS.PAL_TIMESERIES_DATA"
            value_column: Numeric column to forecast
            date_column: Optional date column for ordering
            horizon: Number of periods to forecast (default 12)
            alpha: Smoothing parameter 0-1 (default 0.3)
        
        Returns:
            JSON with forecast values and model parameters
        """
        result = _pal_forecast_impl(table_name, value_column, date_column, horizon, alpha)
        return _json_dumps(result)

# ---------------------------------------------------------------------------
# MCP Tool: pal_anomaly
# ---------------------------------------------------------------------------
def _pal_anomaly_impl(
    table_name: str,
    value_column: str,
    multiplier: float = 1.5,
) -> Dict[str, Any]:
    """Run PAL anomaly detection."""
    if not _HANA_AVAILABLE:
        return {"status": "error", "error": "HANA not configured"}
    
    return hana_client.call_pal_anomaly_from_table(
        table_name=table_name,
        value_column=value_column,
        multiplier=multiplier,
    )

if mcp:
    @mcp.tool()
    def pal_anomaly(
        table_name: str,
        value_column: str,
        multiplier: float = 1.5,
    ) -> str:
        """
        Run PAL IQR-based anomaly detection on a HANA table.
        
        Args:
            table_name: Full table name e.g. "AINUCLEUS.PAL_ANOMALY_DATA"
            value_column: Numeric column to analyze
            multiplier: IQR multiplier for bounds (default 1.5)
        
        Returns:
            JSON with detected anomalies and IQR statistics
        """
        result = _pal_anomaly_impl(table_name, value_column, multiplier)
        return _json_dumps(result)

# ---------------------------------------------------------------------------
# MCP Tool: pal_clustering
# ---------------------------------------------------------------------------
def _pal_clustering_impl(
    table_name: str,
    feature_columns: List[str],
    n_clusters: int = 3,
) -> Dict[str, Any]:
    """Run PAL K-Means clustering."""
    if not _HANA_AVAILABLE:
        return {"status": "error", "error": "HANA not configured"}
    
    return hana_client.call_pal_clustering(
        table_name=table_name,
        feature_columns=feature_columns,
        n_clusters=n_clusters,
    )

if mcp:
    @mcp.tool()
    def pal_clustering(
        table_name: str,
        feature_columns: str,
        n_clusters: int = 3,
    ) -> str:
        """
        Run PAL K-Means clustering on a HANA table.
        
        Args:
            table_name: Full table name e.g. "AINUCLEUS.PAL_CLUSTERING_DATA"
            feature_columns: Comma-separated numeric columns e.g. "AGE,INCOME,SPEND_SCORE"
            n_clusters: Number of clusters (default 3)
        
        Returns:
            JSON with cluster assignments and sizes
        """
        cols = [c.strip() for c in feature_columns.split(",")]
        result = _pal_clustering_impl(table_name, cols, n_clusters)
        return _json_dumps(result)

# ---------------------------------------------------------------------------
# MCP Tool: pal_classification
# ---------------------------------------------------------------------------
def _pal_classification_impl(
    table_name: str,
    feature_columns: List[str],
    label_column: str,
    n_estimators: int = 100,
) -> Dict[str, Any]:
    """Run PAL Random Forest classification."""
    if not _HANA_AVAILABLE:
        return {"status": "error", "error": "HANA not configured"}
    
    return hana_client.call_pal_classification(
        table_name=table_name,
        feature_columns=feature_columns,
        label_column=label_column,
        n_estimators=n_estimators,
    )

if mcp:
    @mcp.tool()
    def pal_classification(
        table_name: str,
        feature_columns: str,
        label_column: str,
        n_estimators: int = 100,
    ) -> str:
        """
        Run PAL Random Forest classification on a HANA table.
        
        Args:
            table_name: Full table name e.g. "AINUCLEUS.PAL_CLASSIFICATION_DATA"
            feature_columns: Comma-separated numeric features e.g. "FEATURE_1,FEATURE_2,FEATURE_3"
            label_column: Label column name e.g. "LABEL"
            n_estimators: Number of trees (default 100)
        
        Returns:
            JSON with training results
        """
        cols = [c.strip() for c in feature_columns.split(",")]
        result = _pal_classification_impl(table_name, cols, label_column, n_estimators)
        return _json_dumps(result)

# ---------------------------------------------------------------------------
# MCP Tool: pal_regression
# ---------------------------------------------------------------------------
def _pal_regression_impl(
    table_name: str,
    feature_columns: List[str],
    target_column: str,
) -> Dict[str, Any]:
    """Run PAL Linear Regression."""
    if not _HANA_AVAILABLE:
        return {"status": "error", "error": "HANA not configured"}
    
    return hana_client.call_pal_regression(
        table_name=table_name,
        feature_columns=feature_columns,
        target_column=target_column,
    )

if mcp:
    @mcp.tool()
    def pal_regression(
        table_name: str,
        feature_columns: str,
        target_column: str,
    ) -> str:
        """
        Run PAL Linear Regression on a HANA table.
        
        Args:
            table_name: Full table name e.g. "AINUCLEUS.PAL_REGRESSION_DATA"
            feature_columns: Comma-separated numeric features e.g. "X1,X2,X3"
            target_column: Target column name e.g. "Y_TARGET"
        
        Returns:
            JSON with regression coefficients
        """
        cols = [c.strip() for c in feature_columns.split(",")]
        result = _pal_regression_impl(table_name, cols, target_column)
        return _json_dumps(result)

# ---------------------------------------------------------------------------
# MCP Tool: hana_tables
# ---------------------------------------------------------------------------
def _hana_tables_impl(schema: Optional[str] = None) -> Dict[str, Any]:
    """Discover PAL-suitable tables."""
    if not _HANA_AVAILABLE:
        return {"status": "error", "error": "HANA not configured"}
    
    return hana_client.discover_pal_tables(schema=schema)

if mcp:
    @mcp.tool()
    def hana_tables(schema: Optional[str] = None) -> str:
        """
        Discover HANA tables suitable for PAL analysis.
        
        Args:
            schema: Schema name (default from HANA_SCHEMA env var)
        
        Returns:
            JSON with table list, columns, and PAL suitability
        """
        result = _hana_tables_impl(schema)
        return _json_dumps(result)

# ---------------------------------------------------------------------------
# MCP Tool: execute_sql
# ---------------------------------------------------------------------------
def _execute_sql_impl(sql: str) -> Dict[str, Any]:
    """Execute arbitrary SQL."""
    if not _HANA_AVAILABLE:
        return {"status": "error", "error": "HANA not configured"}
    
    return hana_client.execute_sql(sql)

if mcp:
    @mcp.tool()
    def execute_sql(sql: str) -> str:
        """
        Execute SQL statement on HANA Cloud.
        
        Args:
            sql: SQL statement (SELECT, CREATE, INSERT, etc.)
        
        Returns:
            JSON with results or affected rows
        """
        result = _execute_sql_impl(sql)
        return _json_dumps(result)

# ---------------------------------------------------------------------------
# Health endpoint
# ---------------------------------------------------------------------------
def get_health() -> Dict[str, Any]:
    """Return health status."""
    hana_status = "connected" if _HANA_AVAILABLE else "not_configured"
    
    if _HANA_AVAILABLE:
        try:
            conn_result = hana_client.test_connection()
            if conn_result.get("status") == "success":
                hana_status = "connected"
            else:
                hana_status = f"error: {conn_result.get('error', 'unknown')}"
        except Exception as e:
            hana_status = f"error: {str(e)}"
    
    return {
        "status": "healthy" if hana_status == "connected" else "degraded",
        "service": "ai-core-pal-mcp",
        "version": "1.0.1",
        "hana": hana_status,
        "mcp_available": _MCP_AVAILABLE,
        "tools": [
            "pal_forecast", "pal_anomaly", "pal_clustering",
            "pal_classification", "pal_regression", "hana_tables",
            "execute_sql"
        ],
    }

# ---------------------------------------------------------------------------
# Fallback HTTP server (when FastMCP not available)
# ---------------------------------------------------------------------------
def create_fallback_app():
    """Create a basic aiohttp app when FastMCP is not available."""
    from aiohttp import web
    
    async def health_handler(request):
        return web.json_response(get_health())
    
    async def mcp_handler(request):
        try:
            body = await request.json()
            method = body.get("method", "")
            params = body.get("params", {})
            rpc_id = body.get("id")
            
            if method == "initialize":
                result = {
                    "protocolVersion": "2024-11-05",
                    "capabilities": {"tools": {}},
                    "serverInfo": {"name": "ai-core-pal", "version": "1.0.1"},
                }
            elif method == "tools/list":
                result = {
                    "tools": [
                        {
                            "name": "pal_forecast",
                            "description": "Time series forecasting",
                            "inputSchema": {
                                "type": "object",
                                "properties": {
                                    "table_name": {"type": "string", "description": "Full table name e.g. \"AINUCLEUS.PAL_TIMESERIES_DATA\""},
                                    "value_column": {"type": "string", "description": "Numeric column to forecast"},
                                    "date_column": {"type": "string", "description": "Optional date column for ordering"},
                                    "horizon": {"type": "integer", "description": "Periods to forecast (default 12)"},
                                    "alpha": {"type": "number", "description": "Smoothing parameter 0-1 (default 0.3)"}
                                },
                                "required": ["table_name", "value_column"]
                            }
                        },
                        {
                            "name": "pal_anomaly",
                            "description": "Anomaly detection",
                            "inputSchema": {
                                "type": "object",
                                "properties": {
                                    "table_name": {"type": "string", "description": "Full table name e.g. \"AINUCLEUS.PAL_ANOMALY_DATA\""},
                                    "value_column": {"type": "string", "description": "Numeric column to analyze"},
                                    "multiplier": {"type": "number", "description": "IQR multiplier for bounds (default 1.5)"}
                                },
                                "required": ["table_name", "value_column"]
                            }
                        },
                        {
                            "name": "pal_clustering",
                            "description": "K-Means clustering",
                            "inputSchema": {
                                "type": "object",
                                "properties": {
                                    "table_name": {"type": "string", "description": "Full table name e.g. \"AINUCLEUS.PAL_CLUSTERING_DATA\""},
                                    "feature_columns": {"type": "string", "description": "Comma-separated numeric columns e.g. \"AGE,INCOME,SPEND_SCORE\""},
                                    "n_clusters": {"type": "integer", "description": "Number of clusters (default 3)"}
                                },
                                "required": ["table_name", "feature_columns"]
                            }
                        },
                        {
                            "name": "pal_classification",
                            "description": "Random Forest classification",
                            "inputSchema": {
                                "type": "object",
                                "properties": {
                                    "table_name": {"type": "string", "description": "Full table name e.g. \"AINUCLEUS.PAL_CLASSIFICATION_DATA\""},
                                    "feature_columns": {"type": "string", "description": "Comma-separated feature columns e.g. \"FEATURE_1,FEATURE_2,FEATURE_3\""},
                                    "label_column": {"type": "string", "description": "Label column name e.g. \"LABEL\""},
                                    "n_estimators": {"type": "integer", "description": "Number of trees (default 100)"}
                                },
                                "required": ["table_name", "feature_columns", "label_column"]
                            }
                        },
                        {
                            "name": "pal_regression",
                            "description": "Linear regression",
                            "inputSchema": {
                                "type": "object",
                                "properties": {
                                    "table_name": {"type": "string", "description": "Full table name e.g. \"AINUCLEUS.PAL_REGRESSION_DATA\""},
                                    "feature_columns": {"type": "string", "description": "Comma-separated feature columns e.g. \"X1,X2,X3\""},
                                    "target_column": {"type": "string", "description": "Target column name e.g. \"Y_TARGET\""}
                                },
                                "required": ["table_name", "feature_columns", "target_column"]
                            }
                        },
                        {
                            "name": "hana_tables",
                            "description": "Discover PAL tables",
                            "inputSchema": {
                                "type": "object",
                                "properties": {
                                    "schema": {"type": "string", "description": "Schema name (default from HANA_SCHEMA env var)"}
                                },
                                "required": []
                            }
                        },
                        {
                            "name": "execute_sql",
                            "description": "Execute SQL on HANA Cloud",
                            "inputSchema": {
                                "type": "object",
                                "properties": {
                                    "sql": {"type": "string", "description": "SQL statement (SELECT, CREATE, INSERT, etc.)"}
                                },
                                "required": ["sql"]
                            }
                        },
                    ]
                }
            elif method == "tools/call":
                tool_name = params.get("name", "")
                tool_args = params.get("arguments", {})
                
                if tool_name == "pal_forecast":
                    result = _pal_forecast_impl(**tool_args)
                elif tool_name == "pal_anomaly":
                    result = _pal_anomaly_impl(**tool_args)
                elif tool_name == "pal_clustering":
                    cols = tool_args.get("feature_columns", "").split(",")
                    result = _pal_clustering_impl(
                        tool_args.get("table_name"),
                        [c.strip() for c in cols],
                        tool_args.get("n_clusters", 3),
                    )
                elif tool_name == "pal_classification":
                    cols = tool_args.get("feature_columns", "").split(",")
                    result = _pal_classification_impl(
                        tool_args.get("table_name"),
                        [c.strip() for c in cols],
                        tool_args.get("label_column"),
                        tool_args.get("n_estimators", 100),
                    )
                elif tool_name == "pal_regression":
                    cols = tool_args.get("feature_columns", "").split(",")
                    result = _pal_regression_impl(
                        tool_args.get("table_name"),
                        [c.strip() for c in cols],
                        tool_args.get("target_column"),
                    )
                elif tool_name == "hana_tables":
                    result = _hana_tables_impl(tool_args.get("schema"))
                elif tool_name == "execute_sql":
                    result = _execute_sql_impl(tool_args.get("sql", ""))
                else:
                    result = {"error": f"Unknown tool: {tool_name}"}
                
                result = {"content": [{"type": "text", "text": _json_dumps(result)}]}
            else:
                result = {"error": f"Unknown method: {method}"}
            
            return web.json_response({
                "jsonrpc": "2.0",
                "id": rpc_id,
                "result": result,
            })
        except Exception as e:
            return web.json_response({
                "jsonrpc": "2.0",
                "id": None,
                "error": {"code": -32603, "message": str(e)},
            })
    
    app = web.Application()
    app.router.add_get("/health", health_handler)
    app.router.add_post("/mcp", mcp_handler)
    return app

# ---------------------------------------------------------------------------
# Main entry point
# ---------------------------------------------------------------------------
# Always use the aiohttp fallback for HTTP server mode
# FastMCP is not ASGI-compatible with uvicorn directly
app = create_fallback_app()

if __name__ == "__main__":
    from aiohttp import web
    
    host = os.environ.get("MCP_HOST", "0.0.0.0")
    port = int(os.environ.get("MCP_PORT", "8084"))
    
    logger.info(f"Starting ai-core-pal MCP server on {host}:{port}")
    logger.info(f"HANA available: {_HANA_AVAILABLE}")
    logger.info(f"MCP available: {_MCP_AVAILABLE}")
    
    web.run_app(app, host=host, port=port)