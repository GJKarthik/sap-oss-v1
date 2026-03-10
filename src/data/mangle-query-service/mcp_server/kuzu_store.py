# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2024 SAP SE
"""
KùzuDB / HippoCPP Graph-RAG store for mangle-query-service MCP server.

Uses `hippocpp` as the graph backend (Kuzu-compatible API, Zig-native engine).
Falls back to `kuzu` pip package when HIPPOCPP_ALLOW_KUZU_FALLBACK=1.
Gracefully degrades when neither is installed.

Schema:
  Nodes  : ResolutionPath, DataSource, QueryCategory, ModelBackend
  Edges  : RESOLVES_VIA   (DataSource → ResolutionPath)
           CLASSIFIES_TO  (QueryCategory → ResolutionPath)
           SERVED_BY      (ResolutionPath → ModelBackend)
           RELATED_PATH   (ResolutionPath → ResolutionPath)
"""
from __future__ import annotations

import os
from typing import Any


class KuzuStore:
    """Embedded graph store for mangle-query-service routing/resolution entities."""

    def __init__(self, db_path: str = ".kuzu-mangle-qs") -> None:
        self._db_path = db_path
        self._db: Any = None
        self._conn: Any = None
        self._available: bool = False
        self._schema_ready: bool = False
        self._init()

    def _init(self) -> None:
        try:
            import sys
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
            """CREATE NODE TABLE IF NOT EXISTS ResolutionPath (
                pathId      STRING,
                name        STRING,
                priority    INT64,
                score       INT64,
                description STRING,
                PRIMARY KEY (pathId)
            )""",
            """CREATE NODE TABLE IF NOT EXISTS DataSource (
                sourceId    STRING,
                name        STRING,
                sourceType  STRING,
                table_name  STRING,
                schema_name STRING,
                PRIMARY KEY (sourceId)
            )""",
            """CREATE NODE TABLE IF NOT EXISTS QueryCategory (
                categoryId  STRING,
                name        STRING,
                confidence  INT64,
                description STRING,
                PRIMARY KEY (categoryId)
            )""",
            """CREATE NODE TABLE IF NOT EXISTS ModelBackend (
                backendId   STRING,
                name        STRING,
                provider    STRING,
                priority    INT64,
                timeout_s   INT64,
                PRIMARY KEY (backendId)
            )""",
            # Relationship tables
            """CREATE REL TABLE IF NOT EXISTS RESOLVES_VIA (
                FROM DataSource TO ResolutionPath,
                weight INT64
            )""",
            """CREATE REL TABLE IF NOT EXISTS CLASSIFIES_TO (
                FROM QueryCategory TO ResolutionPath,
                confidence INT64
            )""",
            """CREATE REL TABLE IF NOT EXISTS SERVED_BY (
                FROM ResolutionPath TO ModelBackend,
                priority INT64
            )""",
            """CREATE REL TABLE IF NOT EXISTS RELATED_PATH (
                FROM ResolutionPath TO ResolutionPath,
                relation STRING
            )""",
        ]

        for stmt in ddl:
            self._conn.execute(stmt)

        self._schema_ready = True

    # ------------------------------------------------------------------
    # Upsert helpers
    # ------------------------------------------------------------------

    def upsert_resolution_path(
        self,
        path_id: str,
        name: str,
        priority: int,
        score: int,
        description: str,
    ) -> None:
        if not self._available or not self._conn:
            return
        self._conn.execute(
            "MERGE (p:ResolutionPath {pathId: $id}) "
            "ON MATCH SET p.name = $nm, p.priority = $pr, p.score = $sc, p.description = $dc "
            "ON CREATE SET p.name = $nm, p.priority = $pr, p.score = $sc, p.description = $dc",
            {"id": path_id, "nm": name, "pr": priority, "sc": score, "dc": description},
        )

    def upsert_data_source(
        self,
        source_id: str,
        name: str,
        source_type: str,
        table_name: str,
        schema_name: str,
    ) -> None:
        if not self._available or not self._conn:
            return
        self._conn.execute(
            "MERGE (s:DataSource {sourceId: $id}) "
            "ON MATCH SET s.name = $nm, s.sourceType = $st, s.table_name = $tn, s.schema_name = $sn "
            "ON CREATE SET s.name = $nm, s.sourceType = $st, s.table_name = $tn, s.schema_name = $sn",
            {"id": source_id, "nm": name, "st": source_type, "tn": table_name, "sn": schema_name},
        )

    def upsert_query_category(
        self,
        category_id: str,
        name: str,
        confidence: int,
        description: str,
    ) -> None:
        if not self._available or not self._conn:
            return
        self._conn.execute(
            "MERGE (c:QueryCategory {categoryId: $id}) "
            "ON MATCH SET c.name = $nm, c.confidence = $cf, c.description = $dc "
            "ON CREATE SET c.name = $nm, c.confidence = $cf, c.description = $dc",
            {"id": category_id, "nm": name, "cf": confidence, "dc": description},
        )

    def upsert_model_backend(
        self,
        backend_id: str,
        name: str,
        provider: str,
        priority: int,
        timeout_s: int,
    ) -> None:
        if not self._available or not self._conn:
            return
        self._conn.execute(
            "MERGE (m:ModelBackend {backendId: $id}) "
            "ON MATCH SET m.name = $nm, m.provider = $pv, m.priority = $pr, m.timeout_s = $ts "
            "ON CREATE SET m.name = $nm, m.provider = $pv, m.priority = $pr, m.timeout_s = $ts",
            {"id": backend_id, "nm": name, "pv": provider, "pr": priority, "ts": timeout_s},
        )

    # ------------------------------------------------------------------
    # Link helpers
    # ------------------------------------------------------------------

    def link_source_path(self, source_id: str, path_id: str, weight: int = 1) -> None:
        if not self._available or not self._conn:
            return
        self._conn.execute(
            "MATCH (s:DataSource {sourceId: $sid}), (p:ResolutionPath {pathId: $pid}) "
            "MERGE (s)-[:RESOLVES_VIA {weight: $w}]->(p)",
            {"sid": source_id, "pid": path_id, "w": weight},
        )

    def link_category_path(self, category_id: str, path_id: str, confidence: int = 70) -> None:
        if not self._available or not self._conn:
            return
        self._conn.execute(
            "MATCH (c:QueryCategory {categoryId: $cid}), (p:ResolutionPath {pathId: $pid}) "
            "MERGE (c)-[:CLASSIFIES_TO {confidence: $cf}]->(p)",
            {"cid": category_id, "pid": path_id, "cf": confidence},
        )

    def link_path_backend(self, path_id: str, backend_id: str, priority: int = 100) -> None:
        if not self._available or not self._conn:
            return
        self._conn.execute(
            "MATCH (p:ResolutionPath {pathId: $pid}), (m:ModelBackend {backendId: $bid}) "
            "MERGE (p)-[:SERVED_BY {priority: $pr}]->(m)",
            {"pid": path_id, "bid": backend_id, "pr": priority},
        )

    def link_paths(self, from_id: str, to_id: str, relation: str = "fallback") -> None:
        if not self._available or not self._conn:
            return
        self._conn.execute(
            "MATCH (a:ResolutionPath {pathId: $fid}), (b:ResolutionPath {pathId: $tid}) "
            "MERGE (a)-[:RELATED_PATH {relation: $rel}]->(b)",
            {"fid": from_id, "tid": to_id, "rel": relation},
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

    def get_paths_for_source(self, source_id: str) -> list[dict]:
        """Return resolution paths reachable from a data source."""
        if not self._available:
            return []
        return self.run_query(
            "MATCH (s:DataSource {sourceId: $id})-[:RESOLVES_VIA]->(p:ResolutionPath) "
            "RETURN p.pathId AS pathId, p.name AS name, p.priority AS priority, "
            "p.score AS score, p.description AS description, 'resolves_via' AS relation",
            {"id": source_id},
        )

    def get_paths_for_category(self, category_id: str) -> list[dict]:
        """Return resolution paths a query category routes to."""
        if not self._available:
            return []
        return self.run_query(
            "MATCH (c:QueryCategory {categoryId: $id})-[:CLASSIFIES_TO]->(p:ResolutionPath) "
            "RETURN p.pathId AS pathId, p.name AS name, p.priority AS priority, "
            "p.score AS score, p.description AS description, 'classifies_to' AS relation",
            {"id": category_id},
        )

    def get_backends_for_path(self, path_id: str) -> list[dict]:
        """Return model backends serving a resolution path."""
        if not self._available:
            return []
        return self.run_query(
            "MATCH (p:ResolutionPath {pathId: $id})-[:SERVED_BY]->(m:ModelBackend) "
            "RETURN m.backendId AS backendId, m.name AS name, m.provider AS provider, "
            "m.priority AS priority, m.timeout_s AS timeout_s, 'served_by' AS relation",
            {"id": path_id},
        )


# ---------------------------------------------------------------------------
# Singleton
# ---------------------------------------------------------------------------

_instance: KuzuStore | None = None


def get_kuzu_store() -> KuzuStore:
    global _instance
    if _instance is None:
        _instance = KuzuStore(os.environ.get("KUZU_DB_PATH", ".kuzu-mangle-qs"))
    return _instance


def _reset_kuzu_store() -> None:
    global _instance
    _instance = None
