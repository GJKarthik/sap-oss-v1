# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2024 SAP SE
"""Unit tests for durable audit log persistence and MCP query plumbing."""

import os
import sqlite3
import sys
import tempfile
import unittest

_here = os.path.dirname(os.path.abspath(__file__))
_root = os.path.dirname(_here)
for _p in (_here, _root):
    if _p not in sys.path:
        sys.path.insert(0, _p)

from audit_store import (
    AuditStore,
    _reset_audit_store,
    _mask_sensitive_data,
    _is_sensitive_field,
    _MASK_VALUE,
)
import server as server_mod


class TestAuditStore(unittest.TestCase):
    def setUp(self):
        self.tmpdir = tempfile.TemporaryDirectory()
        self.db_path = os.path.join(self.tmpdir.name, "audit.sqlite3")
        self.store = AuditStore(db_path=self.db_path, retention_days=90)

    def tearDown(self):
        _reset_audit_store()
        self.tmpdir.cleanup()

    def test_append_and_query_persist_required_fields(self):
        self.store.append({
            "timestamp": "2026-03-18T10:00:00+00:00",
            "agentId": "world-monitor-agent",
            "action": "invoke",
            "status": "success",
            "toolName": "summarize_news",
            "backend": "vllm",
            "promptHash": "abc123",
            "userId": "user-1",
            "source": "world-monitor-main",
            "payload": {"hello": "world"},
        })

        rows = self.store.query({"agentId": "world-monitor-agent", "source": "world-monitor-main"})
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["toolName"], "summarize_news")
        self.assertEqual(rows[0]["promptHash"], "abc123")
        self.assertEqual(rows[0]["payload"], {"hello": "world"})

    def test_append_only_table_rejects_updates(self):
        record = self.store.append({
            "agentId": "agent-1",
            "action": "invoke",
            "status": "success",
            "toolName": "summarize_news",
            "backend": "vllm",
            "promptHash": "hash-1",
            "userId": "user-1",
            "source": "world-monitor-main",
        })

        with self.assertRaises(sqlite3.DatabaseError):
            with self.store._connect() as conn:  # noqa: SLF001 - intentional trigger verification
                conn.execute("UPDATE audit_logs SET status = ? WHERE id = ?", ("error", record["id"]))


class TestMcpAuditLogHandlers(unittest.TestCase):
    def setUp(self):
        self.tmpdir = tempfile.TemporaryDirectory()
        self.db_path = os.path.join(self.tmpdir.name, "audit.sqlite3")
        self.store = AuditStore(db_path=self.db_path, retention_days=90)
        self.server = server_mod.MCPServer()
        self.original_get_audit_store = server_mod.get_audit_store
        server_mod.get_audit_store = lambda: self.store

    def tearDown(self):
        server_mod.get_audit_store = self.original_get_audit_store
        self.tmpdir.cleanup()

    def test_ingest_then_query_returns_durable_logs(self):
        result = self.server.ingest_audit_logs({
            "entries": [{
                "agentId": "agent-42",
                "action": "tool_call",
                "status": "success",
                "toolName": "get_products",
                "backend": "world-monitor-mcp",
                "promptHash": "hash-42",
                "userId": "user-42",
                "source": "genui-governance",
                "payload": {"id": "entry-42"},
            }]
        })

        self.assertEqual(result["inserted"], 1)
        logs = self.server._handle_get_logs({"source": "genui-governance", "toolName": "get_products", "limit": 10})
        self.assertEqual(logs["count"], 1)
        self.assertEqual(logs["logs"][0]["userId"], "user-42")
        self.assertEqual(logs["logs"][0]["payload"], {"id": "entry-42"})


class TestDataMasking(unittest.TestCase):
    """Tests for sensitive data masking functionality."""

    def test_is_sensitive_field_direct_match(self):
        """Test direct matching of sensitive field names."""
        self.assertTrue(_is_sensitive_field("password"))
        self.assertTrue(_is_sensitive_field("PASSWORD"))
        self.assertTrue(_is_sensitive_field("api_key"))
        self.assertTrue(_is_sensitive_field("ssn"))
        self.assertTrue(_is_sensitive_field("credit_card"))

    def test_is_sensitive_field_partial_match(self):
        """Test partial matching (e.g., user_password, api_token_secret)."""
        self.assertTrue(_is_sensitive_field("user_password"))
        self.assertTrue(_is_sensitive_field("api_token_secret"))
        self.assertTrue(_is_sensitive_field("my_secret_key"))
        self.assertTrue(_is_sensitive_field("bank_account_number"))

    def test_is_sensitive_field_non_sensitive(self):
        """Test that non-sensitive fields are not flagged."""
        self.assertFalse(_is_sensitive_field("username"))
        self.assertFalse(_is_sensitive_field("action"))
        self.assertFalse(_is_sensitive_field("tool_name"))
        self.assertFalse(_is_sensitive_field("timestamp"))
        self.assertFalse(_is_sensitive_field("status"))

    def test_mask_sensitive_data_flat_dict(self):
        """Test masking in a flat dictionary."""
        data = {
            "username": "alice",
            "password": "super_secret_123",
            "email": "alice@example.com",
            "action": "login",
        }
        masked = _mask_sensitive_data(data)

        self.assertEqual(masked["username"], "alice")  # Not sensitive
        self.assertEqual(masked["password"], _MASK_VALUE)
        self.assertEqual(masked["email"], _MASK_VALUE)
        self.assertEqual(masked["action"], "login")  # Not sensitive

    def test_mask_sensitive_data_nested_dict(self):
        """Test masking in nested dictionaries."""
        data = {
            "user": {
                "name": "Bob",
                "login_info": {  # Using non-sensitive parent key
                    "api_key": "sk-1234567890",
                    "token": "jwt-token-here",
                    "method": "oauth",
                }
            },
            "metadata": {"source": "test"},
        }
        masked = _mask_sensitive_data(data)

        self.assertEqual(masked["user"]["name"], "Bob")
        self.assertEqual(masked["user"]["login_info"]["api_key"], _MASK_VALUE)
        self.assertEqual(masked["user"]["login_info"]["token"], _MASK_VALUE)
        self.assertEqual(masked["user"]["login_info"]["method"], "oauth")  # Not masked
        self.assertEqual(masked["metadata"]["source"], "test")

    def test_mask_sensitive_data_with_lists(self):
        """Test masking in structures containing lists."""
        data = {
            "users": [
                {"name": "Alice", "password": "pass1"},
                {"name": "Bob", "password": "pass2"},
            ],
            "api_keys": ["key1", "key2"],  # List itself, not masked (field name not matched)
        }
        masked = _mask_sensitive_data(data)

        self.assertEqual(masked["users"][0]["name"], "Alice")
        self.assertEqual(masked["users"][0]["password"], _MASK_VALUE)
        self.assertEqual(masked["users"][1]["password"], _MASK_VALUE)
        # Note: "api_keys" field itself is masked because it contains "api_key"
        self.assertEqual(masked["api_keys"], _MASK_VALUE)

    def test_mask_sensitive_data_preserves_scalars(self):
        """Test that scalar values pass through unchanged."""
        self.assertEqual(_mask_sensitive_data("hello"), "hello")
        self.assertEqual(_mask_sensitive_data(42), 42)
        self.assertEqual(_mask_sensitive_data(True), True)
        self.assertEqual(_mask_sensitive_data(None), None)

    def test_mask_sensitive_data_sap_fields(self):
        """Test masking of SAP-specific sensitive fields."""
        data = {
            "kunnr": "CUST001234",  # SAP Customer number
            "lifnr": "VEND005678",  # SAP Vendor number
            "salary": 95000,
            "balance": 15000.50,
            "bukrs": "1000",  # Company code - NOT sensitive
        }
        masked = _mask_sensitive_data(data)

        self.assertEqual(masked["kunnr"], _MASK_VALUE)
        self.assertEqual(masked["lifnr"], _MASK_VALUE)
        self.assertEqual(masked["salary"], _MASK_VALUE)
        self.assertEqual(masked["balance"], _MASK_VALUE)
        self.assertEqual(masked["bukrs"], "1000")  # Not masked


class TestAuditStoreMasking(unittest.TestCase):
    """Test that AuditStore applies masking on storage."""

    def setUp(self):
        self.tmpdir = tempfile.TemporaryDirectory()
        self.db_path = os.path.join(self.tmpdir.name, "audit.sqlite3")
        self.store = AuditStore(db_path=self.db_path, retention_days=90)

    def tearDown(self):
        _reset_audit_store()
        self.tmpdir.cleanup()

    def test_payload_is_masked_on_storage(self):
        """Verify that sensitive fields in payload are masked when stored."""
        self.store.append({
            "agentId": "test-agent",
            "action": "login",
            "status": "success",
            "toolName": "authenticate",
            "backend": "auth-service",
            "promptHash": "hash123",
            "userId": "user-1",
            "source": "test",
            "payload": {
                "username": "alice",
                "password": "super_secret_password",
                "api_key": "sk-12345",
                "session_id": "sess-abc",
            },
        })

        rows = self.store.query({"agentId": "test-agent"})
        self.assertEqual(len(rows), 1)

        payload = rows[0]["payload"]
        self.assertEqual(payload["username"], "alice")  # Not masked
        self.assertEqual(payload["password"], _MASK_VALUE)  # Masked
        self.assertEqual(payload["api_key"], _MASK_VALUE)  # Masked
        self.assertEqual(payload["session_id"], "sess-abc")  # Not masked

    def test_nested_sensitive_data_masked(self):
        """Verify that nested sensitive data is also masked."""
        self.store.append({
            "agentId": "test-agent",
            "action": "create_user",
            "status": "success",
            "toolName": "user_service",
            "backend": "backend",
            "promptHash": "hash",
            "userId": "admin",
            "source": "test",
            "payload": {
                "user": {
                    "name": "Bob",
                    "login_data": {  # Non-sensitive parent key
                        "password": "bobpass",
                        "token": "jwt-xxx",
                        "method": "basic",
                    }
                }
            },
        })

        rows = self.store.query({"agentId": "test-agent"})
        payload = rows[0]["payload"]

        self.assertEqual(payload["user"]["name"], "Bob")
        self.assertEqual(payload["user"]["login_data"]["password"], _MASK_VALUE)
        self.assertEqual(payload["user"]["login_data"]["token"], _MASK_VALUE)
        self.assertEqual(payload["user"]["login_data"]["method"], "basic")  # Not masked


if __name__ == "__main__":
    unittest.main()