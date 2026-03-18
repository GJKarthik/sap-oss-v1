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

from audit_store import AuditStore, _reset_audit_store
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


if __name__ == "__main__":
    unittest.main()