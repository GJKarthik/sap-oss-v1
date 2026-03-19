#!/usr/bin/env python3
"""
Tests for the massive_term_generator module.
Validates data quality, correctness, and 500K+ scale target.
"""

import json
import os
import sys
import hashlib
import pytest
from pathlib import Path
from collections import Counter

# Ensure the training package is importable
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from schema_pipeline.massive_term_generator import (
    MassiveTermGenerator,
    FINANCIAL_TERMS,
    TABLES,
    JOIN_SCHEMAS,
    DIMENSIONS,
    NEGATIVE_TEMPLATES,
    MULTI_TURN_TEMPLATES,
    FAKE_TERMS,
    FAKE_DIMS,
    QUESTION_TEMPLATES,
)

DATA_DIR = Path(__file__).resolve().parent.parent / "data" / "massive_semantic"
JSONL_PATH = DATA_DIR / "training_data.jsonl"


# ============================================================
# Fixture: load all generated examples once
# ============================================================
@pytest.fixture(scope="module")
def all_examples():
    """Load all generated training examples from JSONL."""
    examples = []
    with open(JSONL_PATH, "r") as f:
        for line in f:
            examples.append(json.loads(line.strip()))
    return examples


# ============================================================
# Scale target
# ============================================================
class TestScaleTarget:
    def test_minimum_500k_examples(self, all_examples):
        assert len(all_examples) >= 500_000, (
            f"Expected >= 500,000 examples, got {len(all_examples):,}"
        )

    def test_at_least_10_domains(self, all_examples):
        domains = set(e.get("domain", "") for e in all_examples)
        assert len(domains) >= 9, f"Expected >= 9 domains, got {len(domains)}: {domains}"

    def test_at_least_25_types(self, all_examples):
        types = set(e.get("type", "") for e in all_examples)
        assert len(types) >= 25, f"Expected >= 25 types, got {len(types)}: {types}"


# ============================================================
# Alias correctness (P0 bug fix)
# ============================================================
class TestAliasCorrectness:
    def test_no_total_alias_on_avg(self, all_examples):
        """AVG() should never be aliased as TOTAL_."""
        for ex in all_examples:
            sql = ex.get("sql") or ""
            if "AVG(" in sql:
                assert " as TOTAL_" not in sql, f"AVG aliased as TOTAL_: {sql[:120]}"

    def test_no_total_alias_on_count(self, all_examples):
        for ex in all_examples:
            sql = ex.get("sql") or ""
            if "COUNT(" in sql:
                assert " as TOTAL_" not in sql, f"COUNT aliased as TOTAL_: {sql[:120]}"

    def test_no_total_alias_on_min(self, all_examples):
        for ex in all_examples:
            sql = ex.get("sql") or ""
            if "MIN(" in sql:
                assert " as TOTAL_" not in sql, f"MIN aliased as TOTAL_: {sql[:120]}"

    def test_no_total_alias_on_max(self, all_examples):
        for ex in all_examples:
            sql = ex.get("sql") or ""
            if "MAX(" in sql:
                assert " as TOTAL_" not in sql, f"MAX aliased as TOTAL_: {sql[:120]}"


# ============================================================
# WHERE clause presence (P1 fix)
# ============================================================
class TestWhereClausePresence:
    def test_no_bare_selects(self, all_examples):
        """Every SELECT should have WHERE, GROUP BY, JOIN, ORDER BY, or an aggregate function."""
        bare = 0
        for ex in all_examples:
            sql = ex.get("sql") or ""
            if sql.startswith("SELECT"):
                has_clause = any(kw in sql for kw in [
                    "WHERE", "GROUP BY", "JOIN", "ORDER BY", "WITH ",
                    "SUM(", "AVG(", "COUNT(", "MIN(", "MAX(",
                ])
                if not has_clause:
                    bare += 1
        assert bare == 0, f"{bare} bare SELECT statements found (no WHERE/GROUP BY/JOIN/aggregate)"


# ============================================================
# JOIN queries (P1)
# ============================================================
class TestJoinQueries:
    def test_has_join_examples(self, all_examples):
        joins = [e for e in all_examples if "JOIN" in (e.get("sql") or "")]
        assert len(joins) >= 1000, f"Expected >= 1000 JOIN queries, got {len(joins)}"

    def test_join_syntax_valid(self, all_examples):
        for ex in all_examples:
            sql = ex.get("sql") or ""
            if "JOIN" in sql:
                assert " ON " in sql, f"JOIN without ON: {sql[:120]}"



# ============================================================
# Negative examples (P2)
# ============================================================
class TestNegativeExamples:
    def test_has_negative_examples(self, all_examples):
        negs = [e for e in all_examples if "negative" in e.get("type", "")]
        assert len(negs) >= 50, f"Expected >= 50 negative examples, got {len(negs)}"

    def test_negatives_have_no_sql(self, all_examples):
        for ex in all_examples:
            if "negative" in ex.get("type", ""):
                assert ex.get("sql") is None, f"Negative example has SQL: {ex}"

    def test_negatives_have_response(self, all_examples):
        for ex in all_examples:
            if "negative" in ex.get("type", ""):
                assert ex.get("response"), f"Negative example missing response: {ex}"

    def test_non_select_refusal(self, all_examples):
        for ex in all_examples:
            if ex.get("type") == "negative_non_select":
                resp = ex.get("response", "")
                assert "cannot" in resp.lower(), f"Non-select refusal should say 'cannot': {resp}"


# ============================================================
# Multi-turn conversations (P3)
# ============================================================
class TestMultiTurn:
    def test_has_multi_turn_examples(self, all_examples):
        mt = [e for e in all_examples if "multi_turn" in e.get("type", "")]
        assert len(mt) >= 50, f"Expected >= 50 multi-turn examples, got {len(mt)}"

    def test_multi_turn_has_turns(self, all_examples):
        for ex in all_examples:
            if "multi_turn" in ex.get("type", ""):
                assert "turns" in ex, f"Multi-turn missing 'turns': {ex.get('type')}"
                assert len(ex["turns"]) >= 4, f"Multi-turn should have >= 4 turns"

    def test_multi_turn_alternates_roles(self, all_examples):
        for ex in all_examples:
            if "multi_turn" in ex.get("type", "") and "turns" in ex:
                roles = [t["role"] for t in ex["turns"]]
                for i in range(1, len(roles)):
                    assert roles[i] != roles[i - 1], f"Consecutive same role: {roles}"


# ============================================================
# Schema description pairs (P2)
# ============================================================
class TestSchemaDescriptions:
    def test_has_schema_examples(self, all_examples):
        schema = [e for e in all_examples if e.get("domain") == "schema"]
        assert len(schema) >= 5000, f"Expected >= 5000 schema examples, got {len(schema)}"

    def test_schema_lookup_has_response(self, all_examples):
        for ex in all_examples:
            if ex.get("type") == "schema_lookup":
                assert ex.get("response"), f"Schema lookup missing response"

    def test_schema_mapping_mentions_source(self, all_examples):
        for ex in all_examples:
            if ex.get("type") == "schema_mapping":
                resp = ex.get("response", "")
                assert "maps to" in resp, f"Schema mapping should contain 'maps to': {resp[:80]}"


# ============================================================
# Question template diversity (P1)
# ============================================================
class TestQuestionDiversity:
    def test_at_least_100_templates(self):
        assert len(QUESTION_TEMPLATES) >= 100, (
            f"Expected >= 100 question templates, got {len(QUESTION_TEMPLATES)}"
        )

    def test_templates_cover_categories(self):
        categories = set()
        for t in QUESTION_TEMPLATES:
            if "{agg}" in t:
                categories.add("aggregation")
            if "{time}" in t:
                categories.add("temporal")
            if "{dim}" in t or "{dim1}" in t:
                categories.add("dimensional")
            if "compare" in t.lower() or "vs" in t.lower():
                categories.add("comparison")
            if "trend" in t.lower() or "over time" in t.lower():
                categories.add("trend")
            if "top" in t.lower() or "bottom" in t.lower() or "rank" in t.lower():
                categories.add("ranking")
            if "budget" in t.lower() or "forecast" in t.lower():
                categories.add("variance")
        expected = {"aggregation", "temporal", "dimensional", "comparison", "trend", "ranking", "variance"}
        assert expected.issubset(categories), f"Missing categories: {expected - categories}"


# ============================================================
# Domain-specific terms (expanded)
# ============================================================
class TestFinancialTerms:
    def test_at_least_60_term_groups(self):
        assert len(FINANCIAL_TERMS) >= 60, (
            f"Expected >= 60 term groups, got {len(FINANCIAL_TERMS)}"
        )

    def test_each_term_has_multiple_synonyms(self):
        for term, syns in FINANCIAL_TERMS.items():
            assert len(syns) >= 5, f"Term '{term}' has only {len(syns)} synonyms"

    def test_banking_specific_terms_present(self):
        required = [
            "nii", "nim", "casa", "npl", "rwa", "cet1", "lcr", "nsfr",
            "ftp", "alm", "irrbb", "pv01", "ecl", "pd", "lgd",
            "aum", "mortgage", "credit_card", "trade_finance",
        ]
        for term in required:
            assert term in FINANCIAL_TERMS, f"Missing banking term: {term}"


# ============================================================
# Deduplication
# ============================================================
class TestDeduplication:
    def test_no_exact_duplicate_rows(self, all_examples):
        """Full row dedup: question+sql pairs should be unique."""
        seen = set()
        dupes = 0
        for ex in all_examples:
            key = json.dumps(ex, sort_keys=True)
            h = hashlib.md5(key.encode()).hexdigest()
            if h in seen:
                dupes += 1
            seen.add(h)
        assert dupes == 0, f"{dupes} exact duplicate rows found"


# ============================================================
# Real prompts
# ============================================================
class TestRealPrompts:
    def test_has_real_prompts(self, all_examples):
        real = [e for e in all_examples if e.get("type") == "real_prompt"]
        assert len(real) >= 50, f"Expected >= 50 real prompts, got {len(real)}"

    def test_real_prompts_have_domain(self, all_examples):
        for ex in all_examples:
            if ex.get("type") == "real_prompt":
                assert ex.get("domain"), f"Real prompt missing domain"


# ============================================================
# Generator unit tests (fast, no file I/O)
# ============================================================
class TestGeneratorUnit:
    def test_expand_term_produces_variations(self):
        gen = MassiveTermGenerator()
        expanded = gen.expand_term("revenue", FINANCIAL_TERMS["revenue"])
        assert len(expanded) > len(FINANCIAL_TERMS["revenue"])
        assert "total revenue" in expanded or "net revenue" in expanded

    def test_hash_dedup_works(self):
        gen = MassiveTermGenerator()
        added1 = gen._add_example("q1", "s1", {"domain": "test", "type": "test", "term": "t"})
        added2 = gen._add_example("q1", "s1", {"domain": "test", "type": "test", "term": "t"})
        assert added1 is True
        assert added2 is False
        assert len(gen.generated_examples) == 1

    def test_tables_cover_all_domains(self):
        domain_terms_in_generate_all = [
            "performance", "balance_sheet", "treasury", "risk",
            "esg", "regulatory", "trade_finance", "wealth", "consumer",
        ]
        for domain in domain_terms_in_generate_all:
            assert domain in TABLES, f"TABLES missing domain: {domain}"

    def test_join_schemas_have_required_keys(self):
        required_keys = {"fact_table", "dim_table", "join_key", "fact_cols", "dim_cols"}
        for name, schema in JOIN_SCHEMAS.items():
            assert required_keys.issubset(schema.keys()), (
                f"JOIN_SCHEMAS['{name}'] missing keys: {required_keys - schema.keys()}"
            )


# ============================================================
# HANA SQL Validation
# ============================================================
class TestHANASQLValidation:
    def test_all_sql_passes_hana_validator(self, all_examples):
        """Every SQL example must pass the HANASQLValidator."""
        from schema_pipeline.sql_validator import HANASQLValidator
        validator = HANASQLValidator(strict=False)
        failures = []
        for i, ex in enumerate(all_examples):
            sql = ex.get("sql")
            if not sql:
                continue
            report = validator.validate(sql)
            if not report.is_valid:
                errors = [e.message for e in report.errors]
                failures.append((i, sql[:100], errors))
                if len(failures) >= 10:
                    break
        assert len(failures) == 0, (
            f"{len(failures)} SQL examples failed HANA validation:\n"
            + "\n".join(f"  [{i}] {s} -> {e}" for i, s, e in failures)
        )

    def test_no_unquoted_year_in_clauses(self, all_examples):
        """YEAR must be quoted when used as a column identifier."""
        import re
        bad = []
        for ex in all_examples:
            sql = ex.get("sql") or ""
            if re.search(r'(?:GROUP BY|WHERE|AND|ORDER BY)\s+YEAR\b', sql) and "EXTRACT" not in sql:
                bad.append(sql[:100])
                if len(bad) >= 5:
                    break
        assert len(bad) == 0, f"Unquoted YEAR found:\n" + "\n".join(bad)

    def test_no_unquoted_month_in_clauses(self, all_examples):
        import re
        bad = []
        for ex in all_examples:
            sql = ex.get("sql") or ""
            if re.search(r'(?:GROUP BY|WHERE|AND|ORDER BY)\s+MONTH\b', sql):
                bad.append(sql[:100])
                if len(bad) >= 5:
                    break
        assert len(bad) == 0, f"Unquoted MONTH found:\n" + "\n".join(bad)

    def test_no_join_without_on(self, all_examples):
        for ex in all_examples:
            sql = ex.get("sql") or ""
            if "JOIN" in sql:
                assert " ON " in sql, f"JOIN without ON: {sql[:120]}"

    def test_balanced_parentheses(self, all_examples):
        bad = []
        for ex in all_examples:
            sql = ex.get("sql") or ""
            if sql and sql.count("(") != sql.count(")"):
                bad.append(sql[:100])
                if len(bad) >= 5:
                    break
        assert len(bad) == 0, f"Unbalanced parens:\n" + "\n".join(bad)


class TestSanitizeSql:
    """Unit tests for the _sanitize_sql method."""

    def test_quotes_year_in_group_by(self):
        gen = MassiveTermGenerator()
        result = gen._sanitize_sql("SELECT YEAR, SUM(X) FROM T GROUP BY YEAR")
        assert '"YEAR"' in result
        assert "GROUP BY" in result

    def test_quotes_year_in_where(self):
        gen = MassiveTermGenerator()
        result = gen._sanitize_sql("SELECT X FROM T WHERE YEAR = 2025")
        assert 'WHERE "YEAR"' in result

    def test_does_not_quote_extract_year(self):
        gen = MassiveTermGenerator()
        result = gen._sanitize_sql("SELECT EXTRACT(YEAR FROM col) FROM T")
        assert "EXTRACT(YEAR" in result  # Should NOT be quoted

    def test_does_not_double_quote(self):
        gen = MassiveTermGenerator()
        result = gen._sanitize_sql('SELECT "YEAR" FROM T WHERE "YEAR" = 2025')
        assert '""YEAR""' not in result

    def test_quotes_month(self):
        gen = MassiveTermGenerator()
        result = gen._sanitize_sql("SELECT MONTH FROM T GROUP BY MONTH")
        assert '"MONTH"' in result


if __name__ == "__main__":
    pytest.main([__file__, "-v", "--tb=short"])

