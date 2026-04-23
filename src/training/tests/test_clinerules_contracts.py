#!/usr/bin/env python3
"""Validation harness for Simula .clinerules files."""

from __future__ import annotations

import re
from pathlib import Path


TRAINING_DIR = Path(__file__).resolve().parents[1]
REPO_ROOT = TRAINING_DIR.parent.parent

TRAINING_RULES = TRAINING_DIR / ".clinerules"
MONITOR_RULES = TRAINING_DIR / ".clinerules.runtime-monitor"
GENERATIVE_UI_RULES = REPO_ROOT / "src" / "generativeUI" / ".clinerules"

TRAINING_TEXT = TRAINING_RULES.read_text(encoding="utf-8")
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
        "verification_commands": bool(re.search(r"\b(curl|grep|rg -n|python3|pytest)\b", text)),
        "monitoring": _has_any(text, ["monitoring", "alert", "synthetic check cadence"]),
    }


class TestRuleFilesExist:
    def test_training_rule_files_exist(self) -> None:
        assert TRAINING_RULES.exists()
        assert MONITOR_RULES.exists()

    def test_generative_ui_baseline_exists(self) -> None:
        assert GENERATIVE_UI_RULES.exists()


class TestTrainingImplementationRules:
    def test_required_sections_present(self) -> None:
        required_sections = [
            "Purpose",
            "Mission",
            "Source Of Truth",
            "Read First On Every Simula Task",
            "Known Issue Registry",
            "10/10 Definition Of Done",
            "Non-Negotiable Engineering Rules",
            "Canonical Contract Rules",
            "Required Runtime And Output Behavior",
            "Evaluation And Quality Gates",
            "Pre-Change Checklist",
            "Post-Change Smoke Tests",
            "Completion Standard",
        ]
        for section in required_sections:
            assert section in TRAINING_TEXT, f"Missing section: {section}"

    def test_required_source_paths_exist(self) -> None:
        required_paths = [
            "docs/pdf/specs/simula-training-spec.pdf",
            "docs/latex/specs/simula/chapters/03-extraction-pipeline.tex",
            "docs/latex/specs/simula/chapters/04-taxonomy-engine.tex",
            "docs/latex/specs/simula/chapters/05-generation-engine.tex",
            "docs/latex/specs/simula/chapters/06-environment-cli.tex",
            "docs/latex/specs/simula/chapters/07-references.tex",
            "docs/latex/specs/simula/chapters/12-implementation-instructions.tex",
            "docs/schema/simula/training-example.schema.json",
            "docs/schema/simula/taxonomy.schema.json",
            "src/training/scripts/run_hana_pipeline.py",
            "src/training/pipeline/main.py",
            "src/training/pipeline/Makefile",
            "src/training/Makefile",
            "src/generativeUI/training-webcomponents-ngx/packages/api-server/src/main.py",
            "src/generativeUI/training-webcomponents-ngx/apps/angular-shell/src/app/pages/pipeline/pipeline.component.ts",
        ]
        for relative_path in required_paths:
            assert (REPO_ROOT / relative_path).exists(), f"Referenced path does not exist: {relative_path}"

    def test_required_canonical_artifacts_are_named(self) -> None:
        required_artifacts = [
            "schemas.json",
            "taxonomies.json",
            "training_data.jsonl",
            "generation_stats.json",
            "rejected_examples.jsonl",
            "complexity_elo_scores.json",
            "coverage_report.json",
            "diversity_metrics.json",
            "critic_calibration.json",
        ]
        for artifact in required_artifacts:
            assert artifact in TRAINING_TEXT, f"Missing required artifact contract: {artifact}"

    def test_schema_first_contract_fields_are_called_out(self) -> None:
        required_fields = [
            "complexity_score",
            "critic_passed",
            "schema_context",
            "taxonomy_path",
            "mix_id",
            "elo_rating",
            "critic_evaluation",
            "generation_metadata",
            "quality_signals",
            "taxonomy_id",
            "node_id",
        ]
        for field_name in required_fields:
            assert field_name in TRAINING_TEXT, f"Missing contract field in rule file: {field_name}"

    def test_operational_smoke_commands_exist(self) -> None:
        commands = [
            "python3 src/training/scripts/run_hana_pipeline.py --help",
            'rg -n "make all|schema_pipeline/data_generator.py|prepare_training_data.py|training/pipeline/output/train.jsonl"',
            'rg -n "Preconvert|Parse Templates|Expand|Build SQL|Math.random\\\\("',
        ]
        for command in commands:
            assert command in TRAINING_TEXT, f"Missing smoke-test command: {command}"


class TestRuntimeMonitorRules:
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
            "Completion Standard",
        ]
        for section in required_sections:
            assert section in MONITOR_TEXT, f"Missing section: {section}"

    def test_monitor_references_required_artifacts(self) -> None:
        required_artifacts = [
            "schemas.json",
            "taxonomies.json",
            "training_data.jsonl",
            "generation_stats.json",
            "rejected_examples.jsonl",
            "complexity_elo_scores.json",
            "coverage_report.json",
            "diversity_metrics.json",
            "critic_calibration.json",
        ]
        for artifact in required_artifacts:
            assert artifact in MONITOR_TEXT, f"Missing monitored artifact: {artifact}"

    def test_condition_codes_are_unique_and_complete(self) -> None:
        match = re.search(
            r"Condition Codes\n(?P<section>.*?)\nResponse Rules",
            MONITOR_TEXT,
            flags=re.DOTALL,
        )
        assert match, "Condition Codes section not found"
        codes = re.findall(r"`(SIM-[A-Z]+-\d+)`", match.group("section"))
        assert codes, "No condition codes found"
        assert len(codes) == len(set(codes)), "Duplicate condition codes found"
        assert {
            "SIM-RUN-001",
            "SIM-RUN-002",
            "SIM-EXT-001",
            "SIM-TAX-001",
            "SIM-GEN-001",
            "SIM-ART-001",
            "SIM-ART-002",
            "SIM-EVAL-001",
            "SIM-EVAL-002",
            "SIM-EVAL-003",
            "SIM-EVAL-004",
            "SIM-EVAL-005",
            "SIM-MODE-001",
            "SIM-UI-001",
        }.issubset(set(codes))

    def test_quality_thresholds_are_explicit(self) -> None:
        required_thresholds = [
            "0.80",
            "0.30",
            "0.70",
            "0.90",
        ]
        for threshold in required_thresholds:
            assert threshold in MONITOR_TEXT, f"Missing monitoring threshold: {threshold}"


class TestBenchmarkAgainstGenerativeUIBaseline:
    def test_combined_training_rules_meet_or_exceed_baseline_operational_rubric(self) -> None:
        baseline_hits = _rubric_hits(GENERATIVE_UI_TEXT)
        combined_hits = _rubric_hits(TRAINING_TEXT + "\n" + MONITOR_TEXT)

        for dimension, baseline_hit in baseline_hits.items():
            if baseline_hit:
                assert combined_hits[dimension], (
                    f"Training rules are weaker than generativeUI baseline for dimension: {dimension}"
                )

        assert sum(combined_hits.values()) >= sum(baseline_hits.values())

    def test_training_rules_add_spec_and_schema_governance_absent_in_baseline(self) -> None:
        assert "Source Of Truth" in TRAINING_TEXT
        assert "docs/schema/simula/training-example.schema.json" in TRAINING_TEXT
        assert "docs/schema/simula/taxonomy.schema.json" in TRAINING_TEXT
        assert "10/10 Definition Of Done" in TRAINING_TEXT
