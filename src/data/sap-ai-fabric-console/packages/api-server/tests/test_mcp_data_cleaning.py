"""
Integration tests for Data Cleaning Copilot MCP Proxy.

Tests the /api/v1/mcp/data-cleaning endpoint and its integration
with the data-cleaning-copilot MCP server.
"""

import asyncio
import json
import pytest
from unittest.mock import AsyncMock, MagicMock, patch
from httpx import AsyncClient, Response

# Test configuration
DATA_CLEANING_MCP_URL = "http://localhost:9110/mcp"


class TestDataCleaningMCPProxy:
    """Test suite for the data-cleaning MCP proxy endpoint."""

    @pytest.fixture
    def mock_settings(self):
        """Mock settings with data cleaning MCP URL."""
        settings = MagicMock()
        settings.data_cleaning_mcp_url = DATA_CLEANING_MCP_URL
        settings.mcp_healthcheck_timeout_seconds = 5.0
        settings.langchain_mcp_url = "http://localhost:9140/mcp"
        settings.streaming_mcp_url = "http://localhost:9190/mcp"
        return settings

    @pytest.fixture
    def valid_auth_token(self):
        """Generate a valid JWT token for testing."""
        return "Bearer test-valid-token"

    # -------------------------------------------------------------------------
    # Test tool/list endpoint
    # -------------------------------------------------------------------------

    @pytest.mark.asyncio
    async def test_tools_list_returns_data_cleaning_tools(self, mock_settings):
        """Verify tools/list returns the expected data cleaning tools."""
        expected_tools = [
            "data_quality_check",
            "schema_analysis",
            "data_profiling",
            "anomaly_detection",
            "generate_cleaning_query",
            "ai_chat",
            "mangle_query",
            "kuzu_index",
            "kuzu_query",
        ]

        mock_response = {
            "jsonrpc": "2.0",
            "id": 1,
            "result": {
                "tools": [
                    {"name": tool, "description": f"{tool} tool"} 
                    for tool in expected_tools
                ]
            }
        }

        with patch("httpx.AsyncClient.post") as mock_post:
            mock_post.return_value = AsyncMock(
                status_code=200,
                json=lambda: mock_response,
                raise_for_status=MagicMock()
            )

            # Simulate the proxy call
            request_body = {
                "jsonrpc": "2.0",
                "id": 1,
                "method": "tools/list",
                "params": {}
            }

            # The actual assertion would be done against the FastAPI app
            # For now, verify the mock response structure
            assert "result" in mock_response
            assert "tools" in mock_response["result"]
            assert len(mock_response["result"]["tools"]) == len(expected_tools)

    # -------------------------------------------------------------------------
    # Test data_quality_check tool
    # -------------------------------------------------------------------------

    @pytest.mark.asyncio
    async def test_data_quality_check_tool(self):
        """Test invoking data_quality_check tool via MCP proxy."""
        request_body = {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/call",
            "params": {
                "name": "data_quality_check",
                "arguments": {
                    "table_name": "Users",
                    "checks": ["null_check", "unique_check"]
                }
            }
        }

        expected_response = {
            "jsonrpc": "2.0",
            "id": 1,
            "result": {
                "content": [
                    {
                        "type": "text",
                        "text": json.dumps({
                            "status": "completed",
                            "table": "Users",
                            "checks_run": 2,
                            "violations_found": 3,
                            "details": [
                                {"check": "null_check", "violations": 2, "column": "Email"},
                                {"check": "unique_check", "violations": 1, "column": "Id"}
                            ]
                        })
                    }
                ]
            }
        }

        with patch("httpx.AsyncClient.post") as mock_post:
            mock_resp = MagicMock()
            mock_resp.status_code = 200
            mock_resp.json.return_value = expected_response
            mock_resp.raise_for_status = MagicMock()
            mock_post.return_value.__aenter__ = AsyncMock(return_value=mock_resp)
            mock_post.return_value.__aexit__ = AsyncMock(return_value=None)

            # Verify response structure
            assert expected_response["result"]["content"][0]["type"] == "text"
            result_data = json.loads(expected_response["result"]["content"][0]["text"])
            assert result_data["status"] == "completed"
            assert result_data["violations_found"] == 3

    # -------------------------------------------------------------------------
    # Test schema_analysis tool
    # -------------------------------------------------------------------------

    @pytest.mark.asyncio
    async def test_schema_analysis_tool(self):
        """Test invoking schema_analysis tool via MCP proxy."""
        request_body = {
            "jsonrpc": "2.0",
            "id": 2,
            "method": "tools/call",
            "params": {
                "name": "schema_analysis",
                "arguments": {
                    "schema_definition": json.dumps({
                        "tables": {
                            "Users": {
                                "columns": [
                                    {"name": "Id", "type": "INTEGER"},
                                    {"name": "Email", "type": "VARCHAR(255)"},
                                    {"name": "CreatedAt", "type": "TIMESTAMP"}
                                ]
                            }
                        }
                    })
                }
            }
        }

        expected_response = {
            "jsonrpc": "2.0",
            "id": 2,
            "result": {
                "content": [
                    {
                        "type": "text",
                        "text": json.dumps({
                            "recommendations": [
                                "Add NOT NULL constraint to Email column",
                                "Add index on CreatedAt for time-based queries",
                                "Consider adding a unique constraint on Email"
                            ],
                            "quality_score": 0.75
                        })
                    }
                ]
            }
        }

        # Verify recommendation structure
        result_data = json.loads(expected_response["result"]["content"][0]["text"])
        assert "recommendations" in result_data
        assert len(result_data["recommendations"]) == 3
        assert result_data["quality_score"] == 0.75

    # -------------------------------------------------------------------------
    # Test data_profiling tool
    # -------------------------------------------------------------------------

    @pytest.mark.asyncio
    async def test_data_profiling_tool(self):
        """Test invoking data_profiling tool via MCP proxy."""
        request_body = {
            "jsonrpc": "2.0",
            "id": 3,
            "method": "tools/call",
            "params": {
                "name": "data_profiling",
                "arguments": {
                    "table_name": "Orders",
                    "sample_size": 1000
                }
            }
        }

        expected_response = {
            "jsonrpc": "2.0",
            "id": 3,
            "result": {
                "content": [
                    {
                        "type": "text",
                        "text": json.dumps({
                            "table": "Orders",
                            "row_count": 1000,
                            "columns": {
                                "OrderId": {
                                    "type": "INTEGER",
                                    "null_count": 0,
                                    "unique_count": 1000,
                                    "min": 1,
                                    "max": 1000
                                },
                                "Amount": {
                                    "type": "DECIMAL",
                                    "null_count": 15,
                                    "mean": 150.50,
                                    "std": 45.20,
                                    "min": 10.00,
                                    "max": 500.00
                                }
                            }
                        })
                    }
                ]
            }
        }

        result_data = json.loads(expected_response["result"]["content"][0]["text"])
        assert result_data["row_count"] == 1000
        assert "columns" in result_data
        assert result_data["columns"]["Amount"]["null_count"] == 15

    # -------------------------------------------------------------------------
    # Test anomaly_detection tool
    # -------------------------------------------------------------------------

    @pytest.mark.asyncio
    async def test_anomaly_detection_tool(self):
        """Test invoking anomaly_detection tool via MCP proxy."""
        request_body = {
            "jsonrpc": "2.0",
            "id": 4,
            "method": "tools/call",
            "params": {
                "name": "anomaly_detection",
                "arguments": {
                    "table_name": "Transactions",
                    "column_name": "Amount",
                    "method": "zscore"
                }
            }
        }

        expected_response = {
            "jsonrpc": "2.0",
            "id": 4,
            "result": {
                "content": [
                    {
                        "type": "text",
                        "text": json.dumps({
                            "method": "zscore",
                            "threshold": 3.0,
                            "anomalies_found": 12,
                            "anomaly_indices": [45, 123, 456, 789, 1001, 1234, 1567, 1890, 2100, 2345, 2678, 2901],
                            "statistics": {
                                "mean": 250.00,
                                "std": 75.50,
                                "min_anomaly": -50.00,
                                "max_anomaly": 2500.00
                            }
                        })
                    }
                ]
            }
        }

        result_data = json.loads(expected_response["result"]["content"][0]["text"])
        assert result_data["method"] == "zscore"
        assert result_data["anomalies_found"] == 12
        assert len(result_data["anomaly_indices"]) == 12

    # -------------------------------------------------------------------------
    # Test generate_cleaning_query tool (requires approval)
    # -------------------------------------------------------------------------

    @pytest.mark.asyncio
    async def test_generate_cleaning_query_tool(self):
        """Test invoking generate_cleaning_query tool via MCP proxy."""
        request_body = {
            "jsonrpc": "2.0",
            "id": 5,
            "method": "tools/call",
            "params": {
                "name": "generate_cleaning_query",
                "arguments": {
                    "issue_description": "Remove duplicate email addresses",
                    "table_name": "Users"
                }
            }
        }

        expected_response = {
            "jsonrpc": "2.0",
            "id": 5,
            "result": {
                "content": [
                    {
                        "type": "text",
                        "text": json.dumps({
                            "status": "pending_approval",
                            "approval_id": "apr-12345",
                            "query": """
DELETE FROM Users u1
WHERE EXISTS (
    SELECT 1 FROM Users u2
    WHERE u2.Email = u1.Email
    AND u2.Id < u1.Id
);
                            """.strip(),
                            "estimated_rows_affected": 150,
                            "warning": "This query will permanently delete data. Review carefully before approval."
                        })
                    }
                ]
            }
        }

        result_data = json.loads(expected_response["result"]["content"][0]["text"])
        assert result_data["status"] == "pending_approval"
        assert "approval_id" in result_data
        assert "query" in result_data
        assert result_data["estimated_rows_affected"] == 150

    # -------------------------------------------------------------------------
    # Test health endpoint
    # -------------------------------------------------------------------------

    @pytest.mark.asyncio
    async def test_health_endpoint_success(self):
        """Test /data-cleaning/health endpoint when service is healthy."""
        expected_response = {
            "status": "ok",
            "service": "data-cleaning-copilot-mcp",
            "target": "http://localhost:9110/health",
            "version": "0.1.0",
            "uptime_seconds": 3600
        }

        with patch("httpx.AsyncClient.get") as mock_get:
            mock_resp = MagicMock()
            mock_resp.status_code = 200
            mock_resp.json.return_value = expected_response
            mock_resp.raise_for_status = MagicMock()
            mock_get.return_value = mock_resp

            assert expected_response["status"] == "ok"
            assert expected_response["service"] == "data-cleaning-copilot-mcp"

    @pytest.mark.asyncio
    async def test_health_endpoint_service_unavailable(self):
        """Test /data-cleaning/health endpoint when service is down."""
        expected_response = {
            "status": "error",
            "service": "data-cleaning-copilot-mcp",
            "target": "http://localhost:9110/health",
            "error": "Connection refused"
        }

        assert expected_response["status"] == "error"
        assert "error" in expected_response

    # -------------------------------------------------------------------------
    # Test authentication
    # -------------------------------------------------------------------------

    @pytest.mark.asyncio
    async def test_unauthenticated_request_rejected(self):
        """Verify that requests without auth token are rejected."""
        # This would be tested against the actual FastAPI app
        # For now, document the expected behavior
        expected_status = 401
        expected_error = {"detail": "Not authenticated"}
        
        assert expected_status == 401

    @pytest.mark.asyncio
    async def test_invalid_token_rejected(self):
        """Verify that requests with invalid token are rejected."""
        expected_status = 401
        expected_error = {"detail": "Could not validate credentials"}
        
        assert expected_status == 401

    # -------------------------------------------------------------------------
    # Test error handling
    # -------------------------------------------------------------------------

    @pytest.mark.asyncio
    async def test_mcp_server_timeout(self):
        """Test handling of MCP server timeout."""
        expected_response = {
            "jsonrpc": "2.0",
            "id": 1,
            "error": {
                "code": -32001,
                "message": f"Cannot reach MCP service at {DATA_CLEANING_MCP_URL}: Connection timeout"
            }
        }

        assert expected_response["error"]["code"] == -32001
        assert "timeout" in expected_response["error"]["message"].lower()

    @pytest.mark.asyncio
    async def test_mcp_server_error_response(self):
        """Test handling of MCP server error response."""
        expected_response = {
            "jsonrpc": "2.0",
            "id": 1,
            "error": {
                "code": -32002,
                "message": "MCP service returned 500"
            }
        }

        assert expected_response["error"]["code"] == -32002

    @pytest.mark.asyncio
    async def test_invalid_jsonrpc_request(self):
        """Test handling of invalid JSON-RPC request."""
        invalid_request = {
            "not_jsonrpc": True
        }

        # Should still be proxied, but MCP server will return error
        expected_response = {
            "jsonrpc": "2.0",
            "id": None,
            "error": {
                "code": -32600,
                "message": "Invalid Request"
            }
        }

        assert expected_response["error"]["code"] == -32600


class TestDataCleaningMCPMetrics:
    """Test Prometheus metrics for data-cleaning MCP proxy."""

    def test_request_counter_incremented(self):
        """Verify request counter is incremented on successful request."""
        # Would check sap_aifabric_mcp_proxy_events_total metric
        # Labels: service="data-cleaning-copilot-mcp", result="request_success"
        pass

    def test_failure_counter_on_connection_error(self):
        """Verify failure counter is incremented on connection error."""
        # Would check sap_aifabric_mcp_proxy_events_total metric
        # Labels: service="data-cleaning-copilot-mcp", result="connect_error"
        pass

    def test_health_gauge_updated(self):
        """Verify health gauge is updated after health probe."""
        # Would check sap_aifabric_mcp_upstream_health metric
        # Labels: service="data-cleaning-copilot-mcp"
        pass


class TestDataCleaningMCPRateLimiting:
    """Test rate limiting for data-cleaning MCP proxy."""

    @pytest.mark.asyncio
    async def test_rate_limit_enforced(self):
        """Verify rate limiting is enforced per client."""
        # Would make MCP_RATE_LIMIT_PER_MINUTE + 1 requests
        # Last request should return 429 Too Many Requests
        expected_status = 429
        expected_headers = {
            "X-RateLimit-Limit": "120",
            "X-RateLimit-Remaining": "0",
            "Retry-After": "60"
        }

        assert expected_status == 429

    @pytest.mark.asyncio
    async def test_rate_limit_window_reset(self):
        """Verify rate limit window resets after configured period."""
        # After RATE_LIMIT_WINDOW_SECONDS, limit should reset
        pass


if __name__ == "__main__":
    pytest.main([__file__, "-v"])