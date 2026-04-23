"""
Governance Module for AI Core PAL

Implements regulations compliance requirements:
- REG-MGF-2.1.2-001: Explicit tool allow-list, deny-by-default
- REG-MGF-2.1.2-002: Per-action identity attribution
- REG-MGF-2.1.2-003: Impact-limiting boundaries
- REG-MGF-2.2.2-001: Human approval checkpoints
- REG-MGF-2.3.3-002: Continuous monitoring

Reference specifications:
- docs/latex/specs/regulations/chapters/03-mgf-framework.tex
- docs/latex/specs/regulations/chapters/10-identity-attribution.tex
- docs/latex/specs/regulations/chapters/12-implementation-instructions.tex
"""

from .identity import (
    AgentIdentity,
    RequestIdentity,
    IdentityEnvelope,
    IdentityProvider,
    create_pal_identity_provider,
    DEFAULT_PAL_IDENTITY,
)

from .audit import (
    AuditEventType,
    AuditStatus,
    AuditAction,
    ApprovalStep,
    AuditOutcome,
    AuditEvent,
    AuditReservation,
    DurableAuditStore,
    get_audit_store,
    hash_content,
)

__all__ = [
    # Identity
    "AgentIdentity",
    "RequestIdentity", 
    "IdentityEnvelope",
    "IdentityProvider",
    "create_pal_identity_provider",
    "DEFAULT_PAL_IDENTITY",
    # Audit
    "AuditEventType",
    "AuditStatus",
    "AuditAction",
    "ApprovalStep",
    "AuditOutcome",
    "AuditEvent",
    "AuditReservation",
    "DurableAuditStore",
    "get_audit_store",
    "hash_content",
]