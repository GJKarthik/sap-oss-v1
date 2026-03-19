#!/usr/bin/env python3
"""
Tests for the specialist_data_generator module.
Validates alignment with massive_term_generator conventions.
"""

import json
import re
import sys
import pytest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from schema_pipeline.specialist_data_generator import SpecialistDataGenerator
from schema_pipeline.massive_term_generator import MassiveTermGenerator
from schema_pipeline.sql_validator import HANASQLValidator


@pytest.fixture(scope="module")
def all_specialist_examples():
    """Generate examples from all 4 specialists."""
    gen = SpecialistDataGenerator()
    sanitizer = MassiveTermGenerator()
    examples = []
    for gen_func in [
        gen.generate_performance_examples,
        gen.generate_balance_sheet_examples,
        gen.generate_treasury_examples,
        gen.generate_esg_examples,
    ]:
        batch = gen_func(500)
        for ex in batch:
            sql = ex.get("sql", "")
            if sql:
                ex["sql"] = sanitizer._sanitize_sql(sql)
        examples.extend(batch)
    return examples


# ============================================================
# Schema alignment with massive_term_generator
# ============================================================
class TestSchemaAlignment:
    def test_uses_sql_key_not_query(self, all_specialist_examples):
        for ex in all_specialist_examples:
            assert "query" not in ex, f"Old 'query' key found: {ex.keys()}"
            assert "sql" in ex, f"Missing 'sql' key: {ex.keys()}"

    def test_uses_domain_key_not_specialist(self, all_specialist_examples):
        for ex in all_specialist_examples:
            assert "specialist" not in ex, f"Old 'specialist' key found: {ex.keys()}"
            assert "domain" in ex, f"Missing 'domain' key: {ex.keys()}"

    def test_has_type_field(self, all_specialist_examples):
        for ex in all_specialist_examples:
            assert "type" in ex, f"Missing 'type' key: {ex.keys()}"

    def test_has_question_field(self, all_specialist_examples):
        for ex in all_specialist_examples:
            assert "question" in ex and ex["question"], "Missing or empty question"

    def test_domains_are_valid(self, all_specialist_examples):
        valid = {"performance", "balance_sheet", "treasury", "esg"}
        for ex in all_specialist_examples:
            assert ex["domain"] in valid, f"Invalid domain: {ex['domain']}"


# ============================================================
# No SELECT * or LIMIT
# ============================================================
class TestNoAntiPatterns:
    def test_no_select_star(self, all_specialist_examples):
        bad = [ex["sql"][:80] for ex in all_specialist_examples if "SELECT *" in ex.get("sql", "")]
        assert len(bad) == 0, f"{len(bad)} SELECT * found:\n" + "\n".join(bad[:5])

    def test_no_limit_keyword(self, all_specialist_examples):
        bad = [ex["sql"][:80] for ex in all_specialist_examples
               if " LIMIT " in ex.get("sql", "") and "TOP" not in ex.get("sql", "")]
        assert len(bad) == 0, f"{len(bad)} LIMIT (without TOP) found:\n" + "\n".join(bad[:5])


# ============================================================
# HANA SQL validation
# ============================================================
class TestHANAValidation:
    def test_all_sql_passes_hana_validator(self, all_specialist_examples):
        validator = HANASQLValidator(strict=False)
        failures = []
        for ex in all_specialist_examples:
            sql = ex.get("sql", "")
            if not sql:
                continue
            report = validator.validate(sql)
            if not report.is_valid:
                failures.append((sql[:80], [e.message for e in report.errors]))
                if len(failures) >= 10:
                    break
        assert len(failures) == 0, (
            f"{len(failures)} HANA validation failures:\n"
            + "\n".join(f"  {s} -> {e}" for s, e in failures)
        )

    def test_no_unquoted_reserved_words(self, all_specialist_examples):
        bad = []
        for ex in all_specialist_examples:
            sql = ex.get("sql", "")
            if re.search(r'(?:GROUP BY|WHERE|AND|ORDER BY)\s+YEAR\b', sql) and "EXTRACT" not in sql:
                bad.append(sql[:100])
            if re.search(r'(?:GROUP BY|WHERE|AND|ORDER BY)\s+MONTH\b', sql):
                bad.append(sql[:100])
            if len(bad) >= 5:
                break
        assert len(bad) == 0, f"Unquoted reserved words:\n" + "\n".join(bad)


# ============================================================
# Coverage: all 4 specialists produce output
# ============================================================
class TestCoverage:
    def test_all_domains_represented(self, all_specialist_examples):
        domains = {ex["domain"] for ex in all_specialist_examples}
        expected = {"performance", "balance_sheet", "treasury", "esg"}
        assert expected == domains, f"Missing domains: {expected - domains}"

    def test_each_domain_has_multiple_types(self, all_specialist_examples):
        from collections import Counter
        domain_types = {}
        for ex in all_specialist_examples:
            domain_types.setdefault(ex["domain"], set()).add(ex["type"])
        for domain, types in domain_types.items():
            assert len(types) >= 3, f"{domain} has only {len(types)} types: {types}"

    def test_minimum_examples_per_domain(self, all_specialist_examples):
        from collections import Counter
        counts = Counter(ex["domain"] for ex in all_specialist_examples)
        for domain, count in counts.items():
            assert count >= 100, f"{domain} has only {count} examples"


# ============================================================
# Consistency with data_generator.py key change
# ============================================================
class TestDataGeneratorAlignment:
    def test_data_generator_uses_sql_key(self):
        """Verify data_generator.py outputs 'sql' not 'query'."""
        import importlib
        import inspect
        from schema_pipeline import data_generator
        source = inspect.getsource(data_generator)
        # Should have "sql": sql, not "query": sql
        assert '"sql": sql' in source or "'sql': sql" in source, (
            "data_generator.py should use 'sql' key"
        )


if __name__ == "__main__":
    pytest.main([__file__, "-v", "--tb=short"])

