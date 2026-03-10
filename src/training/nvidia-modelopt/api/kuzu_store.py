#!/usr/bin/env python3
"""
KuzuStore — graph-RAG backend for the training-main ModelOpt service.

Node types:
  TrainingPair   — a generated (question, sql, domain, difficulty) pair
  SchemaTable    — a banking schema table (name, schema_name, domain)
  PromptTemplate — a prompt template (domain, category, param_count)
  SqlPattern     — a canonical SQL pattern (pattern_text, agg_func, complexity)

Relationship types:
  GENERATED_FROM  TrainingPair  → PromptTemplate
  QUERIES         TrainingPair  → SchemaTable
  HAS_PATTERN     TrainingPair  → SqlPattern
  BELONGS_TO_SCHEMA SchemaTable → SchemaTable  (self-link for schema grouping)

Backend preference: hippocpp (vendored Zig/Python bindings) → kuzu pip package → unavailable.
"""

from __future__ import annotations

import logging
import os
from typing import Any, Dict, List, Optional

logger = logging.getLogger(__name__)

_STORE_PATH = os.getenv("TRAINING_KUZU_PATH", "training_graph.db")

# ---------------------------------------------------------------------------
# Backend import — hippocpp preferred, kuzu pip fallback
# ---------------------------------------------------------------------------

_kuzu_mod = None

try:
    import hippocpp as _kuzu_mod  # type: ignore
    logger.debug("KuzuStore: using hippocpp backend")
except ImportError:
    try:
        import kuzu as _kuzu_mod  # type: ignore
        logger.debug("KuzuStore: using kuzu pip backend")
    except ImportError:
        logger.warning("KuzuStore: neither hippocpp nor kuzu is installed — store unavailable")


# ---------------------------------------------------------------------------
# Schema DDL
# ---------------------------------------------------------------------------

_SCHEMA_DDL = [
    # Nodes
    "CREATE NODE TABLE IF NOT EXISTS TrainingPair "
    "(id STRING, question STRING, sql STRING, domain STRING, difficulty STRING, source STRING, PRIMARY KEY(id))",

    "CREATE NODE TABLE IF NOT EXISTS SchemaTable "
    "(name STRING, schema_name STRING, domain STRING, PRIMARY KEY(name))",

    "CREATE NODE TABLE IF NOT EXISTS PromptTemplate "
    "(id STRING, domain STRING, category STRING, product STRING, param_count INT64, PRIMARY KEY(id))",

    "CREATE NODE TABLE IF NOT EXISTS SqlPattern "
    "(pattern_text STRING, agg_func STRING, complexity STRING, PRIMARY KEY(pattern_text))",

    # Relationships
    "CREATE REL TABLE IF NOT EXISTS GENERATED_FROM (FROM TrainingPair TO PromptTemplate)",
    "CREATE REL TABLE IF NOT EXISTS QUERIES (FROM TrainingPair TO SchemaTable)",
    "CREATE REL TABLE IF NOT EXISTS HAS_PATTERN (FROM TrainingPair TO SqlPattern)",
]

_READONLY_PREFIXES = ("MATCH", "RETURN", "WITH", "CALL", "SHOW", "EXPLAIN", "PROFILE")


class KuzuStore:
    """Embedded graph store for training data graph-RAG."""

    def __init__(self, db_path: str = _STORE_PATH):
        self._db_path = db_path
        self._db = None
        self._conn = None
        self._init_store()

    def _init_store(self) -> None:
        if _kuzu_mod is None:
            return
        try:
            self._db = _kuzu_mod.Database(self._db_path)
            self._conn = _kuzu_mod.Connection(self._db)
            for ddl in _SCHEMA_DDL:
                try:
                    self._conn.execute(ddl)
                except Exception:
                    pass  # table already exists
            logger.info("KuzuStore ready at %s", self._db_path)
        except Exception as exc:
            logger.warning("KuzuStore init failed: %s", exc)
            self._db = None
            self._conn = None

    def available(self) -> bool:
        return self._conn is not None

    # -----------------------------------------------------------------------
    # Upsert helpers
    # -----------------------------------------------------------------------

    def upsert_training_pair(
        self,
        pair_id: str,
        question: str,
        sql: str,
        domain: str,
        difficulty: str,
        source: str = "template_expansion",
    ) -> None:
        if not self.available():
            return
        try:
            self._conn.execute(
                "MERGE (p:TrainingPair {id: $id}) "
                "SET p.question = $question, p.sql = $sql, p.domain = $domain, "
                "p.difficulty = $difficulty, p.source = $source",
                {
                    "id": pair_id,
                    "question": question,
                    "sql": sql,
                    "domain": domain,
                    "difficulty": difficulty,
                    "source": source,
                },
            )
        except Exception as exc:
            logger.debug("upsert_training_pair error: %s", exc)

    def upsert_schema_table(self, name: str, schema_name: str, domain: str) -> None:
        if not self.available():
            return
        try:
            self._conn.execute(
                "MERGE (t:SchemaTable {name: $name}) "
                "SET t.schema_name = $schema_name, t.domain = $domain",
                {"name": name, "schema_name": schema_name, "domain": domain},
            )
        except Exception as exc:
            logger.debug("upsert_schema_table error: %s", exc)

    def upsert_prompt_template(
        self,
        template_id: str,
        domain: str,
        category: str,
        product: str,
        param_count: int,
    ) -> None:
        if not self.available():
            return
        try:
            self._conn.execute(
                "MERGE (t:PromptTemplate {id: $id}) "
                "SET t.domain = $domain, t.category = $category, "
                "t.product = $product, t.param_count = $param_count",
                {
                    "id": template_id,
                    "domain": domain,
                    "category": category,
                    "product": product,
                    "param_count": param_count,
                },
            )
        except Exception as exc:
            logger.debug("upsert_prompt_template error: %s", exc)

    def upsert_sql_pattern(
        self, pattern_text: str, agg_func: str, complexity: str
    ) -> None:
        if not self.available():
            return
        try:
            self._conn.execute(
                "MERGE (s:SqlPattern {pattern_text: $pattern_text}) "
                "SET s.agg_func = $agg_func, s.complexity = $complexity",
                {
                    "pattern_text": pattern_text,
                    "agg_func": agg_func,
                    "complexity": complexity,
                },
            )
        except Exception as exc:
            logger.debug("upsert_sql_pattern error: %s", exc)

    # -----------------------------------------------------------------------
    # Link helpers
    # -----------------------------------------------------------------------

    def link_pair_to_template(self, pair_id: str, template_id: str) -> None:
        if not self.available():
            return
        try:
            self._conn.execute(
                "MATCH (p:TrainingPair {id: $pid}), (t:PromptTemplate {id: $tid}) "
                "MERGE (p)-[:GENERATED_FROM]->(t)",
                {"pid": pair_id, "tid": template_id},
            )
        except Exception as exc:
            logger.debug("link_pair_to_template error: %s", exc)

    def link_pair_to_table(self, pair_id: str, table_name: str) -> None:
        if not self.available():
            return
        try:
            self._conn.execute(
                "MATCH (p:TrainingPair {id: $pid}), (t:SchemaTable {name: $tname}) "
                "MERGE (p)-[:QUERIES]->(t)",
                {"pid": pair_id, "tname": table_name},
            )
        except Exception as exc:
            logger.debug("link_pair_to_table error: %s", exc)

    def link_pair_to_pattern(self, pair_id: str, pattern_text: str) -> None:
        if not self.available():
            return
        try:
            self._conn.execute(
                "MATCH (p:TrainingPair {id: $pid}), (s:SqlPattern {pattern_text: $pt}) "
                "MERGE (p)-[:HAS_PATTERN]->(s)",
                {"pid": pair_id, "pt": pattern_text},
            )
        except Exception as exc:
            logger.debug("link_pair_to_pattern error: %s", exc)

    # -----------------------------------------------------------------------
    # Query helpers
    # -----------------------------------------------------------------------

    def _is_readonly(self, cypher: str) -> bool:
        stripped = cypher.strip().upper()
        return any(stripped.startswith(p) for p in _READONLY_PREFIXES)

    def query(self, cypher: str, params: Optional[Dict[str, Any]] = None) -> List[Dict]:
        """Execute a read-only Cypher query and return rows as dicts."""
        if not self.available():
            return []
        if not self._is_readonly(cypher):
            raise ValueError(f"Only read-only Cypher is permitted; got: {cypher[:80]}")
        try:
            result = self._conn.execute(cypher, params or {})
            rows: List[Dict] = []
            while result.has_next():
                row = result.get_next()
                cols = result.get_column_names() if hasattr(result, "get_column_names") else []
                rows.append(dict(zip(cols, row)) if cols else {"row": row})
            return rows
        except Exception as exc:
            logger.warning("KuzuStore.query error: %s", exc)
            return []

    def get_pairs_for_domain(self, domain: str, limit: int = 10) -> List[Dict]:
        return self.query(
            "MATCH (p:TrainingPair {domain: $domain}) "
            "RETURN p.id, p.question, p.sql, p.difficulty LIMIT $limit",
            {"domain": domain, "limit": limit},
        )

    def get_patterns_for_difficulty(self, difficulty: str, limit: int = 10) -> List[Dict]:
        return self.query(
            "MATCH (p:TrainingPair {difficulty: $difficulty})-[:HAS_PATTERN]->(s:SqlPattern) "
            "RETURN s.pattern_text, s.agg_func, s.complexity LIMIT $limit",
            {"difficulty": difficulty, "limit": limit},
        )

    def get_tables_for_domain(self, domain: str) -> List[Dict]:
        return self.query(
            "MATCH (t:SchemaTable {domain: $domain}) "
            "RETURN t.name, t.schema_name, t.domain",
            {"domain": domain},
        )

    def get_pair_count(self) -> int:
        rows = self.query("MATCH (p:TrainingPair) RETURN COUNT(p) AS cnt")
        if rows:
            return int(list(rows[0].values())[0])
        return 0


# ---------------------------------------------------------------------------
# Singleton
# ---------------------------------------------------------------------------

_store: Optional[KuzuStore] = None


def get_kuzu_store() -> KuzuStore:
    global _store
    if _store is None:
        _store = KuzuStore()
    return _store
