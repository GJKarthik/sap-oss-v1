"""
Governance-Compliant AI Core PAL Agent

Implements full regulations compliance:
- REG-MGF-2.1.2-001: Explicit tool allow-list, deny-by-default
- REG-MGF-2.1.2-002: Per-action identity attribution
- REG-MGF-2.1.2-003: Impact-limiting boundaries
- REG-MGF-2.2.2-001: Human approval checkpoints
- REG-MGF-2.3.3-002: Continuous monitoring

This agent replaces the in-memory audit log with durable storage
and implements reservation-before-action pattern.
"""

import json
import time
import urllib.request
from datetime import datetime, timezone
from typing import Any, Dict, List, Optional

from ..governance import (
    AgentIdentity,
    RequestIdentity,
    IdentityEnvelope,
    IdentityProvider,
    create_pal_identity_provider,
    AuditEventType,
    AuditStatus,
    AuditAction,
    AuditOutcome,
    AuditReservation,
    DurableAuditStore,
    get_audit_store,
    hash_content,
)


class GovernedGovernanceEngine:
    """
    Governance engine with deny-by-default tool policy.
    
    Implements REG-MGF-2.1.2-001: Explicit tool allow-list, deny-by-default.
    """
    
    # Explicit tool allow-list per Chapter 12
    ALLOWED_TOOLS = frozenset({
        "pal_classification",
        "pal_regression", 
        "pal_clustering",
        "pal_forecast",
        "pal_anomaly",
    })
    
    # Tools requiring human approval per REG-MGF-2.2.2-001
    APPROVAL_REQUIRED_TOOLS = frozenset({
        "pal_train_model",
        "pal_delete_model",
        "hana_write",
        "model_deploy",
    })
    
    # MCP tools for compliance-officer persona per Chapter 12
    GOVERNANCE_TOOLS = frozenset({
        "gov.requirement.register",
        "gov.policy.publish",
        "gov.conformance.run",
        "gov.conformance.report",
        "gov.monitor.query",
        "gov.audit.query",
        "gov.identity.attest",
    })
    
    def __init__(self):
        self.prompting_policy = {
            "aicore-pal-service-v1": {
                "max_tokens": 4096,
                "temperature": 0.3,
                "system_prompt": (
                    "You are an AI assistant for SAP HANA PAL predictive analytics. "
                    "Help users understand ML results, interpret predictions, and guide analysis. "
                    "All data processed is enterprise confidential - use on-premise LLM only. "
                    "Never send enterprise data or ML results to external services."
                )
            }
        }
    
    def is_tool_allowed(self, tool: str) -> bool:
        """Check if tool is in the explicit allow-list (deny-by-default)."""
        return tool in self.ALLOWED_TOOLS or tool in self.GOVERNANCE_TOOLS
    
    def requires_approval(self, tool: str) -> bool:
        """Check if tool requires human approval."""
        return tool in self.APPROVAL_REQUIRED_TOOLS
    
    def get_prompting_policy(self, product_id: str = "aicore-pal-service-v1") -> Dict:
        """Get prompting policy for a data product."""
        return self.prompting_policy.get(product_id, {})
    
    def get_autonomy_level(self) -> str:
        """Get agent autonomy level."""
        return "L2"  # Collaborate - human approves critical steps


class GovernedPALAgent:
    """
    Governance-compliant PAL Agent with full regulations support.
    
    Key compliance features:
    1. Identity envelope for every request (REG-MGF-2.1.2-002)
    2. Audit reservation before action execution
    3. Durable audit trail (not in-memory)
    4. Deny-by-default tool policy (REG-MGF-2.1.2-001)
    5. Human approval checkpoints (REG-MGF-2.2.2-001)
    """
    
    def __init__(
        self,
        identity_provider: Optional[IdentityProvider] = None,
        audit_store: Optional[DurableAuditStore] = None,
    ):
        self.identity_provider = identity_provider or create_pal_identity_provider()
        self.audit_store = audit_store or get_audit_store()
        self.governance = GovernedGovernanceEngine()
        
        # Endpoints
        self.vllm_endpoint = "http://localhost:9180/mcp"
        self.mcp_endpoint = "http://localhost:8084/mcp"
    
    async def invoke(
        self,
        prompt: str,
        context: Optional[Dict] = None,
        correlation_id: Optional[str] = None,
        user_id: Optional[str] = None,
        tenant_id: Optional[str] = None,
    ) -> Dict[str, Any]:
        """
        Execute a governance-compliant PAL operation.
        
        Implements the full governance flow:
        1. Create identity envelope
        2. Validate envelope
        3. Check tool allow-list (deny-by-default)
        4. Check approval requirements
        5. Reserve audit before action
        6. Execute action
        7. Complete audit after action
        """
        context = context or {}
        tool = context.get("tool", "pal_classification")
        start_time = time.time()
        
        # Step 1: Create identity envelope
        envelope = self.identity_provider.create_envelope(
            correlation_id=correlation_id,
            user_id=user_id,
            tenant_id=tenant_id,
        )
        
        # Step 2: Validate envelope
        if not envelope.validate():
            return self._create_error_response(
                "Identity envelope validation failed",
                envelope,
                tool,
                "REG-ID-001"
            )
        
        # Step 3: Deny-by-default tool check (REG-MGF-2.1.2-001)
        if not self.governance.is_tool_allowed(tool):
            return self._create_blocked_response(
                f"Tool '{tool}' is not in the allow-list (deny-by-default)",
                envelope,
                tool,
                "REG-ING-001"
            )
        
        # Step 4: Check approval requirements (REG-MGF-2.2.2-001)
        if self.governance.requires_approval(tool):
            return self._create_pending_approval_response(envelope, tool)
        
        # Step 5: Reserve audit BEFORE action (critical requirement)
        action = AuditAction(
            action_type="inference",
            tool_name=tool,
            input_hash=hash_content(prompt),
        )
        
        try:
            reservation = self.audit_store.reserve(
                event_type=AuditEventType.AGENT_INFERENCE,
                envelope=envelope,
                action=action,
            )
        except Exception as e:
            # Per REG-MGF-2.1.2-002: No action without successful audit reservation
            return self._create_error_response(
                f"Audit reservation failed: {str(e)}",
                envelope,
                tool,
                "REG-AUD-001"
            )
        
        # Step 6: Execute action
        try:
            prompting_policy = self.governance.get_prompting_policy()
            result = await self._call_vllm(tool, prompt, prompting_policy)
            
            # Calculate duration
            duration_ms = int((time.time() - start_time) * 1000)
            
            # Update action with output hash
            action.output_hash = hash_content(str(result))
            
            # Step 7: Complete audit after action (success)
            outcome = AuditOutcome(
                status=AuditStatus.SUCCESS,
                duration_ms=duration_ms,
            )
            
            audit_event = self.audit_store.complete(
                reservation=reservation,
                outcome=outcome,
                action=action,
            )
            
            return {
                "status": "success",
                "backend": "vllm",
                "routing_reason": "HANA PAL data is enterprise confidential - vLLM only",
                "result": result,
                "timestamp": datetime.now(timezone.utc).isoformat(),
                "governance": {
                    "request_id": envelope.request_identity.request_id,
                    "correlation_id": envelope.request_identity.correlation_id,
                    "agent_id": envelope.agent_identity.agent_id,
                    "audit_event_id": audit_event.event_id,
                    "duration_ms": duration_ms,
                }
            }
            
        except Exception as e:
            # Complete audit with failure
            duration_ms = int((time.time() - start_time) * 1000)
            
            outcome = AuditOutcome(
                status=AuditStatus.FAILURE,
                duration_ms=duration_ms,
                error_code="EXECUTION_ERROR",
            )
            
            action.error_code = str(type(e).__name__)
            
            self.audit_store.complete(
                reservation=reservation,
                outcome=outcome,
                action=action,
            )
            
            return {
                "status": "error",
                "message": str(e),
                "backend": "vllm",
                "timestamp": datetime.now(timezone.utc).isoformat(),
                "governance": {
                    "request_id": envelope.request_identity.request_id,
                    "correlation_id": envelope.request_identity.correlation_id,
                    "agent_id": envelope.agent_identity.agent_id,
                    "audit_event_id": reservation.event_id,
                    "duration_ms": duration_ms,
                    "error_code": "EXECUTION_ERROR",
                }
            }
    
    async def _call_vllm(
        self,
        tool: str,
        prompt: str,
        prompting_policy: Dict,
    ) -> Any:
        """Call vLLM endpoint."""
        request_data = {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/call",
            "params": {
                "name": tool,
                "arguments": {
                    "messages": json.dumps([
                        {
                            "role": "system",
                            "content": prompting_policy.get("system_prompt", "")
                        },
                        {"role": "user", "content": prompt}
                    ]),
                    "max_tokens": prompting_policy.get("max_tokens", 4096),
                    "temperature": prompting_policy.get("temperature", 0.3),
                }
            }
        }
        
        req = urllib.request.Request(
            self.vllm_endpoint,
            data=json.dumps(request_data).encode(),
            headers={"Content-Type": "application/json"},
            method="POST"
        )
        
        with urllib.request.urlopen(req, timeout=120) as resp:
            return json.loads(resp.read().decode())
    
    def _create_error_response(
        self,
        message: str,
        envelope: IdentityEnvelope,
        tool: str,
        error_code: str,
    ) -> Dict[str, Any]:
        """Create error response with governance metadata."""
        return {
            "status": "error",
            "message": message,
            "tool": tool,
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "governance": {
                "request_id": envelope.request_identity.request_id,
                "correlation_id": envelope.request_identity.correlation_id,
                "agent_id": envelope.agent_identity.agent_id,
                "error_code": error_code,
            }
        }
    
    def _create_blocked_response(
        self,
        message: str,
        envelope: IdentityEnvelope,
        tool: str,
        condition_code: str,
    ) -> Dict[str, Any]:
        """Create blocked response for deny-by-default violations."""
        # Log the blocked attempt
        action = AuditAction(
            action_type="blocked",
            tool_name=tool,
            error_code=condition_code,
        )
        
        event = self.audit_store.write(
            AuditEvent.from_envelope_and_action(
                envelope=envelope,
                event_type=AuditEventType.AGENT_ERROR,
                action=action,
                outcome=AuditOutcome(status=AuditStatus.FAILURE, error_code=condition_code),
            ) if hasattr(AuditEvent, 'from_envelope_and_action') else
            self._create_blocked_audit_event(envelope, tool, condition_code)
        )
        
        return {
            "status": "blocked",
            "message": message,
            "tool": tool,
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "governance": {
                "request_id": envelope.request_identity.request_id,
                "correlation_id": envelope.request_identity.correlation_id,
                "agent_id": envelope.agent_identity.agent_id,
                "condition_code": condition_code,
                "policy": "deny-by-default",
            }
        }
    
    def _create_blocked_audit_event(
        self,
        envelope: IdentityEnvelope,
        tool: str,
        condition_code: str,
    ) -> str:
        """Create and write a blocked audit event."""
        from ..governance.audit import AuditEvent
        
        event = AuditEvent(
            event_id=AuditEvent.generate_id(),
            event_type=AuditEventType.AGENT_ERROR,
            timestamp=datetime.now(timezone.utc).isoformat(),
            request_identity=envelope.request_identity,
            agent_identity=envelope.agent_identity,
            outcome=AuditOutcome(status=AuditStatus.FAILURE, error_code=condition_code),
            action=AuditAction(action_type="blocked", tool_name=tool, error_code=condition_code),
        )
        return self.audit_store.write(event)
    
    def _create_pending_approval_response(
        self,
        envelope: IdentityEnvelope,
        tool: str,
    ) -> Dict[str, Any]:
        """Create pending approval response."""
        # Log the approval request
        action = AuditAction(
            action_type="approval_requested",
            tool_name=tool,
            queue_id=f"approval-queue-{envelope.request_identity.request_id}",
        )
        
        event_id = self._create_blocked_audit_event(envelope, tool, "APPROVAL_REQUIRED")
        
        return {
            "status": "pending_approval",
            "message": f"Tool '{tool}' requires human approval per REG-MGF-2.2.2-001",
            "tool": tool,
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "governance": {
                "request_id": envelope.request_identity.request_id,
                "correlation_id": envelope.request_identity.correlation_id,
                "agent_id": envelope.agent_identity.agent_id,
                "approval_queue_id": action.queue_id,
                "policy": "human-approval-checkpoint",
            }
        }
    
    def get_governance_status(self) -> Dict[str, Any]:
        """Get current governance status."""
        return {
            "agent_id": self.identity_provider.agent_identity.agent_id,
            "agent_type": self.identity_provider.agent_identity.agent_type,
            "agent_version": self.identity_provider.agent_identity.agent_version,
            "autonomy_level": self.governance.get_autonomy_level(),
            "allowed_tools": list(self.governance.ALLOWED_TOOLS),
            "approval_required_tools": list(self.governance.APPROVAL_REQUIRED_TOOLS),
            "governance_tools": list(self.governance.GOVERNANCE_TOOLS),
            "policy": "deny-by-default",
            "audit_store": {
                "type": "durable",
                "backend": "sqlite",
            },
            "compliance": {
                "identity_attribution": "REG-MGF-2.1.2-002",
                "tool_allowlist": "REG-MGF-2.1.2-001",
                "human_checkpoints": "REG-MGF-2.2.2-001",
                "audit_reservation": "Chapter 10",
            }
        }
    
    def get_audit_summary(self, hours: int = 24) -> Dict[str, Any]:
        """Get audit summary for monitoring."""
        return self.audit_store.get_audit_summary(hours)


def create_governed_agent() -> GovernedPALAgent:
    """Factory function to create a governance-compliant PAL agent."""
    return GovernedPALAgent()


if __name__ == "__main__":
    import asyncio
    
    async def main():
        agent = create_governed_agent()
        
        print("=" * 60)
        print("Governance-Compliant PAL Agent")
        print("=" * 60)
        
        # Show governance status
        print("\n--- Governance Status ---")
        status = agent.get_governance_status()
        print(f"Agent ID: {status['agent_id']}")
        print(f"Autonomy Level: {status['autonomy_level']}")
        print(f"Policy: {status['policy']}")
        print(f"Allowed Tools: {status['allowed_tools']}")
        
        # Test 1: Allowed tool
        print("\n--- Test 1: Allowed Tool (pal_classification) ---")
        result = await agent.invoke(
            "Classify customers by revenue",
            {"tool": "pal_classification"},
            correlation_id="test-corr-001",
            user_id="test-user",
        )
        print(f"Status: {result['status']}")
        print(f"Request ID: {result.get('governance', {}).get('request_id', 'N/A')}")
        
        # Test 2: Blocked tool (not in allow-list)
        print("\n--- Test 2: Blocked Tool (not in allow-list) ---")
        result = await agent.invoke(
            "Execute custom SQL",
            {"tool": "custom_sql"},
            correlation_id="test-corr-002",
        )
        print(f"Status: {result['status']}")
        print(f"Message: {result.get('message', 'N/A')}")
        
        # Test 3: Approval required
        print("\n--- Test 3: Approval Required (pal_train_model) ---")
        result = await agent.invoke(
            "Train new model",
            {"tool": "pal_train_model"},
            correlation_id="test-corr-003",
        )
        print(f"Status: {result['status']}")
        print(f"Message: {result.get('message', 'N/A')}")
        
        # Show audit summary
        print("\n--- Audit Summary ---")
        summary = agent.get_audit_summary()
        print(f"Total Events: {summary['total_events']}")
        print(f"Success: {summary['success']}")
        print(f"Failure: {summary['failure']}")
    
    asyncio.run(main())