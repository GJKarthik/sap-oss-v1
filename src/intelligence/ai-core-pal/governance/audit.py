"""
Durable Audit Trail Module for Regulations Compliance

Implements:
- REG-MGF-2.1.2-002: Per-action identity attribution audit
- REG-MGF-2.3.3-002: Continuous monitoring audit trail

Validates against:
- docs/schema/regulations/audit-event.schema.json

Reference: Chapter 10 - Identity Attribution, Section 10.3
"""

import hashlib
import json
import os
import sqlite3
import threading
import uuid
from dataclasses import dataclass, field, asdict
from datetime import datetime, timezone
from enum import Enum
from pathlib import Path
from typing import Optional, Dict, Any, List, Union

from .identity import IdentityEnvelope, AgentIdentity, RequestIdentity


class AuditEventType(str, Enum):
    """Event types as defined in audit-event.schema.json."""
    AGENT_INFERENCE = "agent_inference"
    AGENT_WRITE = "agent_write"
    REVIEW_REQUESTED = "review_requested"
    REVIEW_APPROVED = "review_approved"
    REVIEW_REJECTED = "review_rejected"
    AGENT_ERROR = "agent_error"


class AuditStatus(str, Enum):
    """Outcome status as defined in audit-event.schema.json."""
    SUCCESS = "success"
    FAILURE = "failure"
    PENDING = "pending"
    RESERVED = "reserved"
    ORPHANED = "orphaned"


@dataclass
class AuditAction:
    """Action details for audit events."""
    action_type: str
    entity_id: Optional[str] = None
    input_hash: Optional[str] = None
    output_hash: Optional[str] = None
    before_hash: Optional[str] = None
    after_hash: Optional[str] = None
    reviewer_id: Optional[str] = None
    queue_id: Optional[str] = None
    approver_id: Optional[str] = None
    rejecter_id: Optional[str] = None
    decision: Optional[str] = None
    rationale: Optional[str] = None
    error_code: Optional[str] = None
    stack_trace_hash: Optional[str] = None
    tool_name: Optional[str] = None
    additional_data: Dict[str, Any] = field(default_factory=dict)
    
    def to_dict(self) -> Dict[str, Any]:
        result = {k: v for k, v in asdict(self).items() if v is not None}
        if self.additional_data:
            result.update(self.additional_data)
        return result


@dataclass
class ApprovalStep:
    """Approval chain step as defined in audit-event.schema.json."""
    approver_id: str
    approval_type: str
    timestamp: str = field(default_factory=lambda: datetime.now(timezone.utc).isoformat())
    
    def to_dict(self) -> Dict[str, Any]:
        return asdict(self)


@dataclass
class AuditOutcome:
    """Execution outcome as defined in audit-event.schema.json."""
    status: AuditStatus
    duration_ms: Optional[int] = None
    tokens_used: Optional[int] = None
    error_code: Optional[str] = None
    
    def to_dict(self) -> Dict[str, Any]:
        result = {"status": self.status.value if isinstance(self.status, Enum) else self.status}
        if self.duration_ms is not None:
            result["duration_ms"] = self.duration_ms
        if self.tokens_used is not None:
            result["tokens_used"] = self.tokens_used
        if self.error_code:
            result["error_code"] = self.error_code
        return result


@dataclass
class AuditEvent:
    """
    Immutable audit event as defined in audit-event.schema.json.
    
    Required fields: event_id, event_type, timestamp, request_identity, agent_identity, outcome
    """
    event_id: str
    event_type: AuditEventType
    timestamp: str
    request_identity: RequestIdentity
    agent_identity: AgentIdentity
    outcome: AuditOutcome
    action: Optional[AuditAction] = None
    approval_chain: List[ApprovalStep] = field(default_factory=list)
    
    def to_dict(self) -> Dict[str, Any]:
        result = {
            "event_id": self.event_id,
            "event_type": self.event_type.value if isinstance(self.event_type, Enum) else self.event_type,
            "timestamp": self.timestamp,
            "request_identity": self.request_identity.to_dict(),
            "agent_identity": self.agent_identity.to_dict(),
            "outcome": self.outcome.to_dict()
        }
        if self.action:
            result["action"] = self.action.to_dict()
        if self.approval_chain:
            result["approval_chain"] = [step.to_dict() for step in self.approval_chain]
        return result
    
    def to_json(self) -> str:
        return json.dumps(self.to_dict())
    
    @classmethod
    def generate_id(cls) -> str:
        """Generate unique event ID in format evt-YYYYMMDD-XXXXXX."""
        date_part = datetime.now(timezone.utc).strftime("%Y%m%d")
        random_part = uuid.uuid4().hex[:6]
        return f"evt-{date_part}-{random_part}"


class AuditReservation:
    """
    Audit reservation for reserve-before-action pattern.
    
    Implements the requirement that audit reservation must succeed before action execution.
    """
    
    def __init__(
        self,
        event_id: str,
        event_type: AuditEventType,
        envelope: IdentityEnvelope,
        action: Optional[AuditAction] = None
    ):
        self.event_id = event_id
        self.event_type = event_type
        self.envelope = envelope
        self.action = action
        self.reserved_at = datetime.now(timezone.utc).isoformat()
        self.completed = False
        self.completed_at: Optional[str] = None
        
    def to_pending_event(self) -> AuditEvent:
        """Create pending audit event from reservation."""
        return AuditEvent(
            event_id=self.event_id,
            event_type=self.event_type,
            timestamp=self.reserved_at,
            request_identity=self.envelope.request_identity,
            agent_identity=self.envelope.agent_identity,
            outcome=AuditOutcome(status=AuditStatus.RESERVED),
            action=self.action
        )


class DurableAuditStore:
    """
    Durable audit trail storage using SQLite.
    
    Implements persistent storage requirements for audit events.
    Supports reservation-before-action and completion-after-action pattern.
    """
    
    def __init__(self, db_path: Optional[str] = None):
        if db_path is None:
            # Default to repo-relative path
            db_path = str(Path(__file__).parent.parent.parent.parent.parent / "audit_trail.db")
        
        self.db_path = db_path
        self._local = threading.local()
        self._init_db()
    
    def _get_connection(self) -> sqlite3.Connection:
        """Get thread-local database connection."""
        if not hasattr(self._local, 'conn') or self._local.conn is None:
            self._local.conn = sqlite3.connect(self.db_path, check_same_thread=False)
            self._local.conn.row_factory = sqlite3.Row
        return self._local.conn
    
    def _init_db(self):
        """Initialize database schema."""
        conn = self._get_connection()
        cursor = conn.cursor()
        
        # Main audit events table
        cursor.execute("""
            CREATE TABLE IF NOT EXISTS audit_events (
                event_id TEXT PRIMARY KEY,
                event_type TEXT NOT NULL,
                timestamp TEXT NOT NULL,
                request_id TEXT NOT NULL,
                correlation_id TEXT NOT NULL,
                agent_id TEXT NOT NULL,
                agent_type TEXT NOT NULL,
                status TEXT NOT NULL,
                duration_ms INTEGER,
                tokens_used INTEGER,
                error_code TEXT,
                action_json TEXT,
                approval_chain_json TEXT,
                request_identity_json TEXT NOT NULL,
                agent_identity_json TEXT NOT NULL,
                full_event_json TEXT NOT NULL,
                created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
                completed_at TEXT,
                is_orphaned INTEGER DEFAULT 0
            )
        """)
        
        # Reservations table for pending operations
        cursor.execute("""
            CREATE TABLE IF NOT EXISTS audit_reservations (
                event_id TEXT PRIMARY KEY,
                event_type TEXT NOT NULL,
                envelope_json TEXT NOT NULL,
                action_json TEXT,
                reserved_at TEXT NOT NULL,
                completed INTEGER DEFAULT 0,
                completed_at TEXT,
                is_orphaned INTEGER DEFAULT 0,
                FOREIGN KEY (event_id) REFERENCES audit_events(event_id)
            )
        """)
        
        # Create indexes for efficient queries
        cursor.execute("CREATE INDEX IF NOT EXISTS idx_audit_request_id ON audit_events(request_id)")
        cursor.execute("CREATE INDEX IF NOT EXISTS idx_audit_correlation_id ON audit_events(correlation_id)")
        cursor.execute("CREATE INDEX IF NOT EXISTS idx_audit_agent_id ON audit_events(agent_id)")
        cursor.execute("CREATE INDEX IF NOT EXISTS idx_audit_status ON audit_events(status)")
        cursor.execute("CREATE INDEX IF NOT EXISTS idx_audit_timestamp ON audit_events(timestamp)")
        cursor.execute("CREATE INDEX IF NOT EXISTS idx_reservations_orphaned ON audit_reservations(is_orphaned)")
        
        conn.commit()
    
    def reserve(
        self,
        event_type: AuditEventType,
        envelope: IdentityEnvelope,
        action: Optional[AuditAction] = None
    ) -> AuditReservation:
        """
        Reserve an audit event before action execution.
        
        Per REG-MGF-2.1.2-002: audit reservation must succeed before irreversible action.
        """
        event_id = AuditEvent.generate_id()
        reservation = AuditReservation(
            event_id=event_id,
            event_type=event_type,
            envelope=envelope,
            action=action
        )
        
        conn = self._get_connection()
        cursor = conn.cursor()
        
        cursor.execute("""
            INSERT INTO audit_reservations (event_id, event_type, envelope_json, action_json, reserved_at)
            VALUES (?, ?, ?, ?, ?)
        """, (
            event_id,
            event_type.value,
            envelope.to_json(),
            action.to_dict() if action else None,
            reservation.reserved_at
        ))
        
        # Also insert pending audit event
        pending_event = reservation.to_pending_event()
        self._write_event(pending_event, cursor)
        
        conn.commit()
        return reservation
    
    def complete(
        self,
        reservation: AuditReservation,
        outcome: AuditOutcome,
        action: Optional[AuditAction] = None,
        approval_chain: Optional[List[ApprovalStep]] = None
    ) -> AuditEvent:
        """
        Complete an audit reservation after action execution.
        
        Updates the reserved event with final outcome.
        """
        completed_at = datetime.now(timezone.utc).isoformat()
        
        final_action = action or reservation.action
        final_event = AuditEvent(
            event_id=reservation.event_id,
            event_type=reservation.event_type,
            timestamp=reservation.reserved_at,
            request_identity=reservation.envelope.request_identity,
            agent_identity=reservation.envelope.agent_identity,
            outcome=outcome,
            action=final_action,
            approval_chain=approval_chain or []
        )
        
        conn = self._get_connection()
        cursor = conn.cursor()
        
        # Update reservation as completed
        cursor.execute("""
            UPDATE audit_reservations
            SET completed = 1, completed_at = ?
            WHERE event_id = ?
        """, (completed_at, reservation.event_id))
        
        # Update the audit event with final outcome
        cursor.execute("""
            UPDATE audit_events
            SET status = ?,
                duration_ms = ?,
                tokens_used = ?,
                error_code = ?,
                action_json = ?,
                approval_chain_json = ?,
                full_event_json = ?,
                completed_at = ?
            WHERE event_id = ?
        """, (
            outcome.status.value if isinstance(outcome.status, Enum) else outcome.status,
            outcome.duration_ms,
            outcome.tokens_used,
            outcome.error_code,
            json.dumps(final_action.to_dict()) if final_action else None,
            json.dumps([s.to_dict() for s in (approval_chain or [])]),
            final_event.to_json(),
            completed_at,
            reservation.event_id
        ))
        
        conn.commit()
        reservation.completed = True
        reservation.completed_at = completed_at
        
        return final_event
    
    def write(self, event: AuditEvent) -> str:
        """
        Write an audit event directly (for events that don't require reservation).
        
        Returns the event_id.
        """
        conn = self._get_connection()
        cursor = conn.cursor()
        self._write_event(event, cursor)
        conn.commit()
        return event.event_id
    
    def _write_event(self, event: AuditEvent, cursor: sqlite3.Cursor):
        """Internal method to write event to database."""
        cursor.execute("""
            INSERT OR REPLACE INTO audit_events (
                event_id, event_type, timestamp, request_id, correlation_id,
                agent_id, agent_type, status, duration_ms, tokens_used,
                error_code, action_json, approval_chain_json,
                request_identity_json, agent_identity_json, full_event_json
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, (
            event.event_id,
            event.event_type.value if isinstance(event.event_type, Enum) else event.event_type,
            event.timestamp,
            event.request_identity.request_id,
            event.request_identity.correlation_id,
            event.agent_identity.agent_id,
            event.agent_identity.agent_type,
            event.outcome.status.value if isinstance(event.outcome.status, Enum) else event.outcome.status,
            event.outcome.duration_ms,
            event.outcome.tokens_used,
            event.outcome.error_code,
            json.dumps(event.action.to_dict()) if event.action else None,
            json.dumps([s.to_dict() for s in event.approval_chain]),
            event.request_identity.to_json(),
            event.agent_identity.to_json(),
            event.to_json()
        ))
    
    def query_by_request_id(self, request_id: str) -> List[Dict[str, Any]]:
        """Query audit events by request ID."""
        conn = self._get_connection()
        cursor = conn.cursor()
        cursor.execute(
            "SELECT full_event_json FROM audit_events WHERE request_id = ? ORDER BY timestamp",
            (request_id,)
        )
        return [json.loads(row[0]) for row in cursor.fetchall()]
    
    def query_by_correlation_id(self, correlation_id: str) -> List[Dict[str, Any]]:
        """Query audit events by correlation ID."""
        conn = self._get_connection()
        cursor = conn.cursor()
        cursor.execute(
            "SELECT full_event_json FROM audit_events WHERE correlation_id = ? ORDER BY timestamp",
            (correlation_id,)
        )
        return [json.loads(row[0]) for row in cursor.fetchall()]
    
    def query_by_agent_id(self, agent_id: str, limit: int = 100) -> List[Dict[str, Any]]:
        """Query audit events by agent ID."""
        conn = self._get_connection()
        cursor = conn.cursor()
        cursor.execute(
            "SELECT full_event_json FROM audit_events WHERE agent_id = ? ORDER BY timestamp DESC LIMIT ?",
            (agent_id, limit)
        )
        return [json.loads(row[0]) for row in cursor.fetchall()]
    
    def find_orphaned_reservations(self, timeout_minutes: int = 30) -> List[Dict[str, Any]]:
        """
        Find orphaned reservations (reserved but not completed within timeout).
        
        These indicate actions that may have failed without proper audit completion.
        """
        conn = self._get_connection()
        cursor = conn.cursor()
        cursor.execute("""
            SELECT event_id, event_type, envelope_json, action_json, reserved_at
            FROM audit_reservations
            WHERE completed = 0
            AND datetime(reserved_at) < datetime('now', ?)
        """, (f'-{timeout_minutes} minutes',))
        
        orphans = []
        for row in cursor.fetchall():
            orphans.append({
                "event_id": row[0],
                "event_type": row[1],
                "envelope": json.loads(row[2]),
                "action": json.loads(row[3]) if row[3] else None,
                "reserved_at": row[4]
            })
        return orphans
    
    def mark_orphaned(self, event_id: str):
        """Mark a reservation and its event as orphaned."""
        conn = self._get_connection()
        cursor = conn.cursor()
        
        cursor.execute(
            "UPDATE audit_reservations SET is_orphaned = 1 WHERE event_id = ?",
            (event_id,)
        )
        cursor.execute(
            "UPDATE audit_events SET is_orphaned = 1, status = ? WHERE event_id = ?",
            (AuditStatus.ORPHANED.value, event_id)
        )
        conn.commit()
    
    def get_audit_summary(self, hours: int = 24) -> Dict[str, Any]:
        """Get summary of audit events for monitoring."""
        conn = self._get_connection()
        cursor = conn.cursor()
        
        cursor.execute("""
            SELECT 
                COUNT(*) as total,
                SUM(CASE WHEN status = 'success' THEN 1 ELSE 0 END) as success,
                SUM(CASE WHEN status = 'failure' THEN 1 ELSE 0 END) as failure,
                SUM(CASE WHEN status = 'pending' THEN 1 ELSE 0 END) as pending,
                SUM(CASE WHEN status = 'reserved' THEN 1 ELSE 0 END) as reserved,
                SUM(CASE WHEN is_orphaned = 1 THEN 1 ELSE 0 END) as orphaned,
                AVG(duration_ms) as avg_duration_ms
            FROM audit_events
            WHERE datetime(timestamp) > datetime('now', ?)
        """, (f'-{hours} hours',))
        
        row = cursor.fetchone()
        return {
            "period_hours": hours,
            "total_events": row[0] or 0,
            "success": row[1] or 0,
            "failure": row[2] or 0,
            "pending": row[3] or 0,
            "reserved": row[4] or 0,
            "orphaned": row[5] or 0,
            "avg_duration_ms": row[6]
        }
    
    def close(self):
        """Close database connection."""
        if hasattr(self._local, 'conn') and self._local.conn:
            self._local.conn.close()
            self._local.conn = None


# Global audit store instance
_audit_store: Optional[DurableAuditStore] = None


def get_audit_store(db_path: Optional[str] = None) -> DurableAuditStore:
    """Get the global audit store instance."""
    global _audit_store
    if _audit_store is None:
        _audit_store = DurableAuditStore(db_path)
    return _audit_store


def hash_content(content: Union[str, bytes, Dict, List]) -> str:
    """Generate SHA-256 hash of content for audit purposes."""
    if isinstance(content, (dict, list)):
        content = json.dumps(content, sort_keys=True)
    if isinstance(content, str):
        content = content.encode('utf-8')
    return f"sha256:{hashlib.sha256(content).hexdigest()}"