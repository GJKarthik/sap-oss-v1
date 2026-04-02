"""
Plain dataclass models for SAP AI Fabric Console API.
These replace the SQLAlchemy ORM models and are persisted via the configured store backend.
"""

import uuid
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Any, Dict, List, Optional


def _now() -> datetime:
    return datetime.now(timezone.utc)


def _uuid() -> str:
    return str(uuid.uuid4())


# ---------------------------------------------------------------------------
# Users
# ---------------------------------------------------------------------------

@dataclass
class User:
    username: str
    hashed_password: str
    id: str = field(default_factory=_uuid)
    email: Optional[str] = None
    role: str = "viewer"
    is_active: bool = True
    created_at: datetime = field(default_factory=_now)


# ---------------------------------------------------------------------------
# Data Sources
# ---------------------------------------------------------------------------

@dataclass
class DataSource:
    name: str
    source_type: str
    id: str = field(default_factory=_uuid)
    connection_status: str = "disconnected"
    config: Dict[str, Any] = field(default_factory=dict)
    last_sync: Optional[datetime] = None
    created_at: datetime = field(default_factory=_now)
    owner_id: Optional[str] = None


# ---------------------------------------------------------------------------
# AI Model Registry
# ---------------------------------------------------------------------------

@dataclass
class AIModel:
    id: str
    name: str
    provider: str = "sap-ai-core"
    version: str = "1.0"
    status: str = "available"
    description: Optional[str] = None
    context_window: int = 4096
    capabilities: List[str] = field(default_factory=list)
    created_at: datetime = field(default_factory=_now)


# ---------------------------------------------------------------------------
# Deployments
# ---------------------------------------------------------------------------

@dataclass
class Deployment:
    id: str = field(default_factory=_uuid)
    status: str = "PENDING"
    target_status: Optional[str] = None
    scenario_id: Optional[str] = None
    details: Dict[str, Any] = field(default_factory=dict)
    creation_time: datetime = field(default_factory=_now)
    owner_id: Optional[str] = None


# ---------------------------------------------------------------------------
# Vector Stores (RAG)
# ---------------------------------------------------------------------------

@dataclass
class VectorStore:
    table_name: str
    embedding_model: str = "default"
    documents_added: int = 0
    status: str = "active"
    created_at: datetime = field(default_factory=_now)
    owner_id: Optional[str] = None


# ---------------------------------------------------------------------------
# Governance Rules
# ---------------------------------------------------------------------------

@dataclass
class GovernanceRule:
    name: str
    rule_type: str
    id: str = field(default_factory=_uuid)
    active: bool = True
    description: Optional[str] = None
    created_at: datetime = field(default_factory=_now)
    updated_at: datetime = field(default_factory=_now)
