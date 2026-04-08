# =============================================================================
# test_pipeline.py — Unit tests for the Python text-to-SQL pipeline
# =============================================================================
from __future__ import annotations

import json
import tempfile
from pathlib import Path

import pytest

from pipeline.csv_parser import CsvRow, parse_csv_string
from pipeline.hana_sql_builder import build_aggregation, build_select
from pipeline.json_emitter import emit_pairs_json, emit_schema_json, load_pairs_json
from pipeline.schema_extractor import extract_from_staging_csv_string
from pipeline.schema_registry import Column, Domain, SchemaRegistry, TableSchema
from pipeline.spider_formatter import format_for_spider
from pipeline.template_expander import TrainingPair, expand_all, expand_template
from pipeline.template_parser import Template, TemplateParam, parse_templates_csv_string


# ── CSV Parser ───────────────────────────────────────────────────────────────


class TestCsvParser:
    def test_parse_simple_row(self):
        rows = parse_csv_string("hello,world,42\n")
        assert len(rows) == 1
        assert rows[0].fields == ["hello", "world", "42"]

    def test_parse_quoted_field_with_comma(self):
        rows = parse_csv_string('"hello, world",42\n')
        assert len(rows) == 1
        assert rows[0].fields[0] == "hello, world"

    def test_parse_multiple_rows(self):
        rows = parse_csv_string("a,b\nc,d\n")
        assert len(rows) == 2
        assert rows[0].fields == ["a", "b"]
        assert rows[1].fields == ["c", "d"]

    def test_parse_empty_string(self):
        rows = parse_csv_string("")
        assert len(rows) == 0


# ── Schema Registry ──────────────────────────────────────────────────────────


class TestSchemaRegistry:
    def test_add_and_get_table(self):
        registry = SchemaRegistry()
        table = TableSchema(name="T1", schema_name="STG", domain=Domain.TREASURY)
        registry.add_table(table)
        assert registry.table_count() == 1
        assert registry.get_table("T1") is not None
        assert registry.get_table("T1").schema_name == "STG"

    def test_duplicate_table_ignored(self):
        registry = SchemaRegistry()
        registry.add_table(TableSchema(name="T1", schema_name="STG"))
        registry.add_table(TableSchema(name="T1", schema_name="OTHER"))
        assert registry.table_count() == 1
        assert registry.get_table("T1").schema_name == "STG"

    def test_add_column(self):
        registry = SchemaRegistry()
        registry.add_table(TableSchema(name="T1", schema_name="STG"))
        registry.add_column("T1", Column(name="COL1", data_type="INTEGER"))
        table = registry.get_table("T1")
        assert len(table.columns) == 1
        assert table.columns[0].name == "COL1"

    def test_to_dict(self):
        registry = SchemaRegistry()
        registry.add_table(TableSchema(name="T1", schema_name="STG", domain=Domain.ESG))
        data = registry.to_dict()
        assert len(data) == 1
        assert data[0]["domain"] == "esg"


# ── Schema Extractor ─────────────────────────────────────────────────────────


class TestSchemaExtractor:
    def test_extract_tables_from_staging_csv(self):
        csv_data = (
            "header1\n"
            "header2\n"
            "header3\n"
            ',TREASURY_CAPITAL,BCRS,"TABLE1",AS_OF_DATE,STG_BCRS,BSI_REM_FACT,AS_OF_DATE,Date field,TIMESTAMP,,,\n'
            ',TREASURY_CAPITAL,BCRS,"TABLE1",STATUS,STG_BCRS,BSI_REM_FACT,STATUS,Status field,NVARCHAR,,,\n'
            ',TREASURY_CAPITAL,BCRS,"TABLE2",COUNTRY,STG_BCRS,BSI_REM_DIM_COUNTRY,COUNTRY,Country name,NVARCHAR,,,\n'
        )
        registry = SchemaRegistry()
        extract_from_staging_csv_string(csv_data, registry)
        assert registry.table_count() == 2

        fact = registry.get_table("BSI_REM_FACT")
        assert fact is not None
        assert fact.schema_name == "STG_BCRS"
        assert fact.domain == Domain.TREASURY
        assert len(fact.columns) == 2

    def test_skips_short_rows(self):
        csv_data = "header1\nheader2\nheader3\nshort,row\n"
        registry = SchemaRegistry()
        extract_from_staging_csv_string(csv_data, registry)
        assert registry.table_count() == 0


# ── Template Parser ──────────────────────────────────────────────────────────


class TestTemplateParser:
    def test_parse_templates(self):
        csv_data = (
            "category,product,template,example\n"
            'analytics,treasury,"Show {metric} for {company_code}","SELECT {metric} FROM T WHERE company_code={company_code}"\n'
        )
        templates = parse_templates_csv_string(csv_data, "treasury")
        assert len(templates) == 1
        assert templates[0].domain == "treasury"
        assert len(templates[0].params) == 2

    def test_no_params(self):
        csv_data = "category,product,template,example\ninfo,general,Show all records,SELECT * FROM T\n"
        templates = parse_templates_csv_string(csv_data, "general")
        assert len(templates) == 1
        assert len(templates[0].params) == 0


# ── Template Expander ────────────────────────────────────────────────────────


class TestTemplateExpander:
    def test_expand_no_params(self):
        tmpl = Template(domain="test", category="info", product="p", template_text="Show all", example_text="SELECT *")
        pairs = expand_template(tmpl)
        assert len(pairs) == 1
        assert pairs[0].question == "Show all"
        assert pairs[0].sql == "SELECT *"

    def test_expand_with_params(self):
        tmpl = Template(
            domain="treasury",
            category="analytics",
            product="p",
            template_text="Show {metric}",
            example_text="SELECT {metric}",
            params=[TemplateParam(name="metric")],
        )
        pairs = expand_template(tmpl, param_values={"metric": ["revenue", "profit"]})
        assert len(pairs) == 2
        assert pairs[0].question == "Show revenue"
        assert pairs[1].sql == "SELECT profit"

    def test_expand_all(self):
        templates = [
            Template(domain="d", category="c", product="p", template_text="Q1", example_text="S1"),
            Template(domain="d", category="c", product="p", template_text="Q2", example_text="S2"),
        ]
        pairs = expand_all(templates)
        assert len(pairs) == 2


# ── HANA SQL Builder ─────────────────────────────────────────────────────────


class TestHanaSqlBuilder:
    def test_build_select(self):
        table = TableSchema(name="T1", schema_name="STG", columns=[Column(name="COL1"), Column(name="COL2")])
        query = build_select(table, columns=["COL1"], limit=10)
        assert '"COL1"' in query.sql
        assert "LIMIT 10" in query.sql
        assert '"STG"."T1"' in query.sql

    def test_build_aggregation(self):
        table = TableSchema(name="FACT", schema_name="DW")
        query = build_aggregation(table, measure_col="AMOUNT", dimension_cols=["REGION"], limit=5)
        assert "SUM" in query.sql
        assert "GROUP BY" in query.sql
        assert "LIMIT 5" in query.sql


# ── Spider Formatter ─────────────────────────────────────────────────────────


class TestSpiderFormatter:
    def test_format_split(self):
        pairs = [TrainingPair(question=f"Q{i}", sql=f"S{i}", domain="d", difficulty="easy") for i in range(10)]
        split = format_for_spider(pairs, db_id="test_db")
        assert len(split.train) + len(split.dev) + len(split.test_set) == 10
        assert split.train[0].db_id == "test_db"


# ── JSON Emitter ─────────────────────────────────────────────────────────────


class TestJsonEmitter:
    def test_roundtrip_pairs(self, tmp_path: Path):
        pairs = [TrainingPair(question="Q", sql="S", domain="d", difficulty="easy")]
        path = tmp_path / "pairs.json"
        emit_pairs_json(pairs, path)
        loaded = load_pairs_json(path)
        assert len(loaded) == 1
        assert loaded[0].question == "Q"

    def test_emit_schema(self, tmp_path: Path):
        registry = SchemaRegistry()
        registry.add_table(TableSchema(name="T1", schema_name="S1"))
        path = tmp_path / "schema.json"
        emit_schema_json(registry, path)
        data = json.loads(path.read_text())
        assert len(data) == 1
        assert data[0]["name"] == "T1"
