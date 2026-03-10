# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2024 SAP SE
"""
KùzuDB / HippoCPP Graph-RAG store for ai-core-pal MCP server.

Uses `hippocpp` as the graph backend (Kuzu-compatible API, Zig-native engine).
Falls back to `kuzu` pip package when HIPPOCPP_ALLOW_KUZU_FALLBACK=1.
Gracefully degrades when neither is installed.

Schema:
  Nodes  : PALAlgorithm, HANATable, MeshService, QueryIntent
  Edges  : EXECUTES_ON    (PALAlgorithm → HANATable)
           ROUTES_TO      (QueryIntent  → MeshService)
           RELATED_ALGO   (PALAlgorithm → PALAlgorithm)
           SERVED_BY      (QueryIntent  → PALAlgorithm)
"""
from __future__ import annotations

import os
import sys
from typing import Any


class KuzuStore:
    """Embedded graph store for ai-core-pal PAL algorithms and mesh routing."""

    def __init__(self, db_path: str = ".kuzu-aicore-pal") -> None:
        self._db_path = db_path
        self._db: Any = None
        self._conn: Any = None
        self._available: bool = False
        self._schema_ready: bool = False
        self._init()

    def _init(self) -> None:
        try:
            _hippo_python = os.path.join(
                os.path.dirname(__file__), "..", "hippocpp", "python"
            )
            if os.path.isdir(_hippo_python) and _hippo_python not in sys.path:
                sys.path.insert(0, os.path.abspath(_hippo_python))
            import hippocpp  # type: ignore[import]
            self._db = hippocpp.Database(self._db_path)
            self._conn = hippocpp.Connection(self._db)
            self._available = True
        except Exception:
            try:
                import kuzu  # type: ignore[import]
                self._db = kuzu.Database(self._db_path)
                self._conn = kuzu.Connection(self._db)
                self._available = True
            except Exception:
                self._available = False

    def available(self) -> bool:
        return self._available

    # ------------------------------------------------------------------
    # Schema
    # ------------------------------------------------------------------

    def ensure_schema(self) -> None:
        if not self._available or not self._conn or self._schema_ready:
            return

        ddl = [
            # Node tables
            """CREATE NODE TABLE IF NOT EXISTS PALAlgorithm (
                algoId      STRING,
                name        STRING,
                category    STRING,
                procedure   STRING,
                description STRING,
                PRIMARY KEY (algoId)
            )""",
            """CREATE NODE TABLE IF NOT EXISTS HANATable (
                tableId     STRING,
                name        STRING,
                schema_name STRING,
                table_type  STRING,
                PRIMARY KEY (tableId)
            )""",
            """CREATE NODE TABLE IF NOT EXISTS MeshService (
                serviceId   STRING,
                name        STRING,
                url         STRING,
                port        INT64,
                priority    INT64,
                PRIMARY KEY (serviceId)
            )""",
            """CREATE NODE TABLE IF NOT EXISTS QueryIntent (
                intentId    STRING,
                name        STRING,
                pattern     STRING,
                category    STRING,
                PRIMARY KEY (intentId)
            )""",
            # Relationship tables
            """CREATE REL TABLE IF NOT EXISTS EXECUTES_ON (
                FROM PALAlgorithm TO HANATable,
                weight INT64
            )""",
            """CREATE REL TABLE IF NOT EXISTS ROUTES_TO (
                FROM QueryIntent TO MeshService,
                priority INT64
            )""",
            """CREATE REL TABLE IF NOT EXISTS RELATED_ALGO (
                FROM PALAlgorithm TO PALAlgorithm,
                relation STRING
            )""",
            """CREATE REL TABLE IF NOT EXISTS SERVED_BY (
                FROM QueryIntent TO PALAlgorithm,
                confidence INT64
            )""",
        ]

        for stmt in ddl:
            self._conn.execute(stmt)

        self._schema_ready = True

    # ------------------------------------------------------------------
    # Upsert helpers
    # ------------------------------------------------------------------

    def upsert_pal_algorithm(
        self,
        algo_id: str,
        name: str,
        category: str,
        procedure: str,
        description: str,
    ) -> None:
        if not self._available or not self._conn:
            return
        self._conn.execute(
            "MERGE (a:PALAlgorithm {algoId: $id}) "
            "ON MATCH SET a.name = $nm, a.category = $cat, a.procedure = $proc, a.description = $dc "
            "ON CREATE SET a.name = $nm, a.category = $cat, a.procedure = $proc, a.description = $dc",
            {"id": algo_id, "nm": name, "cat": category, "proc": procedure, "dc": description},
        )

    def upsert_hana_table(
        self,
        table_id: str,
        name: str,
        schema_name: str,
        table_type: str,
    ) -> None:
        if not self._available or not self._conn:
            return
        self._conn.execute(
            "MERGE (t:HANATable {tableId: $id}) "
            "ON MATCH SET t.name = $nm, t.schema_name = $sn, t.table_type = $tt "
            "ON CREATE SET t.name = $nm, t.schema_name = $sn, t.table_type = $tt",
            {"id": table_id, "nm": name, "sn": schema_name, "tt": table_type},
        )

    def upsert_mesh_service(
        self,
        service_id: str,
        name: str,
        url: str,
        port: int,
        priority: int,
    ) -> None:
        if not self._available or not self._conn:
            return
        self._conn.execute(
            "MERGE (s:MeshService {serviceId: $id}) "
            "ON MATCH SET s.name = $nm, s.url = $url, s.port = $port, s.priority = $pr "
            "ON CREATE SET s.name = $nm, s.url = $url, s.port = $port, s.priority = $pr",
            {"id": service_id, "nm": name, "url": url, "port": port, "pr": priority},
        )

    def upsert_query_intent(
        self,
        intent_id: str,
        name: str,
        pattern: str,
        category: str,
    ) -> None:
        if not self._available or not self._conn:
            return
        self._conn.execute(
            "MERGE (i:QueryIntent {intentId: $id}) "
            "ON MATCH SET i.name = $nm, i.pattern = $pat, i.category = $cat "
            "ON CREATE SET i.name = $nm, i.pattern = $pat, i.category = $cat",
            {"id": intent_id, "nm": name, "pat": pattern, "cat": category},
        )

    # ------------------------------------------------------------------
    # Link helpers
    # ------------------------------------------------------------------

    def link_algo_table(self, algo_id: str, table_id: str, weight: int = 1) -> None:
        if not self._available or not self._conn:
            return
        self._conn.execute(
            "MATCH (a:PALAlgorithm {algoId: $aid}), (t:HANATable {tableId: $tid}) "
            "MERGE (a)-[:EXECUTES_ON {weight: $w}]->(t)",
            {"aid": algo_id, "tid": table_id, "w": weight},
        )

    def link_intent_service(self, intent_id: str, service_id: str, priority: int = 1) -> None:
        if not self._available or not self._conn:
            return
        self._conn.execute(
            "MATCH (i:QueryIntent {intentId: $iid}), (s:MeshService {serviceId: $sid}) "
            "MERGE (i)-[:ROUTES_TO {priority: $pr}]->(s)",
            {"iid": intent_id, "sid": service_id, "pr": priority},
        )

    def link_related_algos(self, from_id: str, to_id: str, relation: str = "similar") -> None:
        if not self._available or not self._conn:
            return
        self._conn.execute(
            "MATCH (a:PALAlgorithm {algoId: $fid}), (b:PALAlgorithm {algoId: $tid}) "
            "MERGE (a)-[:RELATED_ALGO {relation: $rel}]->(b)",
            {"fid": from_id, "tid": to_id, "rel": relation},
        )

    def link_intent_algo(self, intent_id: str, algo_id: str, confidence: int = 80) -> None:
        if not self._available or not self._conn:
            return
        self._conn.execute(
            "MATCH (i:QueryIntent {intentId: $iid}), (a:PALAlgorithm {algoId: $aid}) "
            "MERGE (i)-[:SERVED_BY {confidence: $cf}]->(a)",
            {"iid": intent_id, "aid": algo_id, "cf": confidence},
        )

    # ------------------------------------------------------------------
    # Query helpers
    # ------------------------------------------------------------------

    def run_query(self, cypher: str, params: dict | None = None) -> list[dict]:
        if not self._available or not self._conn:
            return []
        try:
            result = self._conn.execute(cypher, params or {})
            cols = result.get_column_names()
            rows: list[dict] = []
            while result.has_next():
                values = result.get_next()
                rows.append(dict(zip(cols, values)))
            return rows
        except Exception as exc:
            print(f"KùzuDB query failed: {exc}")
            return []

    def get_algos_for_intent(self, intent_id: str) -> list[dict]:
        """Return PAL algorithms reachable from a query intent."""
        if not self._available:
            return []
        return self.run_query(
            "MATCH (i:QueryIntent {intentId: $id})-[:SERVED_BY]->(a:PALAlgorithm) "
            "RETURN a.algoId AS algoId, a.name AS name, a.category AS category, "
            "a.procedure AS procedure, a.description AS description",
            {"id": intent_id},
        )

    def get_tables_for_algo(self, algo_id: str) -> list[dict]:
        """Return HANA tables a PAL algorithm executes on."""
        if not self._available:
            return []
        return self.run_query(
            "MATCH (a:PALAlgorithm {algoId: $id})-[:EXECUTES_ON]->(t:HANATable) "
            "RETURN t.tableId AS tableId, t.name AS name, "
            "t.schema_name AS schema_name, t.table_type AS table_type",
            {"id": algo_id},
        )

    def get_services_for_intent(self, intent_id: str) -> list[dict]:
        """Return mesh services an intent routes to."""
        if not self._available:
            return []
        return self.run_query(
            "MATCH (i:QueryIntent {intentId: $id})-[:ROUTES_TO]->(s:MeshService) "
            "RETURN s.serviceId AS serviceId, s.name AS name, "
            "s.url AS url, s.port AS port, s.priority AS priority",
            {"id": intent_id},
        )

    def get_related_algos(self, algo_id: str) -> list[dict]:
        """Return PAL algorithms related to a given algorithm."""
        if not self._available:
            return []
        return self.run_query(
            "MATCH (a:PALAlgorithm {algoId: $id})-[:RELATED_ALGO]->(b:PALAlgorithm) "
            "RETURN b.algoId AS algoId, b.name AS name, b.category AS category, "
            "b.procedure AS procedure, b.description AS description",
            {"id": algo_id},
        )


# ---------------------------------------------------------------------------
# Singleton
# ---------------------------------------------------------------------------

_instance: KuzuStore | None = None


def get_kuzu_store() -> KuzuStore:
    global _instance
    if _instance is None:
        _instance = KuzuStore(os.environ.get("KUZU_DB_PATH", ".kuzu-aicore-pal"))
    return _instance


def _reset_kuzu_store() -> None:
    global _instance
    _instance = None
