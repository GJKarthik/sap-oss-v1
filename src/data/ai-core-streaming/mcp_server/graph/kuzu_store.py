# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2024 SAP SE
"""
KùzuDB Graph Store for AI Core Streaming MCP Server.

Maintains a property graph of streaming AI inference entities used to
enrich stream-status responses with deployment and routing context.

Schema
------
Node tables
  Deployment       – an AI Core deployed model/endpoint
  StreamSession    – an active or historical streaming session
  RoutingDecision  – a security-class routing outcome (aicore/vllm/blocked)

Relationship tables
  SERVED_BY  – StreamSession → Deployment   (session uses a deployment)
  ROUTED_AS  – StreamSession → RoutingDecision  (session's routing outcome)
  HANDLES    – Deployment → RoutingDecision  (deployment handles a route class)

Usage
-----
    from mcp_server.graph.kuzu_store import get_kuzu_store

    store = get_kuzu_store()
    store.ensure_schema()
    store.upsert_deployment("dep-abc", "gpt-4", "default", "running")
    store.upsert_stream("s1a2b3c4", "dep-abc", "active", "public")
    store.upsert_routing_decision("rd-001", "public", "aicore")
    store.link_session_deployment("s1a2b3c4", "dep-abc")
    store.link_session_routing("s1a2b3c4", "rd-001")
    ctx = store.get_stream_context("s1a2b3c4")
"""

import os
import sys
from typing import Any

KUZU_DB_PATH: str = os.environ.get("KUZU_DB_PATH", ":memory:").strip()

_singleton: "KuzuStore | None" = None


def get_kuzu_store() -> "KuzuStore":
    global _singleton
    if _singleton is None:
        _singleton = KuzuStore(KUZU_DB_PATH)
    return _singleton


def _reset_kuzu_store() -> None:
    """Reset the singleton (test use only)."""
    global _singleton
    _singleton = None


class KuzuStore:
    """Embedded KùzuDB graph store for ai-core-streaming graph-RAG features."""

    def __init__(self, db_path: str = ":memory:") -> None:
        self.db_path = db_path
        self._db: Any = None
        self._conn: Any = None
        self._available = self._init_db()
        self._schema_ready = False

    # ------------------------------------------------------------------
    # M1 – Initialisation
    # ------------------------------------------------------------------

    def _init_db(self) -> bool:
        try:
            import kuzu  # type: ignore[import]
            self._db = kuzu.Database(self.db_path)
            self._conn = kuzu.Connection(self._db)
            print(f"INFO: KùzuDB initialised at '{self.db_path}'", file=sys.stderr)
            return True
        except Exception as exc:
            msg = str(exc)
            if "No module named" in msg or "ModuleNotFoundError" in msg:
                print(
                    "WARNING: kuzu Python package not installed; graph-RAG features disabled. "
                    "Add 'kuzu>=0.7.0' to mcp_server/requirements.txt to enable.",
                    file=sys.stderr,
                )
            else:
                print(f"WARNING: KùzuDB init failed: {msg}", file=sys.stderr)
            return False

    def available(self) -> bool:
        return self._available

    def ensure_schema(self) -> None:
        if not self._available or self._schema_ready:
            return
        stmts = [
            # Node: an AI Core deployed model/endpoint
            """CREATE NODE TABLE IF NOT EXISTS Deployment (
                deployment_id  STRING,
                model_name     STRING,
                resource_group STRING,
                status         STRING,
                PRIMARY KEY (deployment_id)
            )""",
            # Node: an active or historical streaming session
            """CREATE NODE TABLE IF NOT EXISTS StreamSession (
                stream_id      STRING,
                deployment_id  STRING,
                status         STRING,
                security_class STRING,
                PRIMARY KEY (stream_id)
            )""",
            # Node: a security-class routing outcome
            """CREATE NODE TABLE IF NOT EXISTS RoutingDecision (
                decision_id    STRING,
                security_class STRING,
                route          STRING,
                PRIMARY KEY (decision_id)
            )""",
            # Relationship: session served by a deployment
            """CREATE REL TABLE IF NOT EXISTS SERVED_BY (
                FROM StreamSession TO Deployment
            )""",
            # Relationship: session routing outcome
            """CREATE REL TABLE IF NOT EXISTS ROUTED_AS (
                FROM StreamSession TO RoutingDecision
            )""",
            # Relationship: deployment handles a route class
            """CREATE REL TABLE IF NOT EXISTS HANDLES (
                FROM Deployment TO RoutingDecision
            )""",
        ]
        for stmt in stmts:
            try:
                self._exec(stmt)
            except Exception as exc:
                msg = str(exc)
                if "already exists" not in msg:
                    print(f"KùzuDB schema stmt skipped ({msg[:80]})", file=sys.stderr)
        self._schema_ready = True

    # ------------------------------------------------------------------
    # Low-level query helper
    # ------------------------------------------------------------------

    def _exec(self, cypher: str, params: dict | None = None) -> Any:
        if params:
            return self._conn.execute(cypher, params)
        return self._conn.execute(cypher)

    # ------------------------------------------------------------------
    # M2 helpers – upsert operations called by kuzu_index tool
    # ------------------------------------------------------------------

    def upsert_deployment(
        self,
        deployment_id: str,
        model_name: str = "",
        resource_group: str = "default",
        status: str = "unknown",
    ) -> None:
        if not self._available:
            return
        try:
            self._exec(
                "MERGE (d:Deployment {deployment_id: $id}) "
                "SET d.model_name = $model, d.resource_group = $rg, d.status = $status",
                {"id": deployment_id, "model": model_name, "rg": resource_group, "status": status},
            )
        except Exception:
            try:
                self._exec(
                    "CREATE (d:Deployment {deployment_id: $id, model_name: $model, "
                    "resource_group: $rg, status: $status})",
                    {"id": deployment_id, "model": model_name, "rg": resource_group, "status": status},
                )
            except Exception as exc2:
                print(f"upsert_deployment failed for {deployment_id}: {exc2}", file=sys.stderr)

    def upsert_stream(
        self,
        stream_id: str,
        deployment_id: str = "",
        status: str = "active",
        security_class: str = "public",
    ) -> None:
        if not self._available:
            return
        try:
            self._exec(
                "MERGE (s:StreamSession {stream_id: $id}) "
                "SET s.deployment_id = $dep, s.status = $status, s.security_class = $sc",
                {"id": stream_id, "dep": deployment_id, "status": status, "sc": security_class},
            )
        except Exception:
            try:
                self._exec(
                    "CREATE (s:StreamSession {stream_id: $id, deployment_id: $dep, "
                    "status: $status, security_class: $sc})",
                    {"id": stream_id, "dep": deployment_id, "status": status, "sc": security_class},
                )
            except Exception as exc2:
                print(f"upsert_stream failed for {stream_id}: {exc2}", file=sys.stderr)

    def upsert_routing_decision(
        self,
        decision_id: str,
        security_class: str = "public",
        route: str = "aicore",
    ) -> None:
        if not self._available:
            return
        try:
            self._exec(
                "MERGE (r:RoutingDecision {decision_id: $id}) "
                "SET r.security_class = $sc, r.route = $route",
                {"id": decision_id, "sc": security_class, "route": route},
            )
        except Exception:
            try:
                self._exec(
                    "CREATE (r:RoutingDecision {decision_id: $id, "
                    "security_class: $sc, route: $route})",
                    {"id": decision_id, "sc": security_class, "route": route},
                )
            except Exception as exc2:
                print(f"upsert_routing_decision failed for {decision_id}: {exc2}", file=sys.stderr)

    def link_session_deployment(self, stream_id: str, deployment_id: str) -> None:
        if not self._available:
            return
        try:
            self._exec(
                "MATCH (s:StreamSession {stream_id: $sid}), "
                "(d:Deployment {deployment_id: $did}) "
                "CREATE (s)-[:SERVED_BY]->(d)",
                {"sid": stream_id, "did": deployment_id},
            )
        except Exception as exc:
            print(f"link_session_deployment failed {stream_id}->{deployment_id}: {exc}", file=sys.stderr)

    def link_session_routing(self, stream_id: str, decision_id: str) -> None:
        if not self._available:
            return
        try:
            self._exec(
                "MATCH (s:StreamSession {stream_id: $sid}), "
                "(r:RoutingDecision {decision_id: $rid}) "
                "CREATE (s)-[:ROUTED_AS]->(r)",
                {"sid": stream_id, "rid": decision_id},
            )
        except Exception as exc:
            print(f"link_session_routing failed {stream_id}->{decision_id}: {exc}", file=sys.stderr)

    def link_deployment_routing(self, deployment_id: str, decision_id: str) -> None:
        if not self._available:
            return
        try:
            self._exec(
                "MATCH (d:Deployment {deployment_id: $did}), "
                "(r:RoutingDecision {decision_id: $rid}) "
                "CREATE (d)-[:HANDLES]->(r)",
                {"did": deployment_id, "rid": decision_id},
            )
        except Exception as exc:
            print(f"link_deployment_routing failed {deployment_id}->{decision_id}: {exc}", file=sys.stderr)

    # ------------------------------------------------------------------
    # M3 helper – raw Cypher query used by kuzu_query tool
    # ------------------------------------------------------------------

    def run_query(self, cypher: str, params: dict | None = None) -> list[dict]:
        if not self._available:
            return []
        try:
            result = self._exec(cypher, params or {})
            col_names: list[str] = result.get_column_names() if hasattr(result, "get_column_names") else []
            rows: list[dict] = []
            while result.has_next():
                row = result.get_next()
                rows.append(dict(zip(col_names, row)))
            return rows
        except Exception as exc:
            print(f"KùzuDB query failed: {exc}", file=sys.stderr)
            return []

    # ------------------------------------------------------------------
    # M4 helpers – graph context enrichment for stream_status
    # ------------------------------------------------------------------

    def get_stream_context(self, stream_id: str) -> list[dict]:
        """Return deployment and routing context for a given stream_id."""
        if not self._available:
            return []

        dep_rows = self.run_query(
            "MATCH (s:StreamSession {stream_id: $id})-[:SERVED_BY]->(d:Deployment) "
            "RETURN d.deployment_id AS deployment_id, d.model_name AS model_name, "
            "d.status AS status, 'served_by' AS relation LIMIT 5",
            {"id": stream_id},
        )
        route_rows = self.run_query(
            "MATCH (s:StreamSession {stream_id: $id})-[:ROUTED_AS]->(r:RoutingDecision) "
            "RETURN r.decision_id AS decision_id, r.security_class AS security_class, "
            "r.route AS route, 'routed_as' AS relation LIMIT 5",
            {"id": stream_id},
        )
        return dep_rows + route_rows

    def get_deployment_context(self, deployment_id: str) -> list[dict]:
        """Return sessions and routing decisions for a given deployment_id."""
        if not self._available:
            return []

        session_rows = self.run_query(
            "MATCH (s:StreamSession)-[:SERVED_BY]->(d:Deployment {deployment_id: $id}) "
            "RETURN s.stream_id AS stream_id, s.status AS status, "
            "s.security_class AS security_class, 'session' AS relation LIMIT 10",
            {"id": deployment_id},
        )
        route_rows = self.run_query(
            "MATCH (d:Deployment {deployment_id: $id})-[:HANDLES]->(r:RoutingDecision) "
            "RETURN r.decision_id AS decision_id, r.security_class AS security_class, "
            "r.route AS route, 'handles' AS relation LIMIT 10",
            {"id": deployment_id},
        )
        return session_rows + route_rows
