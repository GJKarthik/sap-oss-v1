"""
Audit Trail with Vocabulary Context

Phase 4.2: Enhanced audit logging with OData vocabulary context.
Provides comprehensive audit trail for data access with GDPR compliance tracking.
"""

import hashlib
import json
import time
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Any, Dict, List, Optional
from enum import Enum
import os


class AuditEventType(Enum):
    """Types of audit events"""
    QUERY = "query"
    DATA_ACCESS = "data_access"
    PERSONAL_DATA_ACCESS = "personal_data_access"
    SENSITIVE_DATA_ACCESS = "sensitive_data_access"
    TOOL_INVOCATION = "tool_invocation"
    ENTITY_EXTRACTION = "entity_extraction"
    ANNOTATION_LOOKUP = "annotation_lookup"
    VOCABULARY_SEARCH = "vocabulary_search"
    DATA_MASKING = "data_masking"
    DATA_EXPORT = "data_export"


class AccessLevel(Enum):
    """Data access levels for audit"""
    READ = "read"
    WRITE = "write"
    DELETE = "delete"
    EXPORT = "export"
    ADMIN = "admin"


@dataclass
class EntityAccess:
    """Tracks access to a specific entity"""
    entity_type: str
    entity_id: Optional[str] = None
    fields_accessed: List[str] = field(default_factory=list)
    vocabulary_context: str = ""  # e.g., "Common.SemanticObject=SalesOrder"
    access_level: AccessLevel = AccessLevel.READ
    
    def to_dict(self) -> dict:
        return {
            "entity_type": self.entity_type,
            "entity_id": self.entity_id,
            "fields_accessed": self.fields_accessed,
            "vocabulary_context": self.vocabulary_context,
            "access_level": self.access_level.value
        }


@dataclass
class PersonalDataAudit:
    """GDPR-specific audit information"""
    data_subject_accessed: bool = False
    data_subject_role: Optional[str] = None
    personal_fields: List[str] = field(default_factory=list)
    sensitive_fields: List[str] = field(default_factory=list)
    legal_basis: Optional[str] = None
    consent_verified: bool = False
    purpose: Optional[str] = None
    retention_period: Optional[str] = None
    masked_fields: List[str] = field(default_factory=list)
    
    def to_dict(self) -> dict:
        return {
            "data_subject_accessed": self.data_subject_accessed,
            "data_subject_role": self.data_subject_role,
            "personal_fields": self.personal_fields,
            "sensitive_fields": self.sensitive_fields,
            "legal_basis": self.legal_basis,
            "consent_verified": self.consent_verified,
            "purpose": self.purpose,
            "retention_period": self.retention_period,
            "masked_fields": self.masked_fields
        }


@dataclass
class AuditEntry:
    """Complete audit log entry"""
    timestamp: datetime
    query_id: str
    event_type: AuditEventType
    query: str
    query_hash: str
    resolution_path: str = ""
    source: str = ""
    entities_accessed: List[EntityAccess] = field(default_factory=list)
    personal_data_audit: Optional[PersonalDataAudit] = None
    user_context: Dict[str, str] = field(default_factory=dict)
    tool_name: Optional[str] = None
    tool_args: Dict[str, Any] = field(default_factory=dict)
    result_count: int = 0
    duration_ms: float = 0.0
    success: bool = True
    error_message: Optional[str] = None
    vocabulary_terms_used: List[str] = field(default_factory=list)
    
    def to_dict(self) -> dict:
        return {
            "timestamp": self.timestamp.isoformat(),
            "query_id": self.query_id,
            "event_type": self.event_type.value,
            "query": self.query,
            "query_hash": self.query_hash,
            "resolution_path": self.resolution_path,
            "source": self.source,
            "entities_accessed": [e.to_dict() for e in self.entities_accessed],
            "personal_data_audit": self.personal_data_audit.to_dict() if self.personal_data_audit else None,
            "user_context": self.user_context,
            "tool_name": self.tool_name,
            "tool_args": self.tool_args,
            "result_count": self.result_count,
            "duration_ms": self.duration_ms,
            "success": self.success,
            "error_message": self.error_message,
            "vocabulary_terms_used": self.vocabulary_terms_used
        }


class AuditLogger:
    """
    Audit logger with vocabulary context for GDPR compliance.
    
    Features:
    - Tracks all data access with vocabulary annotations
    - Records personal data access for GDPR
    - Provides query hashing for deduplication
    - Supports multiple output destinations
    """
    
    def __init__(self, 
                 log_dir: str = "_audit_logs",
                 max_entries: int = 10000,
                 enable_console: bool = False):
        """
        Initialize audit logger.
        
        Args:
            log_dir: Directory for audit log files
            max_entries: Max in-memory entries before flush
            enable_console: Also print to console
        """
        self.log_dir = log_dir
        self.max_entries = max_entries
        self.enable_console = enable_console
        self.entries: List[AuditEntry] = []
        self._query_counter = 0
        
        # Create log directory
        os.makedirs(log_dir, exist_ok=True)
    
    def _generate_query_id(self) -> str:
        """Generate unique query ID"""
        self._query_counter += 1
        timestamp = int(time.time() * 1000)
        return f"q-{timestamp}-{self._query_counter:06d}"
    
    def _hash_query(self, query: str) -> str:
        """Create hash of query for deduplication"""
        normalized = " ".join(query.lower().split())
        return hashlib.sha256(normalized.encode()).hexdigest()[:16]
    
    def log_query(self,
                  query: str,
                  resolution_path: str = "",
                  entities: List[Dict] = None,
                  personal_data: Dict = None,
                  vocabulary_terms: List[str] = None,
                  user_context: Dict = None,
                  duration_ms: float = 0,
                  success: bool = True,
                  error: str = None) -> AuditEntry:
        """
        Log a query with full context.
        
        Args:
            query: The original query text
            resolution_path: How the query was resolved
            entities: List of entities accessed
            personal_data: Personal data audit info
            vocabulary_terms: OData terms used
            user_context: User/session context
            duration_ms: Query duration
            success: Whether query succeeded
            error: Error message if failed
            
        Returns:
            Created AuditEntry
        """
        query_id = self._generate_query_id()
        
        # Convert entities to EntityAccess
        entity_accesses = []
        if entities:
            for e in entities:
                entity_accesses.append(EntityAccess(
                    entity_type=e.get("entity_type", ""),
                    entity_id=e.get("entity_id"),
                    fields_accessed=e.get("fields_accessed", []),
                    vocabulary_context=e.get("vocabulary_context", ""),
                    access_level=AccessLevel(e.get("access_level", "read"))
                ))
        
        # Create PersonalDataAudit
        pd_audit = None
        if personal_data:
            pd_audit = PersonalDataAudit(
                data_subject_accessed=personal_data.get("data_subject_accessed", False),
                data_subject_role=personal_data.get("data_subject_role"),
                personal_fields=personal_data.get("personal_fields", []),
                sensitive_fields=personal_data.get("sensitive_fields", []),
                legal_basis=personal_data.get("legal_basis"),
                consent_verified=personal_data.get("consent_verified", False),
                purpose=personal_data.get("purpose"),
                masked_fields=personal_data.get("masked_fields", [])
            )
        
        entry = AuditEntry(
            timestamp=datetime.now(timezone.utc),
            query_id=query_id,
            event_type=AuditEventType.QUERY,
            query=query,
            query_hash=self._hash_query(query),
            resolution_path=resolution_path,
            entities_accessed=entity_accesses,
            personal_data_audit=pd_audit,
            user_context=user_context or {},
            vocabulary_terms_used=vocabulary_terms or [],
            duration_ms=duration_ms,
            success=success,
            error_message=error
        )
        
        self._add_entry(entry)
        return entry
    
    def log_tool_invocation(self,
                            tool_name: str,
                            args: Dict,
                            result_count: int = 0,
                            vocabulary_terms: List[str] = None,
                            duration_ms: float = 0,
                            success: bool = True,
                            error: str = None) -> AuditEntry:
        """
        Log an MCP tool invocation.
        
        Args:
            tool_name: Name of the tool called
            args: Tool arguments
            result_count: Number of results
            vocabulary_terms: Terms involved
            duration_ms: Invocation duration
            success: Whether call succeeded
            error: Error message if failed
            
        Returns:
            Created AuditEntry
        """
        query = f"tool:{tool_name}"
        
        entry = AuditEntry(
            timestamp=datetime.now(timezone.utc),
            query_id=self._generate_query_id(),
            event_type=AuditEventType.TOOL_INVOCATION,
            query=query,
            query_hash=self._hash_query(f"{tool_name}:{json.dumps(args, sort_keys=True)}"),
            tool_name=tool_name,
            tool_args=args,
            result_count=result_count,
            vocabulary_terms_used=vocabulary_terms or [],
            duration_ms=duration_ms,
            success=success,
            error_message=error
        )
        
        self._add_entry(entry)
        return entry
    
    def log_personal_data_access(self,
                                 entity_type: str,
                                 entity_id: str,
                                 fields: List[str],
                                 personal_fields: List[str],
                                 sensitive_fields: List[str],
                                 purpose: str,
                                 legal_basis: str = None,
                                 masked_fields: List[str] = None) -> AuditEntry:
        """
        Log access to personal data (GDPR requirement).
        
        Args:
            entity_type: Type of entity accessed
            entity_id: ID of the entity
            fields: All fields accessed
            personal_fields: Personal data fields accessed
            sensitive_fields: Sensitive data fields accessed
            purpose: Purpose of data access
            legal_basis: Legal basis (consent, contract, etc.)
            masked_fields: Fields that were masked
            
        Returns:
            Created AuditEntry
        """
        entry = AuditEntry(
            timestamp=datetime.now(timezone.utc),
            query_id=self._generate_query_id(),
            event_type=AuditEventType.PERSONAL_DATA_ACCESS if personal_fields 
                       else AuditEventType.SENSITIVE_DATA_ACCESS if sensitive_fields
                       else AuditEventType.DATA_ACCESS,
            query=f"data:{entity_type}/{entity_id}",
            query_hash=self._hash_query(f"{entity_type}:{entity_id}"),
            entities_accessed=[EntityAccess(
                entity_type=entity_type,
                entity_id=entity_id,
                fields_accessed=fields,
                access_level=AccessLevel.READ
            )],
            personal_data_audit=PersonalDataAudit(
                data_subject_accessed=True,
                personal_fields=personal_fields,
                sensitive_fields=sensitive_fields,
                legal_basis=legal_basis,
                purpose=purpose,
                masked_fields=masked_fields or []
            ),
            success=True
        )
        
        self._add_entry(entry)
        return entry
    
    def _add_entry(self, entry: AuditEntry):
        """Add entry to log and flush if needed"""
        self.entries.append(entry)
        
        if self.enable_console:
            print(f"[AUDIT] {entry.event_type.value}: {entry.query[:50]}...")
        
        if len(self.entries) >= self.max_entries:
            self.flush()
    
    def flush(self):
        """Flush entries to log file"""
        if not self.entries:
            return
        
        # Create daily log file
        date_str = datetime.now().strftime("%Y-%m-%d")
        log_file = os.path.join(self.log_dir, f"audit_{date_str}.jsonl")
        
        with open(log_file, "a") as f:
            for entry in self.entries:
                f.write(json.dumps(entry.to_dict()) + "\n")
        
        self.entries = []
    
    def get_personal_data_report(self, start_date: datetime = None, end_date: datetime = None) -> Dict:
        """
        Generate GDPR personal data access report.
        
        Args:
            start_date: Report start date
            end_date: Report end date
            
        Returns:
            Dict with personal data access statistics
        """
        # Flush current entries first
        self.flush()
        
        report = {
            "period": {
                "start": start_date.isoformat() if start_date else None,
                "end": end_date.isoformat() if end_date else None
            },
            "total_queries": 0,
            "personal_data_accesses": 0,
            "sensitive_data_accesses": 0,
            "data_subjects_accessed": set(),
            "personal_fields_accessed": {},
            "access_by_purpose": {},
            "access_by_legal_basis": {}
        }
        
        # Read log files
        for filename in os.listdir(self.log_dir):
            if not filename.endswith(".jsonl"):
                continue
            
            log_file = os.path.join(self.log_dir, filename)
            with open(log_file, "r") as f:
                for line in f:
                    try:
                        entry = json.loads(line)
                        report["total_queries"] += 1
                        
                        pd_audit = entry.get("personal_data_audit")
                        if pd_audit:
                            if pd_audit.get("personal_fields"):
                                report["personal_data_accesses"] += 1
                            if pd_audit.get("sensitive_fields"):
                                report["sensitive_data_accesses"] += 1
                            if pd_audit.get("data_subject_accessed"):
                                for ea in entry.get("entities_accessed", []):
                                    if ea.get("entity_id"):
                                        report["data_subjects_accessed"].add(
                                            f"{ea['entity_type']}:{ea['entity_id']}"
                                        )
                            
                            # Track field access
                            for field in pd_audit.get("personal_fields", []):
                                report["personal_fields_accessed"][field] = \
                                    report["personal_fields_accessed"].get(field, 0) + 1
                            
                            # Track by purpose
                            purpose = pd_audit.get("purpose", "unknown")
                            report["access_by_purpose"][purpose] = \
                                report["access_by_purpose"].get(purpose, 0) + 1
                            
                            # Track by legal basis
                            basis = pd_audit.get("legal_basis", "unknown")
                            report["access_by_legal_basis"][basis] = \
                                report["access_by_legal_basis"].get(basis, 0) + 1
                    except json.JSONDecodeError:
                        continue
        
        # Convert set to list for JSON serialization
        report["data_subjects_accessed"] = list(report["data_subjects_accessed"])
        report["unique_data_subjects"] = len(report["data_subjects_accessed"])
        
        return report


# Singleton instance
_audit_logger: Optional[AuditLogger] = None


def get_audit_logger(log_dir: str = "_audit_logs") -> AuditLogger:
    """Get or create the AuditLogger singleton"""
    global _audit_logger
    if _audit_logger is None:
        _audit_logger = AuditLogger(log_dir=log_dir)
    return _audit_logger