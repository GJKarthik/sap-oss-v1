# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2024 SAP SE
"""
HANA Cloud Client for Data Cleaning Copilot

Provides persistence layer for:
- Validation results
- Check definitions
- Approval workflow state
- Audit logs
"""

import json
import os
import logging
from datetime import datetime, timezone
from typing import Any, Dict, List, Optional
from dataclasses import dataclass, asdict, field
from contextlib import contextmanager
import uuid

logger = logging.getLogger("data-cleaning-copilot.hana")

# =============================================================================
# Data Classes
# =============================================================================

@dataclass
class ValidationResult:
    """Represents a validation check result."""
    id: str = field(default_factory=lambda: str(uuid.uuid4()))
    table_name: str = ""
    check_name: str = ""
    check_type: str = ""  # completeness, accuracy, consistency
    status: str = ""  # PASS, WARN, FAIL
    score: float = 0.0
    violations_count: int = 0
    execution_time_ms: int = 0
    created_at: str = field(default_factory=lambda: datetime.now(timezone.utc).isoformat())
    created_by: str = ""
    metadata: Dict[str, Any] = field(default_factory=dict)


@dataclass
class CheckDefinition:
    """Defines a reusable data quality check."""
    id: str = field(default_factory=lambda: str(uuid.uuid4()))
    name: str = ""
    check_type: str = ""
    description: str = ""
    sql_template: str = ""
    threshold: float = 95.0
    severity: str = "warning"  # info, warning, error, critical
    active: bool = True
    created_at: str = field(default_factory=lambda: datetime.now(timezone.utc).isoformat())
    updated_at: str = ""
    metadata: Dict[str, Any] = field(default_factory=dict)


@dataclass
class ApprovalRequest:
    """Represents a query approval request."""
    id: str = field(default_factory=lambda: str(uuid.uuid4()))
    tool: str = "generate_cleaning_query"
    query: str = ""
    table_name: str = ""
    estimated_rows: int = 0
    status: str = "pending"  # pending, approved, rejected
    requested_by: str = ""
    requested_at: str = field(default_factory=lambda: datetime.now(timezone.utc).isoformat())
    reviewed_by: Optional[str] = None
    reviewed_at: Optional[str] = None
    review_reason: Optional[str] = None
    metadata: Dict[str, Any] = field(default_factory=dict)


@dataclass
class AuditLog:
    """Audit log entry."""
    id: str = field(default_factory=lambda: str(uuid.uuid4()))
    timestamp: str = field(default_factory=lambda: datetime.now(timezone.utc).isoformat())
    action: str = ""  # tool_call, approval, rejection, query_execution
    actor: str = ""
    resource_type: str = ""  # validation, check, approval
    resource_id: str = ""
    details: Dict[str, Any] = field(default_factory=dict)
    routing_backend: str = ""  # aicore, vllm, local
    contains_pii: bool = False


# =============================================================================
# HANA Client
# =============================================================================

class HANAClient:
    """
    HANA Cloud client for data persistence.
    
    Uses hdbcli for connection management and provides methods for
    storing validation results, check definitions, and approval workflow.
    """
    
    # Schema for data cleaning copilot tables
    SCHEMA = os.environ.get("HANA_SCHEMA", "DCC_STORE")
    
    # Table definitions
    TABLES = {
        "VALIDATION_RESULTS": """
            CREATE COLUMN TABLE IF NOT EXISTS {schema}.VALIDATION_RESULTS (
                ID NVARCHAR(36) PRIMARY KEY,
                TABLE_NAME NVARCHAR(256),
                CHECK_NAME NVARCHAR(256),
                CHECK_TYPE NVARCHAR(64),
                STATUS NVARCHAR(16),
                SCORE DECIMAL(5,2),
                VIOLATIONS_COUNT INTEGER,
                EXECUTION_TIME_MS INTEGER,
                CREATED_AT TIMESTAMP,
                CREATED_BY NVARCHAR(256),
                METADATA NCLOB
            )
        """,
        "CHECK_DEFINITIONS": """
            CREATE COLUMN TABLE IF NOT EXISTS {schema}.CHECK_DEFINITIONS (
                ID NVARCHAR(36) PRIMARY KEY,
                NAME NVARCHAR(256),
                CHECK_TYPE NVARCHAR(64),
                DESCRIPTION NVARCHAR(1000),
                SQL_TEMPLATE NCLOB,
                THRESHOLD DECIMAL(5,2),
                SEVERITY NVARCHAR(16),
                ACTIVE BOOLEAN,
                CREATED_AT TIMESTAMP,
                UPDATED_AT TIMESTAMP,
                METADATA NCLOB
            )
        """,
        "APPROVAL_REQUESTS": """
            CREATE COLUMN TABLE IF NOT EXISTS {schema}.APPROVAL_REQUESTS (
                ID NVARCHAR(36) PRIMARY KEY,
                TOOL NVARCHAR(64),
                QUERY_TEXT NCLOB,
                TABLE_NAME NVARCHAR(256),
                ESTIMATED_ROWS INTEGER,
                STATUS NVARCHAR(16),
                REQUESTED_BY NVARCHAR(256),
                REQUESTED_AT TIMESTAMP,
                REVIEWED_BY NVARCHAR(256),
                REVIEWED_AT TIMESTAMP,
                REVIEW_REASON NVARCHAR(1000),
                METADATA NCLOB
            )
        """,
        "AUDIT_LOGS": """
            CREATE COLUMN TABLE IF NOT EXISTS {schema}.AUDIT_LOGS (
                ID NVARCHAR(36) PRIMARY KEY,
                TIMESTAMP TIMESTAMP,
                ACTION NVARCHAR(64),
                ACTOR NVARCHAR(256),
                RESOURCE_TYPE NVARCHAR(64),
                RESOURCE_ID NVARCHAR(36),
                DETAILS NCLOB,
                ROUTING_BACKEND NVARCHAR(16),
                CONTAINS_PII BOOLEAN
            )
        """,
    }
    
    def __init__(self):
        self._conn = None
        self._connection_params = {
            "address": os.environ.get("HANA_HOST", ""),
            "port": int(os.environ.get("HANA_PORT", "443")),
            "user": os.environ.get("HANA_USER", ""),
            "password": os.environ.get("HANA_PASSWORD", ""),
            "encrypt": os.environ.get("HANA_ENCRYPT", "true").lower() == "true",
            "sslValidateCertificate": False,
        }
        self._available = None
    
    def available(self) -> bool:
        """Check if HANA connection is available."""
        if self._available is not None:
            return self._available
        
        if not self._connection_params["address"]:
            logger.debug("HANA_HOST not configured")
            self._available = False
            return False
        
        try:
            import hdbcli
            self._available = True
        except ImportError:
            logger.debug("hdbcli not installed")
            self._available = False
        
        return self._available
    
    @contextmanager
    def connection(self):
        """Get a HANA connection context manager."""
        if not self.available():
            raise RuntimeError("HANA connection not available")
        
        from hdbcli import dbapi
        
        conn = dbapi.connect(**self._connection_params)
        try:
            yield conn
        finally:
            conn.close()
    
    def initialize_schema(self) -> bool:
        """Create schema and tables if they don't exist."""
        if not self.available():
            return False
        
        try:
            with self.connection() as conn:
                cursor = conn.cursor()
                
                # Create schema
                try:
                    cursor.execute(f"CREATE SCHEMA {self.SCHEMA}")
                except Exception:
                    pass  # Schema may already exist
                
                # Create tables
                for table_name, ddl in self.TABLES.items():
                    try:
                        cursor.execute(ddl.format(schema=self.SCHEMA))
                        logger.info(f"Created table {self.SCHEMA}.{table_name}")
                    except Exception as e:
                        logger.debug(f"Table {table_name} may already exist: {e}")
                
                conn.commit()
                return True
        except Exception as e:
            logger.error(f"Failed to initialize schema: {e}")
            return False
    
    # -------------------------------------------------------------------------
    # Validation Results
    # -------------------------------------------------------------------------
    
    def save_validation_result(self, result: ValidationResult) -> bool:
        """Save a validation result to HANA."""
        if not self.available():
            logger.debug("HANA not available, skipping save")
            return False
        
        try:
            with self.connection() as conn:
                cursor = conn.cursor()
                cursor.execute(
                    f"""
                    UPSERT {self.SCHEMA}.VALIDATION_RESULTS
                    (ID, TABLE_NAME, CHECK_NAME, CHECK_TYPE, STATUS, SCORE,
                     VIOLATIONS_COUNT, EXECUTION_TIME_MS, CREATED_AT, CREATED_BY, METADATA)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    (
                        result.id,
                        result.table_name,
                        result.check_name,
                        result.check_type,
                        result.status,
                        result.score,
                        result.violations_count,
                        result.execution_time_ms,
                        result.created_at,
                        result.created_by,
                        json.dumps(result.metadata),
                    ),
                )
                conn.commit()
                return True
        except Exception as e:
            logger.error(f"Failed to save validation result: {e}")
            return False
    
    def get_validation_results(
        self,
        table_name: str = None,
        check_type: str = None,
        limit: int = 100
    ) -> List[ValidationResult]:
        """Retrieve validation results with optional filters."""
        if not self.available():
            return []
        
        try:
            with self.connection() as conn:
                cursor = conn.cursor()
                
                where_clauses = []
                params = []
                
                if table_name:
                    where_clauses.append("TABLE_NAME = ?")
                    params.append(table_name)
                if check_type:
                    where_clauses.append("CHECK_TYPE = ?")
                    params.append(check_type)
                
                where_sql = f"WHERE {' AND '.join(where_clauses)}" if where_clauses else ""
                
                cursor.execute(
                    f"""
                    SELECT ID, TABLE_NAME, CHECK_NAME, CHECK_TYPE, STATUS, SCORE,
                           VIOLATIONS_COUNT, EXECUTION_TIME_MS, CREATED_AT, CREATED_BY, METADATA
                    FROM {self.SCHEMA}.VALIDATION_RESULTS
                    {where_sql}
                    ORDER BY CREATED_AT DESC
                    LIMIT ?
                    """,
                    params + [limit],
                )
                
                results = []
                for row in cursor.fetchall():
                    results.append(ValidationResult(
                        id=row[0],
                        table_name=row[1],
                        check_name=row[2],
                        check_type=row[3],
                        status=row[4],
                        score=float(row[5]) if row[5] else 0.0,
                        violations_count=row[6] or 0,
                        execution_time_ms=row[7] or 0,
                        created_at=str(row[8]) if row[8] else "",
                        created_by=row[9] or "",
                        metadata=json.loads(row[10]) if row[10] else {},
                    ))
                return results
        except Exception as e:
            logger.error(f"Failed to get validation results: {e}")
            return []
    
    # -------------------------------------------------------------------------
    # Check Definitions
    # -------------------------------------------------------------------------
    
    def save_check_definition(self, check: CheckDefinition) -> bool:
        """Save a check definition to HANA."""
        if not self.available():
            return False
        
        try:
            with self.connection() as conn:
                cursor = conn.cursor()
                cursor.execute(
                    f"""
                    UPSERT {self.SCHEMA}.CHECK_DEFINITIONS
                    (ID, NAME, CHECK_TYPE, DESCRIPTION, SQL_TEMPLATE, THRESHOLD,
                     SEVERITY, ACTIVE, CREATED_AT, UPDATED_AT, METADATA)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    (
                        check.id,
                        check.name,
                        check.check_type,
                        check.description,
                        check.sql_template,
                        check.threshold,
                        check.severity,
                        check.active,
                        check.created_at,
                        check.updated_at or datetime.now(timezone.utc).isoformat(),
                        json.dumps(check.metadata),
                    ),
                )
                conn.commit()
                return True
        except Exception as e:
            logger.error(f"Failed to save check definition: {e}")
            return False
    
    def get_check_definitions(self, active_only: bool = True) -> List[CheckDefinition]:
        """Retrieve check definitions."""
        if not self.available():
            return self._get_default_checks()
        
        try:
            with self.connection() as conn:
                cursor = conn.cursor()
                where_sql = "WHERE ACTIVE = TRUE" if active_only else ""
                cursor.execute(
                    f"""
                    SELECT ID, NAME, CHECK_TYPE, DESCRIPTION, SQL_TEMPLATE, THRESHOLD,
                           SEVERITY, ACTIVE, CREATED_AT, UPDATED_AT, METADATA
                    FROM {self.SCHEMA}.CHECK_DEFINITIONS
                    {where_sql}
                    ORDER BY NAME
                    """,
                )
                
                results = []
                for row in cursor.fetchall():
                    results.append(CheckDefinition(
                        id=row[0],
                        name=row[1],
                        check_type=row[2],
                        description=row[3] or "",
                        sql_template=row[4] or "",
                        threshold=float(row[5]) if row[5] else 95.0,
                        severity=row[6] or "warning",
                        active=bool(row[7]),
                        created_at=str(row[8]) if row[8] else "",
                        updated_at=str(row[9]) if row[9] else "",
                        metadata=json.loads(row[10]) if row[10] else {},
                    ))
                return results if results else self._get_default_checks()
        except Exception as e:
            logger.error(f"Failed to get check definitions: {e}")
            return self._get_default_checks()
    
    def _get_default_checks(self) -> List[CheckDefinition]:
        """Return default check definitions when HANA is unavailable."""
        return [
            CheckDefinition(
                id="default-completeness",
                name="completeness",
                check_type="completeness",
                description="Check for NULL values in columns",
                threshold=95.0,
                severity="warning",
            ),
            CheckDefinition(
                id="default-accuracy",
                name="accuracy",
                check_type="accuracy",
                description="Check data format and constraints",
                threshold=99.0,
                severity="error",
            ),
            CheckDefinition(
                id="default-consistency",
                name="consistency",
                check_type="consistency",
                description="Check referential integrity",
                threshold=98.0,
                severity="warning",
            ),
        ]
    
    # -------------------------------------------------------------------------
    # Approval Requests
    # -------------------------------------------------------------------------
    
    def save_approval_request(self, request: ApprovalRequest) -> bool:
        """Save an approval request to HANA."""
        if not self.available():
            return False
        
        try:
            with self.connection() as conn:
                cursor = conn.cursor()
                cursor.execute(
                    f"""
                    UPSERT {self.SCHEMA}.APPROVAL_REQUESTS
                    (ID, TOOL, QUERY_TEXT, TABLE_NAME, ESTIMATED_ROWS, STATUS,
                     REQUESTED_BY, REQUESTED_AT, REVIEWED_BY, REVIEWED_AT, REVIEW_REASON, METADATA)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    (
                        request.id,
                        request.tool,
                        request.query,
                        request.table_name,
                        request.estimated_rows,
                        request.status,
                        request.requested_by,
                        request.requested_at,
                        request.reviewed_by,
                        request.reviewed_at,
                        request.review_reason,
                        json.dumps(request.metadata),
                    ),
                )
                conn.commit()
                return True
        except Exception as e:
            logger.error(f"Failed to save approval request: {e}")
            return False
    
    def get_pending_approvals(self) -> List[ApprovalRequest]:
        """Get all pending approval requests."""
        if not self.available():
            return []
        
        try:
            with self.connection() as conn:
                cursor = conn.cursor()
                cursor.execute(
                    f"""
                    SELECT ID, TOOL, QUERY_TEXT, TABLE_NAME, ESTIMATED_ROWS, STATUS,
                           REQUESTED_BY, REQUESTED_AT, REVIEWED_BY, REVIEWED_AT, REVIEW_REASON, METADATA
                    FROM {self.SCHEMA}.APPROVAL_REQUESTS
                    WHERE STATUS = 'pending'
                    ORDER BY REQUESTED_AT DESC
                    """,
                )
                
                results = []
                for row in cursor.fetchall():
                    results.append(ApprovalRequest(
                        id=row[0],
                        tool=row[1],
                        query=row[2] or "",
                        table_name=row[3] or "",
                        estimated_rows=row[4] or 0,
                        status=row[5],
                        requested_by=row[6] or "",
                        requested_at=str(row[7]) if row[7] else "",
                        reviewed_by=row[8],
                        reviewed_at=str(row[9]) if row[9] else None,
                        review_reason=row[10],
                        metadata=json.loads(row[11]) if row[11] else {},
                    ))
                return results
        except Exception as e:
            logger.error(f"Failed to get pending approvals: {e}")
            return []
    
    def update_approval_status(
        self,
        approval_id: str,
        status: str,
        reviewed_by: str,
        reason: str = None
    ) -> bool:
        """Update the status of an approval request."""
        if not self.available():
            return False
        
        try:
            with self.connection() as conn:
                cursor = conn.cursor()
                cursor.execute(
                    f"""
                    UPDATE {self.SCHEMA}.APPROVAL_REQUESTS
                    SET STATUS = ?, REVIEWED_BY = ?, REVIEWED_AT = ?, REVIEW_REASON = ?
                    WHERE ID = ?
                    """,
                    (status, reviewed_by, datetime.now(timezone.utc).isoformat(), reason, approval_id),
                )
                conn.commit()
                return cursor.rowcount > 0
        except Exception as e:
            logger.error(f"Failed to update approval status: {e}")
            return False
    
    # -------------------------------------------------------------------------
    # Audit Logs
    # -------------------------------------------------------------------------
    
    def log_audit(self, log: AuditLog) -> bool:
        """Write an audit log entry."""
        if not self.available():
            logger.debug(f"Audit (local): {log.action} by {log.actor} on {log.resource_type}/{log.resource_id}")
            return False
        
        try:
            with self.connection() as conn:
                cursor = conn.cursor()
                cursor.execute(
                    f"""
                    INSERT INTO {self.SCHEMA}.AUDIT_LOGS
                    (ID, TIMESTAMP, ACTION, ACTOR, RESOURCE_TYPE, RESOURCE_ID,
                     DETAILS, ROUTING_BACKEND, CONTAINS_PII)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    (
                        log.id,
                        log.timestamp,
                        log.action,
                        log.actor,
                        log.resource_type,
                        log.resource_id,
                        json.dumps(log.details),
                        log.routing_backend,
                        log.contains_pii,
                    ),
                )
                conn.commit()
                return True
        except Exception as e:
            logger.error(f"Failed to write audit log: {e}")
            return False
    
    def get_audit_logs(
        self,
        resource_type: str = None,
        resource_id: str = None,
        limit: int = 100
    ) -> List[AuditLog]:
        """Retrieve audit logs."""
        if not self.available():
            return []
        
        try:
            with self.connection() as conn:
                cursor = conn.cursor()
                
                where_clauses = []
                params = []
                
                if resource_type:
                    where_clauses.append("RESOURCE_TYPE = ?")
                    params.append(resource_type)
                if resource_id:
                    where_clauses.append("RESOURCE_ID = ?")
                    params.append(resource_id)
                
                where_sql = f"WHERE {' AND '.join(where_clauses)}" if where_clauses else ""
                
                cursor.execute(
                    f"""
                    SELECT ID, TIMESTAMP, ACTION, ACTOR, RESOURCE_TYPE, RESOURCE_ID,
                           DETAILS, ROUTING_BACKEND, CONTAINS_PII
                    FROM {self.SCHEMA}.AUDIT_LOGS
                    {where_sql}
                    ORDER BY TIMESTAMP DESC
                    LIMIT ?
                    """,
                    params + [limit],
                )
                
                results = []
                for row in cursor.fetchall():
                    results.append(AuditLog(
                        id=row[0],
                        timestamp=str(row[1]) if row[1] else "",
                        action=row[2],
                        actor=row[3] or "",
                        resource_type=row[4],
                        resource_id=row[5] or "",
                        details=json.loads(row[6]) if row[6] else {},
                        routing_backend=row[7] or "",
                        contains_pii=bool(row[8]),
                    ))
                return results
        except Exception as e:
            logger.error(f"Failed to get audit logs: {e}")
            return []


# =============================================================================
# Singleton Instance
# =============================================================================

_client: Optional[HANAClient] = None


def get_client() -> HANAClient:
    """Get or create the global HANA client instance."""
    global _client
    if _client is None:
        _client = HANAClient()
    return _client


# =============================================================================
# Convenience Functions
# =============================================================================

def save_validation(
    table_name: str,
    check_name: str,
    check_type: str,
    status: str,
    score: float,
    **kwargs
) -> Optional[str]:
    """
    Save a validation result and return its ID.
    
    Example:
        >>> result_id = save_validation(
        ...     table_name="Users",
        ...     check_name="null_check_email",
        ...     check_type="completeness",
        ...     status="PASS",
        ...     score=98.5
        ... )
    """
    result = ValidationResult(
        table_name=table_name,
        check_name=check_name,
        check_type=check_type,
        status=status,
        score=score,
        **kwargs,
    )
    if get_client().save_validation_result(result):
        return result.id
    return None


def create_approval(
    query: str,
    table_name: str,
    requested_by: str,
    estimated_rows: int = 0
) -> Optional[str]:
    """
    Create an approval request and return its ID.
    
    Example:
        >>> approval_id = create_approval(
        ...     query="DELETE FROM Users WHERE inactive = true",
        ...     table_name="Users",
        ...     requested_by="admin@example.com",
        ...     estimated_rows=150
        ... )
    """
    request = ApprovalRequest(
        query=query,
        table_name=table_name,
        requested_by=requested_by,
        estimated_rows=estimated_rows,
    )
    if get_client().save_approval_request(request):
        return request.id
    return None


def audit(
    action: str,
    actor: str,
    resource_type: str,
    resource_id: str = "",
    **details
) -> None:
    """
    Write an audit log entry.
    
    Example:
        >>> audit(
        ...     action="tool_call",
        ...     actor="user@example.com",
        ...     resource_type="validation",
        ...     resource_id="val-123",
        ...     backend="vllm",
        ...     contains_pii=True
        ... )
    """
    log = AuditLog(
        action=action,
        actor=actor,
        resource_type=resource_type,
        resource_id=resource_id,
        details=details,
        routing_backend=details.get("backend", ""),
        contains_pii=details.get("contains_pii", False),
    )
    get_client().log_audit(log)