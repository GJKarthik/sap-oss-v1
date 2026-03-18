"""Durable audit log storage for world-monitor and MCP integrations."""

from __future__ import annotations

import json
import os
import sqlite3
import threading
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any
from uuid import uuid4

MAX_AUDIT_QUERY_LIMIT = 500
_DEFAULT_RETENTION_DAYS = 90
_STORE: "AuditStore | None" = None

# Sensitive field names that should be masked before storage (case-insensitive matching)
_SENSITIVE_FIELDS = frozenset({
    # Authentication
    "password", "passwd", "pwd", "secret", "token", "api_key", "apikey",
    "access_token", "refresh_token", "bearer", "auth", "authorization",
    "credential", "credentials", "private_key", "privatekey",
    # Personal Identifiable Information (PII)
    "ssn", "social_security", "socialsecurity", "tax_id", "taxid",
    "credit_card", "creditcard", "card_number", "cardnumber", "cvv", "cvc",
    "account_number", "accountnumber", "bank_account", "bankaccount", "iban",
    "email", "phone", "telephone", "mobile", "address", "zip", "postal",
    # SAP-specific sensitive fields
    "salary", "compensation", "balance", "amount", "price",
    "kunnr", "lifnr",  # Customer/Vendor numbers in SAP
})
_MASK_VALUE = "***MASKED***"
_MAX_MASK_DEPTH = 10  # Prevent infinite recursion

_CREATE_AUDIT_SCHEMA = """
CREATE TABLE IF NOT EXISTS audit_logs (
    id TEXT PRIMARY KEY,
    timestamp TEXT NOT NULL,
    agent_id TEXT NOT NULL,
    action TEXT NOT NULL,
    status TEXT NOT NULL,
    tool_name TEXT NOT NULL,
    backend TEXT NOT NULL,
    prompt_hash TEXT NOT NULL,
    user_id TEXT NOT NULL,
    source TEXT NOT NULL,
    error TEXT,
    retention_until TEXT NOT NULL,
    payload_json TEXT NOT NULL DEFAULT '{}',
    created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX IF NOT EXISTS idx_audit_logs_timestamp ON audit_logs(timestamp DESC);
CREATE INDEX IF NOT EXISTS idx_audit_logs_agent_id ON audit_logs(agent_id);
CREATE INDEX IF NOT EXISTS idx_audit_logs_status ON audit_logs(status);
CREATE INDEX IF NOT EXISTS idx_audit_logs_tool_name ON audit_logs(tool_name);
CREATE INDEX IF NOT EXISTS idx_audit_logs_source ON audit_logs(source);
CREATE TRIGGER IF NOT EXISTS audit_logs_no_update
BEFORE UPDATE ON audit_logs
BEGIN
    SELECT RAISE(ABORT, 'audit_logs is append-only');
END;
CREATE TRIGGER IF NOT EXISTS audit_logs_no_delete
BEFORE DELETE ON audit_logs
BEGIN
    SELECT RAISE(ABORT, 'audit_logs is append-only');
END;
"""


def _utc_now() -> datetime:
    return datetime.now(timezone.utc)


def _parse_timestamp(value: Any, fallback: datetime | None = None) -> datetime:
    if isinstance(value, datetime):
        return value.astimezone(timezone.utc) if value.tzinfo else value.replace(tzinfo=timezone.utc)
    if isinstance(value, str) and value.strip():
        text = value.strip().replace("Z", "+00:00")
        try:
            parsed = datetime.fromisoformat(text)
            return parsed.astimezone(timezone.utc) if parsed.tzinfo else parsed.replace(tzinfo=timezone.utc)
        except ValueError:
            pass
    return fallback or _utc_now()


def _clamp_retention_days(value: Any, default: int = _DEFAULT_RETENTION_DAYS) -> int:
    try:
        parsed = int(value)
    except (TypeError, ValueError):
        return default
    return max(1, min(parsed, 3650))


def _is_sensitive_field(field_name: str) -> bool:
    """Check if a field name matches any sensitive field pattern."""
    if not isinstance(field_name, str):
        return False
    lower_name = field_name.lower().replace("-", "_").replace(" ", "_")
    # Direct match
    if lower_name in _SENSITIVE_FIELDS:
        return True
    # Partial match (e.g., "user_password", "api_token_secret")
    for sensitive in _SENSITIVE_FIELDS:
        if sensitive in lower_name:
            return True
    return False


def _mask_sensitive_data(data: Any, depth: int = 0) -> Any:
    """Recursively mask sensitive fields in a data structure.

    Args:
        data: The data to mask (dict, list, or scalar)
        depth: Current recursion depth to prevent infinite loops

    Returns:
        A copy of the data with sensitive fields masked
    """
    if depth > _MAX_MASK_DEPTH:
        return data

    if isinstance(data, dict):
        masked = {}
        for key, value in data.items():
            if _is_sensitive_field(str(key)):
                # Mask the entire value
                masked[key] = _MASK_VALUE
            else:
                # Recursively check nested structures
                masked[key] = _mask_sensitive_data(value, depth + 1)
        return masked

    if isinstance(data, list):
        return [_mask_sensitive_data(item, depth + 1) for item in data]

    # Scalars pass through unchanged
    return data


class AuditStore:
    def __init__(self, db_path: str | None = None, retention_days: int | None = None):
        root = Path(__file__).resolve().parent.parent
        self.db_path = str(Path(db_path or os.environ.get("AUDIT_DB_PATH") or (root / "data" / "audit_logs.sqlite3")))
        self.retention_days = _clamp_retention_days(retention_days or os.environ.get("AUDIT_RETENTION_DAYS"), _DEFAULT_RETENTION_DAYS)
        self._schema_ready = False
        self._lock = threading.Lock()

    def _connect(self) -> sqlite3.Connection:
        Path(self.db_path).parent.mkdir(parents=True, exist_ok=True)
        conn = sqlite3.connect(self.db_path, timeout=5, check_same_thread=False)
        conn.row_factory = sqlite3.Row
        conn.execute("PRAGMA journal_mode=WAL")
        conn.execute("PRAGMA synchronous=NORMAL")
        return conn

    def ensure_schema(self) -> None:
        with self._lock:
            if self._schema_ready:
                return
            with self._connect() as conn:
                conn.executescript(_CREATE_AUDIT_SCHEMA)
                conn.commit()
            self._schema_ready = True

    def _normalise_entry(self, entry: dict[str, Any], mask_sensitive: bool = True) -> dict[str, Any]:
        """Normalise and optionally mask an audit entry before storage.

        Args:
            entry: The raw audit entry dict
            mask_sensitive: Whether to mask sensitive fields in the payload (default: True)

        Returns:
            Normalised entry ready for database insertion
        """
        now = _utc_now()
        timestamp = _parse_timestamp(entry.get("timestamp"), now)
        retention_days = _clamp_retention_days(entry.get("retentionDays"), self.retention_days)

        # Get payload and apply masking if enabled
        raw_payload = entry.get("payload", entry)
        payload = _mask_sensitive_data(raw_payload) if mask_sensitive else raw_payload

        return {
            "id": str(entry.get("id") or uuid4()),
            "timestamp": timestamp.isoformat(),
            "agent_id": str(entry.get("agentId") or entry.get("agent_id") or "unknown-agent"),
            "action": str(entry.get("action") or "unknown"),
            "status": str(entry.get("status") or "unknown"),
            "tool_name": str(entry.get("toolName") or entry.get("tool_name") or "unknown"),
            "backend": str(entry.get("backend") or "unknown"),
            "prompt_hash": str(entry.get("promptHash") or entry.get("prompt_hash") or ""),
            "user_id": str(entry.get("userId") or entry.get("user_id") or "anonymous"),
            "source": str(entry.get("source") or "unknown"),
            "error": str(entry.get("error") or "") or None,
            "retention_until": (timestamp + timedelta(days=retention_days)).isoformat(),
            "payload_json": json.dumps(payload, sort_keys=True, default=str),
        }

    def append(self, entry: dict[str, Any]) -> dict[str, Any]:
        self.ensure_schema()
        record = self._normalise_entry(entry)
        with self._connect() as conn:
            conn.execute(
                """
                INSERT INTO audit_logs (
                    id, timestamp, agent_id, action, status, tool_name, backend,
                    prompt_hash, user_id, source, error, retention_until, payload_json
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    record["id"], record["timestamp"], record["agent_id"], record["action"], record["status"],
                    record["tool_name"], record["backend"], record["prompt_hash"], record["user_id"], record["source"],
                    record["error"], record["retention_until"], record["payload_json"],
                ),
            )
            conn.commit()
        return record

    def append_many(self, entries: list[dict[str, Any]]) -> list[dict[str, Any]]:
        self.ensure_schema()
        records = [self._normalise_entry(entry) for entry in entries if isinstance(entry, dict)]
        if not records:
            return []
        with self._connect() as conn:
            conn.executemany(
                """
                INSERT INTO audit_logs (
                    id, timestamp, agent_id, action, status, tool_name, backend,
                    prompt_hash, user_id, source, error, retention_until, payload_json
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                [
                    (
                        record["id"], record["timestamp"], record["agent_id"], record["action"], record["status"],
                        record["tool_name"], record["backend"], record["prompt_hash"], record["user_id"], record["source"],
                        record["error"], record["retention_until"], record["payload_json"],
                    )
                    for record in records
                ],
            )
            conn.commit()
        return records

    def query(self, filters: dict[str, Any] | None = None) -> list[dict[str, Any]]:
        self.ensure_schema()
        filters = filters or {}
        limit = max(1, min(int(filters.get("limit", 100) or 100), MAX_AUDIT_QUERY_LIMIT))
        offset = max(0, int(filters.get("offset", 0) or 0))
        where = ["retention_until >= ?"]
        params: list[Any] = [_utc_now().isoformat()]
        field_map = {
            "agentId": "agent_id",
            "action": "action",
            "status": "status",
            "toolName": "tool_name",
            "backend": "backend",
            "userId": "user_id",
            "source": "source",
        }
        for arg_name, column_name in field_map.items():
            value = filters.get(arg_name)
            if value not in (None, ""):
                where.append(f"{column_name} = ?")
                params.append(str(value))
        if filters.get("from"):
            where.append("timestamp >= ?")
            params.append(_parse_timestamp(filters.get("from")).isoformat())
        if filters.get("to"):
            where.append("timestamp <= ?")
            params.append(_parse_timestamp(filters.get("to")).isoformat())
        sql = (
            "SELECT id, timestamp, agent_id, action, status, tool_name, backend, prompt_hash, user_id, "
            "source, error, retention_until, payload_json FROM audit_logs "
            f"WHERE {' AND '.join(where)} ORDER BY timestamp DESC LIMIT ? OFFSET ?"
        )
        params.extend([limit, offset])
        with self._connect() as conn:
            rows = conn.execute(sql, params).fetchall()
        results = []
        for row in rows:
            payload = None
            payload_text = row["payload_json"] or "{}"
            try:
                payload = json.loads(payload_text)
            except json.JSONDecodeError:
                payload = None
            result = {
                "id": row["id"],
                "timestamp": row["timestamp"],
                "agentId": row["agent_id"],
                "action": row["action"],
                "status": row["status"],
                "toolName": row["tool_name"],
                "backend": row["backend"],
                "promptHash": row["prompt_hash"],
                "userId": row["user_id"],
                "source": row["source"],
                "error": row["error"],
                "retentionUntil": row["retention_until"],
            }
            if payload is not None:
                result["payload"] = payload
            results.append(result)
        return results


def get_audit_store(db_path: str | None = None, retention_days: int | None = None) -> AuditStore:
    global _STORE
    if _STORE is None or db_path is not None or retention_days is not None:
        _STORE = AuditStore(db_path=db_path, retention_days=retention_days)
    return _STORE


def _reset_audit_store() -> None:
    global _STORE
    _STORE = None