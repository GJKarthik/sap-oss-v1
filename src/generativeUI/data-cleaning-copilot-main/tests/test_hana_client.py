# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2024 SAP SE
"""
Unit tests for HANA Cloud client.

Tests cover:
- Data class serialization
- CRUD operations (mocked)
- Graceful degradation when HANA unavailable
- Default check definitions fallback
"""

import pytest
import json
from datetime import datetime, timezone
from unittest.mock import Mock, patch, MagicMock
import sys
import os

# Add parent to path for imports
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from hana.client import (
    ValidationResult,
    CheckDefinition,
    ApprovalRequest,
    AuditLog,
    HANAClient,
    get_client,
    save_validation,
    create_approval,
    audit,
)


class TestDataClasses:
    """Test data class creation and defaults."""
    
    def test_validation_result_defaults(self):
        result = ValidationResult()
        assert result.id is not None
        assert len(result.id) == 36  # UUID format
        assert result.table_name == ""
        assert result.score == 0.0
        assert result.status == ""
        assert result.created_at is not None
        assert isinstance(result.metadata, dict)
    
    def test_validation_result_with_values(self):
        result = ValidationResult(
            table_name="Users",
            check_name="null_check",
            check_type="completeness",
            status="PASS",
            score=98.5,
            violations_count=15,
            execution_time_ms=120,
            created_by="test@example.com",
            metadata={"columns": ["email", "name"]},
        )
        assert result.table_name == "Users"
        assert result.score == 98.5
        assert result.violations_count == 15
        assert result.metadata == {"columns": ["email", "name"]}
    
    def test_check_definition_defaults(self):
        check = CheckDefinition()
        assert check.id is not None
        assert check.threshold == 95.0
        assert check.severity == "warning"
        assert check.active is True
    
    def test_check_definition_with_values(self):
        check = CheckDefinition(
            name="email_format",
            check_type="accuracy",
            description="Validates email format",
            threshold=99.0,
            severity="error",
        )
        assert check.name == "email_format"
        assert check.threshold == 99.0
        assert check.severity == "error"
    
    def test_approval_request_defaults(self):
        request = ApprovalRequest()
        assert request.status == "pending"
        assert request.tool == "generate_cleaning_query"
        assert request.reviewed_by is None
        assert request.reviewed_at is None
    
    def test_approval_request_with_values(self):
        request = ApprovalRequest(
            query="DELETE FROM Users WHERE inactive = true",
            table_name="Users",
            estimated_rows=150,
            requested_by="admin@example.com",
        )
        assert "DELETE" in request.query
        assert request.estimated_rows == 150
        assert request.status == "pending"
    
    def test_audit_log_defaults(self):
        log = AuditLog()
        assert log.timestamp is not None
        assert log.contains_pii is False
        assert log.routing_backend == ""


class TestHANAClientAvailability:
    """Test HANA client availability checks."""
    
    def test_unavailable_when_host_not_configured(self):
        with patch.dict(os.environ, {"HANA_HOST": ""}, clear=False):
            client = HANAClient()
            client._available = None  # Reset cached value
            assert client.available() is False
    
    def test_unavailable_when_hdbcli_not_installed(self):
        with patch.dict(os.environ, {"HANA_HOST": "test.hanacloud.ondemand.com"}, clear=False):
            client = HANAClient()
            client._available = None
            
            # Mock import failure
            with patch.dict(sys.modules, {"hdbcli": None}):
                # Force re-check
                client._available = None
                # This will try to import hdbcli and fail
                assert client.available() is False
    
    def test_cached_availability(self):
        client = HANAClient()
        client._available = True
        assert client.available() is True
        
        client._available = False
        assert client.available() is False


class TestHANAClientFallbacks:
    """Test graceful fallback when HANA is unavailable."""
    
    def test_get_check_definitions_returns_defaults(self):
        client = HANAClient()
        client._available = False
        
        checks = client.get_check_definitions()
        
        assert len(checks) == 3
        check_names = [c.name for c in checks]
        assert "completeness" in check_names
        assert "accuracy" in check_names
        assert "consistency" in check_names
    
    def test_default_checks_have_correct_thresholds(self):
        client = HANAClient()
        client._available = False
        
        checks = client.get_check_definitions()
        check_dict = {c.name: c for c in checks}
        
        assert check_dict["completeness"].threshold == 95.0
        assert check_dict["accuracy"].threshold == 99.0
        assert check_dict["consistency"].threshold == 98.0
    
    def test_save_validation_returns_false_when_unavailable(self):
        client = HANAClient()
        client._available = False
        
        result = ValidationResult(table_name="Test")
        assert client.save_validation_result(result) is False
    
    def test_get_validation_results_returns_empty_when_unavailable(self):
        client = HANAClient()
        client._available = False
        
        results = client.get_validation_results()
        assert results == []
    
    def test_get_pending_approvals_returns_empty_when_unavailable(self):
        client = HANAClient()
        client._available = False
        
        approvals = client.get_pending_approvals()
        assert approvals == []
    
    def test_audit_log_gracefully_fails_when_unavailable(self):
        client = HANAClient()
        client._available = False
        
        log = AuditLog(action="test", actor="test@example.com")
        result = client.log_audit(log)
        assert result is False


class TestHANAClientMockedConnection:
    """Test HANA operations with mocked connection."""
    
    @pytest.fixture
    def mock_hana_client(self):
        """Create a client with mocked connection."""
        client = HANAClient()
        client._available = True
        return client
    
    def test_save_validation_result_success(self, mock_hana_client):
        mock_conn = MagicMock()
        mock_cursor = MagicMock()
        mock_conn.cursor.return_value = mock_cursor
        
        with patch.object(mock_hana_client, 'connection') as mock_context:
            mock_context.return_value.__enter__ = Mock(return_value=mock_conn)
            mock_context.return_value.__exit__ = Mock(return_value=False)
            
            result = ValidationResult(
                table_name="Users",
                check_name="null_check",
                status="PASS",
                score=98.5,
            )
            
            success = mock_hana_client.save_validation_result(result)
            
            assert success is True
            mock_cursor.execute.assert_called_once()
            mock_conn.commit.assert_called_once()
    
    def test_update_approval_status(self, mock_hana_client):
        mock_conn = MagicMock()
        mock_cursor = MagicMock()
        mock_cursor.rowcount = 1
        mock_conn.cursor.return_value = mock_cursor
        
        with patch.object(mock_hana_client, 'connection') as mock_context:
            mock_context.return_value.__enter__ = Mock(return_value=mock_conn)
            mock_context.return_value.__exit__ = Mock(return_value=False)
            
            success = mock_hana_client.update_approval_status(
                approval_id="test-id",
                status="approved",
                reviewed_by="reviewer@example.com",
                reason="Looks good",
            )
            
            assert success is True


class TestConvenienceFunctions:
    """Test module-level convenience functions."""
    
    def test_get_client_singleton(self):
        import hana.client as client_module
        client_module._client = None  # Reset singleton
        
        client1 = get_client()
        client2 = get_client()
        
        assert client1 is client2
    
    def test_save_validation_convenience(self):
        with patch('hana.client.get_client') as mock_get_client:
            mock_client = MagicMock()
            mock_client.save_validation_result.return_value = True
            mock_get_client.return_value = mock_client
            
            result_id = save_validation(
                table_name="Users",
                check_name="null_check",
                check_type="completeness",
                status="PASS",
                score=98.5,
            )
            
            assert result_id is not None
            mock_client.save_validation_result.assert_called_once()
    
    def test_create_approval_convenience(self):
        with patch('hana.client.get_client') as mock_get_client:
            mock_client = MagicMock()
            mock_client.save_approval_request.return_value = True
            mock_get_client.return_value = mock_client
            
            approval_id = create_approval(
                query="DELETE FROM Users WHERE inactive = true",
                table_name="Users",
                requested_by="admin@example.com",
                estimated_rows=150,
            )
            
            assert approval_id is not None
            mock_client.save_approval_request.assert_called_once()
    
    def test_audit_convenience(self):
        with patch('hana.client.get_client') as mock_get_client:
            mock_client = MagicMock()
            mock_get_client.return_value = mock_client
            
            audit(
                action="tool_call",
                actor="user@example.com",
                resource_type="validation",
                resource_id="val-123",
                backend="vllm",
                contains_pii=True,
            )
            
            mock_client.log_audit.assert_called_once()
            
            # Verify the AuditLog was created correctly
            call_args = mock_client.log_audit.call_args[0][0]
            assert call_args.action == "tool_call"
            assert call_args.actor == "user@example.com"
            assert call_args.contains_pii is True


class TestSchemaInitialization:
    """Test schema and table creation."""
    
    def test_initialize_schema_when_unavailable(self):
        client = HANAClient()
        client._available = False
        
        result = client.initialize_schema()
        assert result is False
    
    def test_table_definitions_exist(self):
        assert "VALIDATION_RESULTS" in HANAClient.TABLES
        assert "CHECK_DEFINITIONS" in HANAClient.TABLES
        assert "APPROVAL_REQUESTS" in HANAClient.TABLES
        assert "AUDIT_LOGS" in HANAClient.TABLES
    
    def test_table_ddl_contains_required_columns(self):
        val_ddl = HANAClient.TABLES["VALIDATION_RESULTS"]
        assert "ID" in val_ddl
        assert "TABLE_NAME" in val_ddl
        assert "SCORE" in val_ddl
        assert "STATUS" in val_ddl
        
        audit_ddl = HANAClient.TABLES["AUDIT_LOGS"]
        assert "ROUTING_BACKEND" in audit_ddl
        assert "CONTAINS_PII" in audit_ddl