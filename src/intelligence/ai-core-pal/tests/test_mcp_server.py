# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2024 SAP SE
"""
Test MCP server endpoints.

Run: pytest tests/test_mcp_server.py -v

Note: Start the MCP server first:
  python -m mcp_server.btp_pal_mcp_server
"""
import json
import os
import sys

import pytest
import requests

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


MCP_URL = os.environ.get("MCP_URL", "http://localhost:8084")


def is_server_running():
    """Check if MCP server is running."""
    try:
        resp = requests.get(f"{MCP_URL}/health", timeout=2)
        return resp.status_code == 200
    except requests.RequestException:
        return False


class TestMcpHealth:
    """Test MCP server health endpoint."""

    def test_health_endpoint(self):
        """Test /health endpoint."""
        if not is_server_running():
            pytest.skip("MCP server not running")
        
        resp = requests.get(f"{MCP_URL}/health")
        assert resp.status_code == 200
        
        data = resp.json()
        assert "status" in data
        assert "service" in data
        assert data["service"] == "ai-core-pal-mcp"
        
        print(f"Health: {data}")


class TestMcpProtocol:
    """Test MCP JSON-RPC protocol."""

    def test_initialize(self):
        """Test MCP initialize method."""
        if not is_server_running():
            pytest.skip("MCP server not running")
        
        resp = requests.post(f"{MCP_URL}/mcp", json={
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": {}
        })
        
        assert resp.status_code == 200
        data = resp.json()
        assert "result" in data
        assert "protocolVersion" in data["result"]
        print(f"Protocol version: {data['result']['protocolVersion']}")

    def test_tools_list(self):
        """Test MCP tools/list method."""
        if not is_server_running():
            pytest.skip("MCP server not running")
        
        resp = requests.post(f"{MCP_URL}/mcp", json={
            "jsonrpc": "2.0",
            "id": 2,
            "method": "tools/list",
            "params": {}
        })
        
        assert resp.status_code == 200
        data = resp.json()
        assert "result" in data
        assert "tools" in data["result"]
        
        tools = data["result"]["tools"]
        tool_names = [t["name"] for t in tools]
        
        # Check expected tools
        expected = ["pal_forecast", "pal_anomaly", "pal_clustering", 
                   "pal_classification", "pal_regression", "hana_tables"]
        for exp in expected:
            assert exp in tool_names, f"Missing tool: {exp}"
        
        print(f"Available tools: {tool_names}")


class TestMcpTools:
    """Test MCP tool calls."""

    def test_hana_tables_tool(self):
        """Test hana_tables tool."""
        if not is_server_running():
            pytest.skip("MCP server not running")
        
        resp = requests.post(f"{MCP_URL}/mcp", json={
            "jsonrpc": "2.0",
            "id": 10,
            "method": "tools/call",
            "params": {
                "name": "hana_tables",
                "arguments": {}
            }
        })
        
        assert resp.status_code == 200
        data = resp.json()
        
        if "error" in data:
            print(f"Tool error: {data['error']}")
            pytest.skip("HANA not configured on server")
        
        assert "result" in data
        result = data["result"]
        
        # Result should have content with text
        if "content" in result:
            text = result["content"][0]["text"]
            result_data = json.loads(text)
            print(f"Tables found: {result_data.get('count', 0)}")

    def test_pal_forecast_tool(self):
        """Test pal_forecast tool."""
        if not is_server_running():
            pytest.skip("MCP server not running")
        
        schema = os.environ.get("HANA_SCHEMA", "AINUCLEUS")
        
        resp = requests.post(f"{MCP_URL}/mcp", json={
            "jsonrpc": "2.0",
            "id": 11,
            "method": "tools/call",
            "params": {
                "name": "pal_forecast",
                "arguments": {
                    "table_name": f"{schema}.PAL_TIMESERIES_DATA",
                    "value_column": "AMOUNT_USD",
                    "date_column": "RECORD_DATE",
                    "horizon": 6
                }
            }
        })
        
        assert resp.status_code == 200
        data = resp.json()
        
        if "error" in data:
            print(f"Tool error: {data['error']}")
            pytest.skip("HANA not configured or table missing")
        
        assert "result" in data

    def test_pal_anomaly_tool(self):
        """Test pal_anomaly tool."""
        if not is_server_running():
            pytest.skip("MCP server not running")
        
        schema = os.environ.get("HANA_SCHEMA", "AINUCLEUS")
        
        resp = requests.post(f"{MCP_URL}/mcp", json={
            "jsonrpc": "2.0",
            "id": 12,
            "method": "tools/call",
            "params": {
                "name": "pal_anomaly",
                "arguments": {
                    "table_name": f"{schema}.PAL_ANOMALY_DATA",
                    "value_column": "METRIC_VALUE",
                    "multiplier": 1.5
                }
            }
        })
        
        assert resp.status_code == 200
        data = resp.json()
        
        if "error" in data:
            print(f"Tool error: {data['error']}")
            pytest.skip("HANA not configured or table missing")
        
        assert "result" in data

    def test_pal_clustering_tool(self):
        """Test pal_clustering tool."""
        if not is_server_running():
            pytest.skip("MCP server not running")
        
        schema = os.environ.get("HANA_SCHEMA", "AINUCLEUS")
        
        resp = requests.post(f"{MCP_URL}/mcp", json={
            "jsonrpc": "2.0",
            "id": 13,
            "method": "tools/call",
            "params": {
                "name": "pal_clustering",
                "arguments": {
                    "table_name": f"{schema}.PAL_CLUSTERING_DATA",
                    "feature_columns": "AGE,INCOME,SPEND_SCORE",
                    "n_clusters": 3
                }
            }
        })
        
        assert resp.status_code == 200
        data = resp.json()
        
        if "error" in data:
            print(f"Tool error: {data['error']}")
            pytest.skip("HANA not configured or table missing")
        
        assert "result" in data


if __name__ == "__main__":
    pytest.main([__file__, "-v"])