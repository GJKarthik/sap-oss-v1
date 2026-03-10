# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2024 SAP SE
"""
KùzuDB Graph Store for Data Cleaning Copilot.

Maintains a property graph of database table/column relationships and
quality-check coverage.  The graph is used to enrich ``data_quality_check``
responses with FK-neighbour and co-check context that flat schema inspection
cannot surface.

Schema
------
Node tables
  DbTable      – a database table being cleaned
  Column       – a column belonging to a table
  QualityCheck – a named data-quality check (completeness, accuracy, …)

Relationship tables
  HAS_COLUMN   – DbTable → Column
  FOREIGN_KEY  – Column → Column (FK reference, constraint_name STRING)
  CHECK_COVERS – QualityCheck → Column

Usage
-----
    from graph.kuzu_store import KuzuStore

    store = KuzuStore()
    store.ensure_schema()
    store.upsert_table("SalesOrders")
    store.upsert_column("SalesOrders", "CustomerID", "INTEGER")
    store.upsert_column("Customers", "ID", "INTEGER")
    store.link_fk("SalesOrders", "CustomerID", "Customers", "ID", "fk_cust")
    context = store.get_table_context("SalesOrders", hops=2)
"""

from __future__ import annotations

import json
import logging
import os
import threading
from typing import Any

logger = logging.getLogger("data-cleaning-copilot.graph")

_KUZU_DB_PATH = os.environ.get("KUZU_DB_PATH", ":memory:")

_store_lock = threading.Lock()
_singleton: "KuzuStore | None" = None


def get_store() -> "KuzuStore":
    """Return the process-wide singleton KuzuStore, creating it if needed."""
    global _singleton
    if _singleton is None:
        with _store_lock:
            if _singleton is None:
                _singleton = KuzuStore(_KUZU_DB_PATH)
                _singleton.ensure_schema()
    return _singleton


class KuzuStore:
    """Thread-safe wrapper around a KùzuDB database.

    Falls back gracefully when the ``kuzu`` pip package is not installed so
    that the MCP server can still start without the graph feature enabled.
    """

    def __init__(self, db_path: str = ":memory:") -> None:
        self._db_path = db_path
        self._db: Any = None
        self._conn: Any = None
        self._lock = threading.Lock()
        self._available = self._init_db()

    # ------------------------------------------------------------------
    # Initialisation
    # ------------------------------------------------------------------

    def _init_db(self) -> bool:
        try:
            import kuzu  # type: ignore
            self._db = kuzu.Database(self._db_path)
            self._conn = kuzu.Connection(self._db)
            logger.info("KùzuDB initialised at '%s'", self._db_path)
            return True
        except ImportError:
            logger.warning(
                "kuzu package not installed; graph-RAG features disabled. "
                "Add 'kuzu' to pyproject.toml dependencies to enable."
            )
            return False
        except Exception as exc:
            logger.warning("KùzuDB init failed: %s", exc)
            return False

    def available(self) -> bool:
        return self._available

    # ------------------------------------------------------------------
    # M1 – Schema definition
    # ------------------------------------------------------------------

    def ensure_schema(self) -> None:
        """Create node/relationship tables if they do not already exist."""
        if not self._available:
            return
        with self._lock:
            stmts = [
                # Node: a database table
                """CREATE NODE TABLE IF NOT EXISTS DbTable (
                    table_name STRING,
                    PRIMARY KEY (table_name)
                )""",
                # Node: a column within a table
                """CREATE NODE TABLE IF NOT EXISTS Column (
                    col_id     STRING,
                    table_name STRING,
                    col_name   STRING,
                    col_type   STRING,
                    PRIMARY KEY (col_id)
                )""",
                # Node: a named data-quality check
                """CREATE NODE TABLE IF NOT EXISTS QualityCheck (
                    check_id   STRING,
                    check_type STRING,
                    table_name STRING,
                    status     STRING,
                    score      STRING,
                    PRIMARY KEY (check_id)
                )""",
                # Relationship: table owns column
                """CREATE REL TABLE IF NOT EXISTS HAS_COLUMN (
                    FROM DbTable TO Column
                )""",
                # Relationship: FK reference between columns
                """CREATE REL TABLE IF NOT EXISTS FOREIGN_KEY (
                    FROM Column TO Column,
                    constraint_name STRING
                )""",
                # Relationship: quality check covers a column
                """CREATE REL TABLE IF NOT EXISTS CHECK_COVERS (
                    FROM QualityCheck TO Column
                )""",
            ]
            for stmt in stmts:
                try:
                    self._conn.execute(stmt)
                except Exception as exc:
                    logger.debug("Schema stmt skipped (%s): %s", exc, stmt[:60])

    # ------------------------------------------------------------------
    # M2 helpers – node/edge upsert used by kuzu_index tool
    # ------------------------------------------------------------------

    def upsert_table(self, table_name: str) -> None:
        """Insert or update a DbTable node."""
        if not self._available:
            return
        with self._lock:
            try:
                self._conn.execute(
                    "MERGE (t:DbTable {table_name: $name})",
                    {"name": table_name},
                )
            except Exception:
                try:
                    self._conn.execute(
                        "CREATE (t:DbTable {table_name: $name})",
                        {"name": table_name},
                    )
                except Exception as exc:
                    logger.debug("upsert_table failed for %s: %s", table_name, exc)

    def upsert_column(self, table_name: str, col_name: str, col_type: str = "UNKNOWN") -> str:
        """Insert or update a Column node and HAS_COLUMN edge. Returns col_id."""
        if not self._available:
            return ""
        col_id = f"{table_name}.{col_name}"
        with self._lock:
            try:
                self._conn.execute(
                    "MERGE (c:Column {col_id: $cid}) "
                    "SET c.table_name = $tbl, c.col_name = $col, c.col_type = $typ",
                    {"cid": col_id, "tbl": table_name, "col": col_name, "typ": col_type},
                )
            except Exception:
                try:
                    self._conn.execute(
                        "CREATE (c:Column {col_id: $cid, table_name: $tbl, "
                        "col_name: $col, col_type: $typ})",
                        {"cid": col_id, "tbl": table_name, "col": col_name, "typ": col_type},
                    )
                except Exception as exc:
                    logger.debug("upsert_column failed for %s: %s", col_id, exc)
            try:
                self._conn.execute(
                    "MATCH (t:DbTable {table_name: $tbl}), (c:Column {col_id: $cid}) "
                    "CREATE (t)-[:HAS_COLUMN]->(c)",
                    {"tbl": table_name, "cid": col_id},
                )
            except Exception as exc:
                logger.debug("HAS_COLUMN edge failed for %s: %s", col_id, exc)
        return col_id

    def link_fk(
        self,
        src_table: str,
        src_col: str,
        dst_table: str,
        dst_col: str,
        constraint_name: str = "",
    ) -> None:
        """Create a FOREIGN_KEY edge between two Column nodes."""
        if not self._available:
            return
        src_id = f"{src_table}.{src_col}"
        dst_id = f"{dst_table}.{dst_col}"
        with self._lock:
            try:
                self._conn.execute(
                    "MATCH (a:Column {col_id: $src}), (b:Column {col_id: $dst}) "
                    "CREATE (a)-[:FOREIGN_KEY {constraint_name: $cn}]->(b)",
                    {"src": src_id, "dst": dst_id, "cn": constraint_name},
                )
            except Exception as exc:
                logger.debug("link_fk failed %s->%s: %s", src_id, dst_id, exc)

    def upsert_quality_check(
        self,
        table_name: str,
        check_type: str,
        status: str = "",
        score: str = "",
        columns: list[str] | None = None,
    ) -> None:
        """Insert or update a QualityCheck node and CHECK_COVERS edges."""
        if not self._available:
            return
        check_id = f"{table_name}:{check_type}"
        with self._lock:
            try:
                self._conn.execute(
                    "MERGE (q:QualityCheck {check_id: $id}) "
                    "SET q.check_type = $typ, q.table_name = $tbl, "
                    "q.status = $st, q.score = $sc",
                    {"id": check_id, "typ": check_type, "tbl": table_name,
                     "st": status, "sc": score},
                )
            except Exception:
                try:
                    self._conn.execute(
                        "CREATE (q:QualityCheck {check_id: $id, check_type: $typ, "
                        "table_name: $tbl, status: $st, score: $sc})",
                        {"id": check_id, "typ": check_type, "tbl": table_name,
                         "st": status, "sc": score},
                    )
                except Exception as exc:
                    logger.debug("upsert_quality_check failed for %s: %s", check_id, exc)
            for col_name in (columns or []):
                col_id = f"{table_name}.{col_name}"
                try:
                    self._conn.execute(
                        "MATCH (q:QualityCheck {check_id: $qid}), (c:Column {col_id: $cid}) "
                        "CREATE (q)-[:CHECK_COVERS]->(c)",
                        {"qid": check_id, "cid": col_id},
                    )
                except Exception as exc:
                    logger.debug("CHECK_COVERS failed %s->%s: %s", check_id, col_id, exc)

    # ------------------------------------------------------------------
    # M3 helper – raw Cypher query used by kuzu_query tool
    # ------------------------------------------------------------------

    def run_query(self, cypher: str, params: dict | None = None) -> list[dict]:
        """Execute a Cypher query and return rows as a list of dicts."""
        if not self._available:
            return []
        with self._lock:
            try:
                result = self._conn.execute(cypher, params or {})
                if isinstance(result, list):
                    result = result[0]
                rows = []
                col_names = result.get_column_names()
                while result.has_next():
                    row = result.get_next()
                    rows.append(dict(zip(col_names, row)))
                return rows
            except Exception as exc:
                logger.warning("kuzu query failed: %s", exc)
                return []

    # ------------------------------------------------------------------
    # M4 helper – graph context enrichment for data_quality_check
    # ------------------------------------------------------------------

    def get_table_context(self, table_name: str, hops: int = 2) -> list[dict]:
        """Return columns and FK-neighbour tables within `hops` steps.

        The result is appended as ``graph_context`` to ``data_quality_check``
        responses so the LLM/caller can reason about related tables and columns.
        """
        if not self._available:
            return []
        cypher = (
            "MATCH (t:DbTable {table_name: $tbl})-[:HAS_COLUMN]->(c:Column) "
            "RETURN c.col_name AS col_name, c.col_type AS col_type, "
            "'own_column' AS relation "
            "LIMIT 30"
        )
        own_cols = self.run_query(cypher, {"tbl": table_name})

        fk_cypher = (
            "MATCH (src:Column {table_name: $tbl})"
            "-[:FOREIGN_KEY*1.." + str(min(hops, 4)) + "]->(dst:Column) "
            "RETURN dst.table_name AS ref_table, dst.col_name AS ref_col, "
            "'fk_reference' AS relation "
            "LIMIT 20"
        )
        fk_refs = self.run_query(fk_cypher, {"tbl": table_name})

        check_cypher = (
            "MATCH (q:QualityCheck {table_name: $tbl})-[:CHECK_COVERS]->(c:Column) "
            "RETURN q.check_type AS check_type, q.status AS status, "
            "c.col_name AS col_name, 'check_coverage' AS relation "
            "LIMIT 20"
        )
        checks = self.run_query(check_cypher, {"tbl": table_name})

        return own_cols + fk_refs + checks

    def get_check_context(self, table_name: str, check_type: str) -> list[dict]:
        """Return columns covered by a specific quality check."""
        if not self._available:
            return []
        cypher = (
            "MATCH (q:QualityCheck {check_id: $cid})-[:CHECK_COVERS]->(c:Column) "
            "RETURN c.col_name AS col_name, c.col_type AS col_type"
        )
        return self.run_query(cypher, {"cid": f"{table_name}:{check_type}"})
