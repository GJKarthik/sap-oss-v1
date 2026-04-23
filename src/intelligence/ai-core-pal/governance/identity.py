"""
Identity Attribution Module for Regulations Compliance

Implements REG-MGF-2.1.2-002: Per-action identity attribution
Validates against:
- docs/schema/regulations/agent-identity.schema.json
- docs/schema/regulations/request-identity.schema.json

Reference: Chapter 10 - Identity Attribution
"""

import hashlib
import uuid
from dataclasses import dataclass, field, asdict
from datetime import datetime, timezone
from typing import Optional, Dict, Any, List
import json


@dataclass
class AgentIdentity:
    """
    Agent identity as defined in agent-identity.schema.json.
    
    Every agent action must be attributable to an identity per REG-MGF-2.1.2-002.
    """
    agent_id: str
    agent_type: str
    agent_version: str
    service_name: str
    deployment_id: str
    model_id: Optional[str] = None
    model_version: Optional[str] = None
    capabilities: List[str] = field(default_factory=list)
    trust_level: str = "L2"  # L1=Observe, L2=Collaborate, L3=Delegate, L4=Autonomous
    created_at: str = field(default_factory=lambda: datetime.now(timezone.utc).isoformat())
    
    def to_dict(self) -> Dict[str, Any]:
        return asdict(self)
    
    def to_json(self) -> str:
        return json.dumps(self.to_dict())
    
    @classmethod
    def from_dict(cls, data: Dict[str, Any]) -> "AgentIdentity":
        return cls(**{k: v for k, v in data.items() if k in cls.__dataclass_fields__})
    
    def validate(self) -> bool:
        """Validate against agent-identity.schema.json requirements."""
        required_fields = ["agent_id", "agent_type", "agent_version", "service_name", "deployment_id"]
        for field_name in required_fields:
            if not getattr(self, field_name, None):
                return False
        if self.trust_level not in ["L1", "L2", "L3", "L4"]:
            return False
        return True


@dataclass
class RequestIdentity:
    """
    Request identity as defined in request-identity.schema.json.
    
    Every request must carry identity envelope per REG-MGF-2.1.2-002.
    """
    request_id: str
    correlation_id: str
    session_id: Optional[str] = None
    user_id: Optional[str] = None
    client_id: Optional[str] = None
    tenant_id: Optional[str] = None
    source_ip: Optional[str] = None
    user_agent: Optional[str] = None
    timestamp: str = field(default_factory=lambda: datetime.now(timezone.utc).isoformat())
    headers: Dict[str, str] = field(default_factory=dict)
    
    def to_dict(self) -> Dict[str, Any]:
        return asdict(self)
    
    def to_json(self) -> str:
        return json.dumps(self.to_dict())
    
    @classmethod
    def from_dict(cls, data: Dict[str, Any]) -> "RequestIdentity":
        return cls(**{k: v for k, v in data.items() if k in cls.__dataclass_fields__})
    
    @classmethod
    def generate(cls, correlation_id: Optional[str] = None, **kwargs) -> "RequestIdentity":
        """Generate a new request identity with unique request_id."""
        return cls(
            request_id=f"req-{uuid.uuid4().hex[:16]}",
            correlation_id=correlation_id or f"corr-{uuid.uuid4().hex[:12]}",
            **kwargs
        )
    
    def validate(self) -> bool:
        """Validate against request-identity.schema.json requirements."""
        required_fields = ["request_id", "correlation_id"]
        for field_name in required_fields:
            if not getattr(self, field_name, None):
                return False
        return True


@dataclass
class IdentityEnvelope:
    """
    Combined identity envelope for governance tracking.
    
    Wraps both agent and request identity for complete attribution.
    """
    agent_identity: AgentIdentity
    request_identity: RequestIdentity
    envelope_id: str = field(default_factory=lambda: f"env-{uuid.uuid4().hex[:12]}")
    created_at: str = field(default_factory=lambda: datetime.now(timezone.utc).isoformat())
    
    def to_dict(self) -> Dict[str, Any]:
        return {
            "envelope_id": self.envelope_id,
            "agent_identity": self.agent_identity.to_dict(),
            "request_identity": self.request_identity.to_dict(),
            "created_at": self.created_at
        }
    
    def to_json(self) -> str:
        return json.dumps(self.to_dict())
    
    def validate(self) -> bool:
        """Validate complete identity envelope."""
        return self.agent_identity.validate() and self.request_identity.validate()
    
    def get_audit_fields(self) -> Dict[str, str]:
        """Get fields required for audit events."""
        return {
            "agent_id": self.agent_identity.agent_id,
            "agent_type": self.agent_identity.agent_type,
            "request_id": self.request_identity.request_id,
            "correlation_id": self.request_identity.correlation_id,
            "envelope_id": self.envelope_id
        }


class IdentityProvider:
    """
    Identity provider for governance-compliant agent operations.
    
    Ensures all operations have proper identity attribution per REG-MGF-2.1.2-002.
    """
    
    def __init__(
        self,
        agent_id: str,
        agent_type: str,
        agent_version: str,
        service_name: str,
        deployment_id: str,
        **kwargs
    ):
        self._agent_identity = AgentIdentity(
            agent_id=agent_id,
            agent_type=agent_type,
            agent_version=agent_version,
            service_name=service_name,
            deployment_id=deployment_id,
            **kwargs
        )
        
        if not self._agent_identity.validate():
            raise ValueError("Invalid agent identity configuration")
    
    @property
    def agent_identity(self) -> AgentIdentity:
        return self._agent_identity
    
    def create_request_identity(
        self,
        correlation_id: Optional[str] = None,
        user_id: Optional[str] = None,
        tenant_id: Optional[str] = None,
        **kwargs
    ) -> RequestIdentity:
        """Create a new request identity for a governance-tracked operation."""
        return RequestIdentity.generate(
            correlation_id=correlation_id,
            user_id=user_id,
            tenant_id=tenant_id,
            **kwargs
        )
    
    def create_envelope(
        self,
        correlation_id: Optional[str] = None,
        user_id: Optional[str] = None,
        tenant_id: Optional[str] = None,
        **kwargs
    ) -> IdentityEnvelope:
        """Create a complete identity envelope for a governance-tracked operation."""
        request_identity = self.create_request_identity(
            correlation_id=correlation_id,
            user_id=user_id,
            tenant_id=tenant_id,
            **kwargs
        )
        return IdentityEnvelope(
            agent_identity=self._agent_identity,
            request_identity=request_identity
        )
    
    def validate_envelope(self, envelope: IdentityEnvelope) -> bool:
        """Validate an identity envelope for governance compliance."""
        return envelope.validate()
    
    @staticmethod
    def hash_input(input_data: str) -> str:
        """Generate SHA-256 hash of input for audit purposes."""
        return f"sha256:{hashlib.sha256(input_data.encode()).hexdigest()}"
    
    @staticmethod
    def hash_output(output_data: str) -> str:
        """Generate SHA-256 hash of output for audit purposes."""
        return f"sha256:{hashlib.sha256(output_data.encode()).hexdigest()}"


# Default agent identity for AI Core PAL
DEFAULT_PAL_IDENTITY = {
    "agent_id": "aicore-pal-agent-001",
    "agent_type": "predictive-analytics",
    "agent_version": "2.0.0",
    "service_name": "aicore-pal",
    "deployment_id": "pal-prod-sg-001",
    "model_id": "vllm-mistral-7b",
    "model_version": "0.4.0",
    "capabilities": [
        "pal_classification",
        "pal_regression", 
        "pal_clustering",
        "pal_forecast",
        "pal_anomaly"
    ],
    "trust_level": "L2"
}


def create_pal_identity_provider() -> IdentityProvider:
    """Factory function to create the PAL agent identity provider."""
    return IdentityProvider(**DEFAULT_PAL_IDENTITY)