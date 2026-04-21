#!/usr/bin/env python3
"""Validation harness for Regulations .clinerules files."""

from __future__ import annotations

import re
from pathlib import Path


AI_CORE_PAL_DIR = Path(__file__).resolve().parents[1]
INTELLIGENCE_DIR = AI_CORE_PAL_DIR.parent
SRC_DIR = INTELLIGENCE_DIR.parent
REPO_ROOT = SRC_DIR.parent

DEVELOPMENT_RULES = INTELLIGENCE_DIR / ".clinerules"
MONITOR_RULES = INTELLIGENCE_DIR / ".clinerules.runtime-monitor"
GENERATIVE_UI_RULES = REPO_ROOT / "src" / "generativeUI" / ".clinerules"

DEVELOPMENT_TEXT = DEVELOPMENT_RULES.read_text(encoding="utf-8")
MONITOR_TEXT = MONITOR_RULES.read_text(encoding="utf-8")
GENERATIVE_UI_TEXT = GENERATIVE_UI_RULES.read_text(encoding="utf-8")


def _lower(text: str) -> str:
    return text.lower()


def _has_any(text: str, patterns: list[str]) -> bool:
    lowered = _lower(text)
    return any(pattern.lower() in lowered for pattern in patterns)


def _rubric_hits(text: str) -> dict[str, bool]:
    lowered = _lower(text)
    return {
        "incident_registry": _has_any(text, ["Known Issue Registry", "Known Failure Registry", "KI-001"]),
        "checklist": "checklist" in lowered,
        "smoke_tests": _has_any(text, ["Smoke Tests", "smoke test", "synthetic check cadence"]),
        "thresholds": "threshold" in lowered and bool(re.search(r"\b0\.\d+\b|\b\d+%", text)),
        "verification_commands": bool(re.search(r"\b(curl|grep|rg -n|python3|pytest|make test)\b", text)),
        "monitoring": _has_any(text, ["monitoring", "alert", "synthetic check cadence"]),
    }


class TestRuleFilesExist:
    def test_regulations_rule_files_exist(self) -> None:
        assert DEVELOPMENT_RULES.exists()
        assert MONITOR_RULES.exists()

    def test_generative_ui_baseline_exists(self) -> None:
        assert GENERATIVE_UI_RULES.exists()


class TestRegulationsDevelopmentRules:
    def test_required_sections_present(self) -> None:
        required_sections = [
            "Purpose",
            "Mission",
            "Source Of Truth",
            "Read First On Every Regulations Task",
            "Known Issue Registry",
            "10/10 Definition Of Done",
            "Non-Negotiable Engineering Rules",
            "Canonical Contract Rules",
            "Required Runtime Behavior",
            "Monitoring And Conformance Gates",
            "Pre-Change Checklist",
            "Post-Change Smoke Tests",
            "Completion Standard",
        ]
        for section in required_sections:
            assert section in DEVELOPMENT_TEXT, f"Missing section: {section}"

    def test_required_source_paths_exist(self) -> None:
        required_paths = [
            "docs/pdf/specs/regulations-spec.pdf",
            "docs/latex/specs/regulations/chapters/02-data-schema.tex",
            "docs/latex/specs/regulations/chapters/03-mgf-framework.tex",
            "docs/latex/specs/regulations/chapters/06-conformance-tooling.tex",
            "docs/latex/specs/regulations/chapters/08-monitoring-spec.tex",
            "docs/latex/specs/regulations/chapters/09-testing.tex",
            "docs/latex/specs/regulations/chapters/10-identity-attribution.tex",
            "docs/latex/specs/regulations/chapters/12-implementation-instructions.tex",
            "docs/schema/regulations/requirement.schema.json",
            "docs/schema/regulations/regulation.schema.json",
            "docs/schema/regulations/conformance-tool.schema.json",
            "docs/schema/regulations/corpus.schema.json",
            "docs/schema/regulations/agent-identity.schema.json",
            "docs/schema/regulations/request-identity.schema.json",
            "docs/schema/regulations/audit-event.schema.json",
            "docs/schema/regulations/capability-monitoring-metrics.schema.json",
            "src/intelligence/ai-core-pal/data_products/registry.yaml",
            "src/intelligence/ai-core-pal/agent/aicore_pal_agent.py",
            "src/intelligence/ai-core-pal/mcp_server/btp_pal_mcp_server.py",
            "src/intelligence/analytics/anomaly_detector.py",
            "src/intelligence/monitoring/kill_switch_monitor.py",
            "src/generativeUI/gateway/nginx.conf.template",
            "src/generativeUI/gateway/health/main.py",
            "src/generativeUI/gateway/README.md",
            "src/generativeUI/training-webcomponents-ngx/packages/api-server/src/main.py",
            "src/generativeUI/training-webcomponents-ngx/apps/angular-shell/src/app/services/training-governance.service.ts",
            "src/generativeUI/training-webcomponents-ngx/apps/angular-shell/src/app/services/team-governance.service.ts",
            "src/generativeUI/training-webcomponents-ngx/apps/angular-shell/src/app/pages/governance/governance.component.ts",
        ]
        for relative_path in required_paths:
            assert (REPO_ROOT / relative_path).exists(), f"Referenced path does not exist: {relative_path}"

    def test_required_regulatory_contracts_are_named(self) -> None:
        required_terms = [
            "compliance-officer",
            "gov.requirement.register",
            "gov.policy.publish",
            "gov.conformance.run",
            "gov.conformance.report",
            "gov.monitor.query",
            "gov.audit.query",
            "gov.identity.attest",
            "agent_id",
            "request_id",
            "correlation_id",
            "event_id",
            "approval_chain",
            "input_hash",
            "output_hash",
        ]
        for term in required_terms:
            assert term in DEVELOPMENT_TEXT, f"Missing required regulatory term: {term}"

    def test_required_thresholds_are_explicit(self) -> None:
        required_thresholds = [
            "0.05",
            "3x",
            "0.7",
            "1.5x",
            "3 consecutive",
            "15 minutes",
        ]
        for threshold in required_thresholds:
            assert threshold in DEVELOPMENT_TEXT, f"Missing threshold or escalation text: {threshold}"

    def test_operational_smoke_commands_exist(self) -> None:
        commands = [
            'rg -n "regulations\\.(requirement|regulation|conformance-tool|corpus|agent-identity|request-identity|audit-event|capability-monitoring-metrics)" src/intelligence/ai-core-pal/data_products/registry.yaml',
            'rg -n "gov\\.requirement\\.register|gov\\.policy\\.publish|gov\\.conformance\\.run|gov\\.conformance\\.report|gov\\.monitor\\.query|gov\\.audit\\.query|gov\\.identity\\.attest"',
            'rg -n "audit_log|rules_paths|agent_can_use|agent_requires_approval|pending_approval|blocked" src/intelligence/ai-core-pal/agent/aicore_pal_agent.py',
            "python3 -m pytest src/intelligence/ai-core-pal/tests/test_clinerules_contracts.py -v --tb=short",
            "cd src/intelligence/ai-core-pal && make test-clinerules",
        ]
        for command in commands:
            assert command in DEVELOPMENT_TEXT, f"Missing smoke-test command: {command}"


class TestRegulationsRuntimeMonitorRules:
    def test_required_sections_present(self) -> None:
        required_sections = [
            "Purpose",
            "Mission",
            "Source Of Truth",
            "Primary Monitoring Objective",
            "Evidence Sources",
            "What Counts As Healthy",
            "What Must Never Be Reported As Healthy",
            "Known Failure Registry",
            "Critical Alert Conditions",
            "High Severity Alert Conditions",
            "Synthetic Check Cadence",
            "Condition Codes",
            "Response Rules",
            "Operator Triage Checklist",
            "Minimum Evidence Required To Close An Alert",
            "Completion Standard",
        ]
        for section in required_sections:
            assert section in MONITOR_TEXT, f"Missing section: {section}"

    def test_monitor_references_required_metrics_and_thresholds(self) -> None:
        required_terms = [
            "output_token_count",
            "response_latency_ms",
            "confidence_score",
            "refusal_rate",
            "tool_call_frequency",
            "output_format_violations",
            "unexpected_topic_detections",
            "novel_capability_indicators",
            "0.05",
            "3x",
            "0.7",
            "1.5x",
            "3 consecutive",
            "15 minutes",
        ]
        for term in required_terms:
            assert term in MONITOR_TEXT, f"Missing monitoring term: {term}"

    def test_condition_codes_are_unique_and_complete(self) -> None:
        match = re.search(
            r"Condition Codes\n(?P<section>.*?)\nResponse Rules",
            MONITOR_TEXT,
            flags=re.DOTALL,
        )
        assert match, "Condition Codes section not found"
        codes = re.findall(r"`(REG-[A-Z]+-\d+)`", match.group("section"))
        assert codes, "No condition codes found"
        assert len(codes) == len(set(codes)), "Duplicate condition codes found"
        assert {
            "REG-ING-001",
            "REG-ID-001",
            "REG-ID-002",
            "REG-AUD-001",
            "REG-AUD-002",
            "REG-MET-001",
            "REG-MET-002",
            "REG-MET-003",
            "REG-MET-004",
            "REG-MET-005",
            "REG-CONF-001",
            "REG-GOV-001",
            "REG-CB-001",
        }.issubset(set(codes))


class TestBenchmarkAgainstGenerativeUIBaseline:
    def test_combined_regulations_rules_meet_or_exceed_baseline_operational_rubric(self) -> None:
        baseline_hits = _rubric_hits(GENERATIVE_UI_TEXT)
        combined_hits = _rubric_hits(DEVELOPMENT_TEXT + "\n" + MONITOR_TEXT)

        for dimension, baseline_hit in baseline_hits.items():
            if baseline_hit:
                assert combined_hits[dimension], (
                    f"Regulations rules are weaker than generativeUI baseline for dimension: {dimension}"
                )

        assert sum(combined_hits.values()) >= sum(baseline_hits.values())

    def test_regulations_rules_add_identity_audit_and_threshold_governance_absent_in_baseline(self) -> None:
        assert "docs/schema/regulations/agent-identity.schema.json" in DEVELOPMENT_TEXT
        assert "docs/schema/regulations/request-identity.schema.json" in DEVELOPMENT_TEXT
        assert "docs/schema/regulations/audit-event.schema.json" in DEVELOPMENT_TEXT
        assert "0.05" in DEVELOPMENT_TEXT + MONITOR_TEXT
        assert "3x" in DEVELOPMENT_TEXT + MONITOR_TEXT
        assert "3 consecutive" in DEVELOPMENT_TEXT + MONITOR_TEXT
