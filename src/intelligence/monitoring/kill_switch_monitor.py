"""
Kill-Switch Monitoring Service
TB-HITL Specification P2-1 Implementation

This module provides automated evaluation of kill-switch conditions
as specified in Table 11.4 and Chapter 14 of the TB-HITL spec.
"""

import asyncio
import logging
from dataclasses import dataclass
from datetime import datetime, timedelta
from enum import Enum
from typing import Optional, List, Dict, Any
import hashlib
import json

# Configure logging
logger = logging.getLogger(__name__)


class KillSwitchAction(Enum):
    """Actions that can be taken when a kill-switch triggers."""
    NONE = "none"
    ALERT_P2 = "alert_p2"
    ALERT_P1 = "alert_p1"
    KILL_IMMEDIATELY = "kill_immediately"


class NotificationChannel(Enum):
    """Notification channels for kill-switch alerts."""
    GITHUB_ISSUE = "github:issue"            # GitHub Issue creation
    GITHUB_DISCUSSION = "github:discussion"  # GitHub Discussion post
    EMAIL = "email:oncall@example.com"       # Email notification
    LOG = "log:critical"                     # Critical log entry


@dataclass
class KillSwitchResult:
    """Result of a kill-switch condition evaluation."""
    triggered: bool
    condition: str
    value: float
    threshold: float
    action: KillSwitchAction
    notification_channels: List[NotificationChannel]
    timestamp: datetime
    details: Optional[Dict[str, Any]] = None


@dataclass
class ProbeConfig:
    """Configuration for a kill-switch probe."""
    name: str
    condition: str
    threshold: float
    evaluation_frequency: str  # continuous, hourly, daily, post-cycle
    action: KillSwitchAction
    notification_channels: List[NotificationChannel]


class HANAConnector:
    """SAP HANA database connector for kill-switch queries."""
    
    def __init__(self, connection_string: Optional[str] = None):
        """
        Initialize HANA connector.
        
        Args:
            connection_string: HANA connection string (hdbcli format)
        """
        self.connection_string = connection_string
        self._connection = None
    
    async def execute(self, query: str, params: List[Any]) -> Dict[str, Any]:
        """
        Execute a query against SAP HANA and return results.
        
        Args:
            query: SQL query (HANA SQL syntax)
            params: Query parameters
            
        Returns:
            Dict with query results
        """
        # Placeholder - implement actual HANA connection using hdbcli
        # from hdbcli import dbapi
        # connection = dbapi.connect(address=host, port=port, user=user, password=password)
        raise NotImplementedError("HANA connector not configured")
    
    def close(self) -> None:
        """Close the database connection."""
        if self._connection:
            self._connection.close()
            self._connection = None


class KillSwitchMonitor:
    """
    Automated kill-switch condition evaluation.
    
    Implements the monitoring specification from Chapter 14:
    - Accept rate monitoring (post-cycle)
    - Material variance missed (daily)
    - Commentary factual error (manual weekly)
    - Hallucination detection (real-time)
    - vLLM availability (continuous 1-min)
    - Audit trail integrity (hourly)
    """
    
    # Quality thresholds from .clinerules
    ACCEPT_WITHOUT_EDIT_TARGET = 0.70
    ACCEPT_WITHOUT_EDIT_KILL = 0.50
    ACCEPT_WITH_EDIT_TARGET = 0.95
    ACCEPT_WITH_EDIT_KILL = 0.85
    
    # vLLM thresholds
    VLLM_LATENCY_THRESHOLD_MS = 5000
    VLLM_ERROR_RATE_THRESHOLD = 0.10
    VLLM_AVAILABILITY_THRESHOLD = 0.95
    HEALTH_CHECK_FAILURES_MAX = 3
    
    # Hallucination detection
    HALLUCINATION_CONFIDENCE_THRESHOLD = 0.30
    
    def __init__(
        self,
        db: HANAConnector,
        notification_service: Optional[Any] = None,
    ):
        self.db = db
        self.notification_service = notification_service
        self._health_check_failures = 0
        self._is_killed = False
        
        # Probe configurations
        self.probes: List[ProbeConfig] = [
            ProbeConfig(
                name="accept_rate_check",
                condition="accept_without_edit_rate < 50%",
                threshold=self.ACCEPT_WITHOUT_EDIT_KILL,
                evaluation_frequency="post-cycle",
                action=KillSwitchAction.ALERT_P2,
                notification_channels=[
                    NotificationChannel.GITHUB_ISSUE,
                    NotificationChannel.LOG,
                ],
            ),
            ProbeConfig(
                name="material_variance_missed",
                condition="AI missed material variance",
                threshold=1.0,  # Any miss triggers
                evaluation_frequency="daily",
                action=KillSwitchAction.ALERT_P1,
                notification_channels=[
                    NotificationChannel.GITHUB_ISSUE,
                    NotificationChannel.EMAIL,
                ],
            ),
            ProbeConfig(
                name="hallucination_detected",
                condition="confidence < 0.3 AND no source_references",
                threshold=self.HALLUCINATION_CONFIDENCE_THRESHOLD,
                evaluation_frequency="continuous",
                action=KillSwitchAction.KILL_IMMEDIATELY,
                notification_channels=[
                    NotificationChannel.GITHUB_ISSUE,
                    NotificationChannel.LOG,
                ],
            ),
            ProbeConfig(
                name="vllm_availability",
                condition="vLLM availability < 95%",
                threshold=self.VLLM_AVAILABILITY_THRESHOLD,
                evaluation_frequency="continuous",
                action=KillSwitchAction.ALERT_P2,
                notification_channels=[
                    NotificationChannel.LOG,
                ],
            ),
            ProbeConfig(
                name="audit_trail_integrity",
                condition="evidence_hash mismatch",
                threshold=0.0,  # Any integrity failure
                evaluation_frequency="hourly",
                action=KillSwitchAction.KILL_IMMEDIATELY,
                notification_channels=[
                    NotificationChannel.GITHUB_ISSUE,
                    NotificationChannel.LOG,
                ],
            ),
        ]
    
    # -------------------------------------------------------------------------
    # Quality Metrics Checks (Post-Cycle)
    # -------------------------------------------------------------------------
    
    async def check_accept_rate(self, period: str) -> KillSwitchResult:
        """
        Post-cycle check: Accept-without-edit rate.
        
        SQL query from Chapter 14, I-4 resolution.
        """
        query = """
            SELECT 
                COUNT(*) FILTER (WHERE decision='accept' AND edits='{}') AS accept_no_edit,
                COUNT(*) AS total_reviewed
            FROM decisions 
            WHERE period = %s
        """
        
        try:
            result = await self.db.execute(query, [period])
            
            if result["total_reviewed"] == 0:
                return KillSwitchResult(
                    triggered=False,
                    condition="accept_without_edit_rate",
                    value=0.0,
                    threshold=self.ACCEPT_WITHOUT_EDIT_KILL,
                    action=KillSwitchAction.NONE,
                    notification_channels=[],
                    timestamp=datetime.utcnow(),
                    details={"error": "No reviewed items in period"},
                )
            
            rate = result["accept_no_edit"] / result["total_reviewed"]
            triggered = rate < self.ACCEPT_WITHOUT_EDIT_KILL
            
            result_obj = KillSwitchResult(
                triggered=triggered,
                condition="accept_without_edit_rate",
                value=rate,
                threshold=self.ACCEPT_WITHOUT_EDIT_KILL,
                action=KillSwitchAction.ALERT_P2 if triggered else KillSwitchAction.NONE,
                notification_channels=[
                    NotificationChannel.GITHUB_ISSUE,
                    NotificationChannel.LOG,
                ] if triggered else [],
                timestamp=datetime.utcnow(),
                details={
                    "period": period,
                    "accept_no_edit": result["accept_no_edit"],
                    "total_reviewed": result["total_reviewed"],
                    "target": self.ACCEPT_WITHOUT_EDIT_TARGET,
                },
            )
            
            if triggered:
                await self._send_notification(result_obj)
            
            return result_obj
            
        except Exception as e:
            logger.error(f"Accept rate check failed: {e}")
            raise
    
    async def check_accept_with_edit_rate(self, period: str) -> KillSwitchResult:
        """
        Post-cycle check: Accept-with-any-edit rate.
        
        Formula: accept_with_any_edit_rate = count(accept) / total_reviewed >= 95%
        """
        query = """
            SELECT 
                COUNT(*) FILTER (WHERE decision='accept') AS accept_total,
                COUNT(*) AS total_reviewed
            FROM decisions 
            WHERE period = %s
        """
        
        result = await self.db.execute(query, [period])
        
        if result["total_reviewed"] == 0:
            return KillSwitchResult(
                triggered=False,
                condition="accept_with_any_edit_rate",
                value=0.0,
                threshold=self.ACCEPT_WITH_EDIT_KILL,
                action=KillSwitchAction.NONE,
                notification_channels=[],
                timestamp=datetime.utcnow(),
            )
        
        rate = result["accept_total"] / result["total_reviewed"]
        triggered = rate < self.ACCEPT_WITH_EDIT_KILL
        
        return KillSwitchResult(
            triggered=triggered,
            condition="accept_with_any_edit_rate",
            value=rate,
            threshold=self.ACCEPT_WITH_EDIT_KILL,
            action=KillSwitchAction.ALERT_P2 if triggered else KillSwitchAction.NONE,
            notification_channels=[
                NotificationChannel.LOG,
            ] if triggered else [],
            timestamp=datetime.utcnow(),
            details={
                "period": period,
                "accept_total": result["accept_total"],
                "total_reviewed": result["total_reviewed"],
                "target": self.ACCEPT_WITH_EDIT_TARGET,
            },
        )
    
    # -------------------------------------------------------------------------
    # Hallucination Detection (Real-Time)
    # -------------------------------------------------------------------------
    
    def check_hallucination_realtime(
        self,
        commentary_text: str,
        confidence: float,
        source_references: List[str],
    ) -> KillSwitchResult:
        """
        Real-time check: Hallucination detection.
        
        Triggers when confidence < 0.3 AND no source references.
        """
        triggered = (
            confidence < self.HALLUCINATION_CONFIDENCE_THRESHOLD 
            and len(source_references) == 0
        )
        
        result = KillSwitchResult(
            triggered=triggered,
            condition="hallucination_detected",
            value=confidence,
            threshold=self.HALLUCINATION_CONFIDENCE_THRESHOLD,
            action=KillSwitchAction.KILL_IMMEDIATELY if triggered else KillSwitchAction.NONE,
            notification_channels=[
                NotificationChannel.GITHUB_ISSUE,
                NotificationChannel.LOG,
            ] if triggered else [],
            timestamp=datetime.utcnow(),
            details={
                "confidence": confidence,
                "source_references": source_references,
                "commentary_preview": commentary_text[:200] if commentary_text else None,
            },
        )
        
        if triggered:
            logger.critical(
                f"HALLUCINATION DETECTED: confidence={confidence}, "
                f"sources={source_references}"
            )
            self._trigger_kill_switch("hallucination_detected")
        
        return result
    
    # -------------------------------------------------------------------------
    # vLLM Health Monitoring (Continuous)
    # -------------------------------------------------------------------------
    
    async def check_vllm_availability(
        self,
        latency_p95_ms: float,
        error_rate: float,
        health_check_passed: bool,
    ) -> KillSwitchResult:
        """
        Continuous check: vLLM availability and performance.
        
        Triggers on:
        - latency P95 > 5000ms (5-minute rolling window)
        - error rate > 10% (5-minute rolling window)
        - 3 consecutive health check failures
        """
        # Track health check failures
        if not health_check_passed:
            self._health_check_failures += 1
        else:
            self._health_check_failures = 0
        
        # Determine if triggered
        latency_triggered = latency_p95_ms > self.VLLM_LATENCY_THRESHOLD_MS
        error_rate_triggered = error_rate > self.VLLM_ERROR_RATE_THRESHOLD
        health_triggered = self._health_check_failures >= self.HEALTH_CHECK_FAILURES_MAX
        
        triggered = latency_triggered or error_rate_triggered or health_triggered
        
        # Determine specific condition
        if health_triggered:
            condition = "health_check_failures"
            value = float(self._health_check_failures)
            threshold = float(self.HEALTH_CHECK_FAILURES_MAX)
        elif latency_triggered:
            condition = "vllm_latency_p95"
            value = latency_p95_ms
            threshold = float(self.VLLM_LATENCY_THRESHOLD_MS)
        elif error_rate_triggered:
            condition = "vllm_error_rate"
            value = error_rate
            threshold = self.VLLM_ERROR_RATE_THRESHOLD
        else:
            condition = "vllm_availability"
            value = 1.0 - error_rate  # Availability
            threshold = self.VLLM_AVAILABILITY_THRESHOLD
        
        return KillSwitchResult(
            triggered=triggered,
            condition=condition,
            value=value,
            threshold=threshold,
            action=KillSwitchAction.ALERT_P2 if triggered else KillSwitchAction.NONE,
            notification_channels=[
                NotificationChannel.LOG,
            ] if triggered else [],
            timestamp=datetime.utcnow(),
            details={
                "latency_p95_ms": latency_p95_ms,
                "error_rate": error_rate,
                "health_check_passed": health_check_passed,
                "consecutive_failures": self._health_check_failures,
                "fallback_recommended": triggered,
            },
        )
    
    # -------------------------------------------------------------------------
    # Audit Trail Integrity (Hourly)
    # -------------------------------------------------------------------------
    
    async def check_audit_trail_integrity(self) -> KillSwitchResult:
        """
        Hourly check: Audit trail integrity via evidence hash verification.
        
        Verifies SHA-256 hashes of audit entries.
        """
        query = """
            SELECT 
                audit_id,
                timestamp,
                persona_id,
                action,
                resource_id,
                after_state,
                evidence_hash
            FROM audit_trail
            WHERE timestamp > NOW() - INTERVAL '1 hour'
            ORDER BY timestamp
        """
        
        try:
            entries = await self.db.execute(query, [])
            
            mismatches = []
            for entry in entries.get("rows", []):
                # Recalculate expected hash
                hash_input = json.dumps({
                    "timestamp": entry["timestamp"],
                    "persona_id": entry["persona_id"],
                    "action": entry["action"],
                    "resource_id": entry["resource_id"],
                    "after_state": entry["after_state"],
                }, sort_keys=True)
                
                expected_hash = f"sha256:{hashlib.sha256(hash_input.encode()).hexdigest()}"
                
                if entry["evidence_hash"] != expected_hash:
                    mismatches.append({
                        "audit_id": entry["audit_id"],
                        "expected_hash": expected_hash,
                        "actual_hash": entry["evidence_hash"],
                    })
            
            triggered = len(mismatches) > 0
            
            result = KillSwitchResult(
                triggered=triggered,
                condition="audit_trail_integrity",
                value=float(len(mismatches)),
                threshold=0.0,
                action=KillSwitchAction.KILL_IMMEDIATELY if triggered else KillSwitchAction.NONE,
                notification_channels=[
                    NotificationChannel.GITHUB_ISSUE,
                    NotificationChannel.LOG,
                ] if triggered else [],
                timestamp=datetime.utcnow(),
                details={
                    "entries_checked": len(entries.get("rows", [])),
                    "mismatches": mismatches[:10],  # First 10 only
                    "total_mismatches": len(mismatches),
                },
            )
            
            if triggered:
                logger.critical(
                    f"AUDIT TRAIL INTEGRITY FAILURE: {len(mismatches)} mismatches"
                )
                self._trigger_kill_switch("audit_trail_integrity")
            
            return result
            
        except Exception as e:
            logger.error(f"Audit trail integrity check failed: {e}")
            raise
    
    # -------------------------------------------------------------------------
    # Material Variance Check (Daily)
    # -------------------------------------------------------------------------
    
    async def check_material_variance_missed(self, date: str) -> KillSwitchResult:
        """
        Daily check: Compare AI-flagged vs manually-flagged material variances.
        
        Run daily at 06:00 UTC.
        """
        query = """
            SELECT 
                vr.id,
                vr.account_code,
                vr.variance_amount,
                vr.ai_flagged_material,
                vr.human_flagged_material
            FROM variance_records vr
            WHERE vr.created_date = %s
              AND vr.ai_flagged_material = FALSE
              AND vr.human_flagged_material = TRUE
        """
        
        result = await self.db.execute(query, [date])
        
        missed = result.get("rows", [])
        triggered = len(missed) > 0
        
        return KillSwitchResult(
            triggered=triggered,
            condition="material_variance_missed",
            value=float(len(missed)),
            threshold=1.0,
            action=KillSwitchAction.ALERT_P1 if triggered else KillSwitchAction.NONE,
            notification_channels=[
                NotificationChannel.GITHUB_ISSUE,
                NotificationChannel.EMAIL,
            ] if triggered else [],
            timestamp=datetime.utcnow(),
            details={
                "date": date,
                "missed_count": len(missed),
                "missed_records": [
                    {
                        "id": m["id"],
                        "account_code": m["account_code"],
                        "variance_amount": m["variance_amount"],
                    }
                    for m in missed[:5]  # First 5 only
                ],
            },
        )
    
    # -------------------------------------------------------------------------
    # Kill Switch Activation
    # -------------------------------------------------------------------------
    
    def _trigger_kill_switch(self, reason: str) -> None:
        """Activate the kill switch - switch to template-only mode."""
        self._is_killed = True
        logger.critical(f"KILL SWITCH ACTIVATED: {reason}")
        # Actual implementation would update configuration/feature flags
    
    def is_killed(self) -> bool:
        """Check if kill switch is currently active."""
        return self._is_killed
    
    def reset_kill_switch(self, authorized_by: str) -> None:
        """Reset the kill switch (requires authorization)."""
        logger.warning(f"KILL SWITCH RESET by {authorized_by}")
        self._is_killed = False
        self._health_check_failures = 0
    
    # -------------------------------------------------------------------------
    # Notification
    # -------------------------------------------------------------------------
    
    async def _send_notification(self, result: KillSwitchResult) -> None:
        """Send notification for triggered kill-switch condition."""
        if self.notification_service is None:
            logger.warning("Notification service not configured")
            return
        
        for channel in result.notification_channels:
            try:
                await self.notification_service.send(
                    channel=channel.value,
                    title=f"Kill-Switch Alert: {result.condition}",
                    message=f"Value: {result.value:.2f}, Threshold: {result.threshold:.2f}",
                    severity=result.action.value,
                    details=result.details,
                )
            except Exception as e:
                logger.error(f"Failed to send notification to {channel}: {e}")
    
    # -------------------------------------------------------------------------
    # Scheduled Execution
    # -------------------------------------------------------------------------
    
    async def run_scheduled_checks(self) -> List[KillSwitchResult]:
        """Run all scheduled checks and return results."""
        results = []
        now = datetime.utcnow()
        
        # Post-cycle check (run at M+6)
        # This should be triggered externally when a period closes
        
        # Daily check (06:00 UTC)
        if now.hour == 6:
            date = (now - timedelta(days=1)).strftime("%Y-%m-%d")
            results.append(await self.check_material_variance_missed(date))
        
        # Hourly check
        results.append(await self.check_audit_trail_integrity())
        
        return results


# =============================================================================
# Commentary Service with Kill-Switch Integration
# =============================================================================

class CommentaryService:
    """
    Commentary generation service with vLLM fallback.
    
    Implements P0-2 resolution from Chapter 14.
    """
    
    TEMPLATE_CONFIDENCE = 0.75  # Template confidence capped at 75%
    
    def __init__(
        self,
        kill_switch_monitor: KillSwitchMonitor,
        vllm_client: Optional[Any] = None,
    ):
        self.kill_switch = kill_switch_monitor
        self.vllm_client = vllm_client
        self._fallback_active = False
    
    async def generate_commentary(
        self,
        variance_record: Dict[str, Any],
    ) -> Dict[str, Any]:
        """
        Generate commentary for a variance record.
        
        Uses vLLM if available, falls back to templates if:
        - Kill switch is active
        - vLLM is unavailable
        - vLLM times out
        """
        # Check if fallback is required
        if self.kill_switch.is_killed() or self._fallback_active:
            return self._generate_template_commentary(variance_record)
        
        try:
            return await self._generate_vllm_commentary(variance_record)
        except Exception as e:
            logger.warning(f"vLLM generation failed, using template: {e}")
            self._fallback_active = True
            return self._generate_template_commentary(variance_record)
    
    async def _generate_vllm_commentary(
        self,
        variance_record: Dict[str, Any],
    ) -> Dict[str, Any]:
        """Generate commentary using vLLM."""
        if self.vllm_client is None:
            raise RuntimeError("vLLM client not configured")
        
        # Call vLLM API (placeholder)
        response = await self.vllm_client.generate(variance_record)
        
        # Check for hallucination
        hallucination_result = self.kill_switch.check_hallucination_realtime(
            commentary_text=response.get("text", ""),
            confidence=response.get("confidence", 0.0),
            source_references=response.get("source_references", []),
        )
        
        if hallucination_result.triggered:
            raise ValueError("Hallucination detected - rejecting commentary")
        
        return response
    
    def _generate_template_commentary(
        self,
        variance_record: Dict[str, Any],
    ) -> Dict[str, Any]:
        """
        Generate commentary using templates.
        
        Template library TPL-001 to TPL-007 from Chapter 14.
        """
        templates = {
            "spike": "TPL-001: {account_name} increased by {variance_amount} ({variance_pct}%) compared to prior period. This {direction} is primarily attributed to {reason}.",
            "drop": "TPL-003: {account_name} decreased by {variance_amount} ({variance_pct}%) compared to prior period. This {direction} is primarily attributed to {reason}.",
            "new_account": "TPL-005: {account_name} is a new account with a balance of {current_balance}. This account was not present in the prior period.",
            "material": "TPL-006: {account_name} has a material balance of {current_balance} requiring review.",
            "general": "TPL-007: {account_name} shows a variance of {variance_amount} ({variance_pct}%) from prior period {prior_period}.",
        }
        
        variance_type = variance_record.get("variance_type", "general")
        template = templates.get(variance_type, templates["general"])
        
        # Format template
        variance_amount = variance_record.get("variance_amount", 0)
        variance_pct = abs(variance_record.get("variance_percentage", 0) * 100)
        
        text = template.format(
            account_name=variance_record.get("account_name", "Account"),
            variance_amount=f"${abs(variance_amount):,.2f}",
            variance_pct=f"{variance_pct:.1f}",
            direction="increase" if variance_amount > 0 else "decrease",
            current_balance=f"${variance_record.get('current_balance', 0):,.2f}",
            prior_period=variance_record.get("prior_period", "prior period"),
            reason="pending investigation",
        )
        
        return {
            "commentary_id": f"template-{datetime.utcnow().isoformat()}",
            "text": text,
            "confidence": self.TEMPLATE_CONFIDENCE,
            "source_references": [],
            "model_version": "template-v1.0",
            "processing_time_ms": 5,
            "fallback_used": True,
        }


# =============================================================================
# Main Entry Point
# =============================================================================

if __name__ == "__main__":
    # Example usage
    print("Kill-Switch Monitor - TB-HITL P2-1 Implementation")
    print("=" * 60)
    print("\nProbe Configurations:")
    
    monitor = KillSwitchMonitor(db=HANAConnector())
    
    for probe in monitor.probes:
        print(f"\n  {probe.name}:")
        print(f"    Condition: {probe.condition}")
        print(f"    Threshold: {probe.threshold}")
        print(f"    Frequency: {probe.evaluation_frequency}")
        print(f"    Action: {probe.action.value}")