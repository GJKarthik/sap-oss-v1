# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2024 SAP SE
"""
KùzuDB Graph Store for World Monitor MCP Server.

Maintains a property graph of geopolitical monitoring entities used to
enrich alert and metrics responses with correlated-event and service context.

Schema
------
Node tables
  GeoEvent     – a geopolitical/natural event (conflict, disaster, cyber, …)
  ServiceNode  – a registered MCP service or monitored endpoint
  AlertRecord  – a named alert with severity and originating service

Relationship tables
  TRIGGERS_ALERT  – GeoEvent → AlertRecord
  MONITORED_BY    – GeoEvent → ServiceNode  (which service tracks this event)
  AFFECTS_SERVICE – AlertRecord → ServiceNode

Usage
-----
    from mcp_server.graph.kuzu_store import get_kuzu_store

    store = get_kuzu_store()
    store.ensure_schema()
    store.upsert_event("evt-001", "conflict", "Ukraine", "Eastern Europe")
    store.upsert_service("world-monitor-mcp", "http://localhost:9170/mcp", "monitoring")
    store.upsert_alert("alt-001", "High Conflict Activity", "critical", "world-monitor-mcp")
    store.link_event_alert("evt-001", "alt-001")
    ctx = store.get_event_context("evt-001")
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
    """Embedded KùzuDB graph store for world-monitor graph-RAG features."""

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
            # Node: a geopolitical / natural / cyber event
            """CREATE NODE TABLE IF NOT EXISTS GeoEvent (
                event_id    STRING,
                event_type  STRING,
                country     STRING,
                region      STRING,
                PRIMARY KEY (event_id)
            )""",
            # Node: a registered MCP service or monitored endpoint
            """CREATE NODE TABLE IF NOT EXISTS ServiceNode (
                name        STRING,
                endpoint    STRING,
                category    STRING,
                PRIMARY KEY (name)
            )""",
            # Node: an alert record
            """CREATE NODE TABLE IF NOT EXISTS AlertRecord (
                alert_id    STRING,
                name        STRING,
                severity    STRING,
                service     STRING,
                PRIMARY KEY (alert_id)
            )""",
            # Relationship: event triggers an alert
            """CREATE REL TABLE IF NOT EXISTS TRIGGERS_ALERT (
                FROM GeoEvent TO AlertRecord
            )""",
            # Relationship: event monitored by a service
            """CREATE REL TABLE IF NOT EXISTS MONITORED_BY (
                FROM GeoEvent TO ServiceNode
            )""",
            # Relationship: alert affects a service
            """CREATE REL TABLE IF NOT EXISTS AFFECTS_SERVICE (
                FROM AlertRecord TO ServiceNode
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

    def upsert_event(
        self,
        event_id: str,
        event_type: str = "",
        country: str = "",
        region: str = "",
    ) -> None:
        if not self._available:
            return
        try:
            self._exec(
                "MERGE (e:GeoEvent {event_id: $id}) "
                "SET e.event_type = $etype, e.country = $country, e.region = $region",
                {"id": event_id, "etype": event_type, "country": country, "region": region},
            )
        except Exception:
            try:
                self._exec(
                    "CREATE (e:GeoEvent {event_id: $id, event_type: $etype, "
                    "country: $country, region: $region})",
                    {"id": event_id, "etype": event_type, "country": country, "region": region},
                )
            except Exception as exc2:
                print(f"upsert_event failed for {event_id}: {exc2}", file=sys.stderr)

    def upsert_service(self, name: str, endpoint: str = "", category: str = "") -> None:
        if not self._available:
            return
        try:
            self._exec(
                "MERGE (s:ServiceNode {name: $name}) "
                "SET s.endpoint = $ep, s.category = $cat",
                {"name": name, "ep": endpoint, "cat": category},
            )
        except Exception:
            try:
                self._exec(
                    "CREATE (s:ServiceNode {name: $name, endpoint: $ep, category: $cat})",
                    {"name": name, "ep": endpoint, "cat": category},
                )
            except Exception as exc2:
                print(f"upsert_service failed for {name}: {exc2}", file=sys.stderr)

    def upsert_alert(
        self,
        alert_id: str,
        name: str = "",
        severity: str = "warning",
        service: str = "",
    ) -> None:
        if not self._available:
            return
        try:
            self._exec(
                "MERGE (a:AlertRecord {alert_id: $id}) "
                "SET a.name = $name, a.severity = $sev, a.service = $svc",
                {"id": alert_id, "name": name, "sev": severity, "svc": service},
            )
        except Exception:
            try:
                self._exec(
                    "CREATE (a:AlertRecord {alert_id: $id, name: $name, "
                    "severity: $sev, service: $svc})",
                    {"id": alert_id, "name": name, "sev": severity, "svc": service},
                )
            except Exception as exc2:
                print(f"upsert_alert failed for {alert_id}: {exc2}", file=sys.stderr)

    def link_event_alert(self, event_id: str, alert_id: str) -> None:
        if not self._available:
            return
        try:
            self._exec(
                "MATCH (e:GeoEvent {event_id: $eid}), (a:AlertRecord {alert_id: $aid}) "
                "CREATE (e)-[:TRIGGERS_ALERT]->(a)",
                {"eid": event_id, "aid": alert_id},
            )
        except Exception as exc:
            print(f"link_event_alert failed {event_id}->{alert_id}: {exc}", file=sys.stderr)

    def link_event_service(self, event_id: str, service_name: str) -> None:
        if not self._available:
            return
        try:
            self._exec(
                "MATCH (e:GeoEvent {event_id: $eid}), (s:ServiceNode {name: $sname}) "
                "CREATE (e)-[:MONITORED_BY]->(s)",
                {"eid": event_id, "sname": service_name},
            )
        except Exception as exc:
            print(f"link_event_service failed {event_id}->{service_name}: {exc}", file=sys.stderr)

    def link_alert_service(self, alert_id: str, service_name: str) -> None:
        if not self._available:
            return
        try:
            self._exec(
                "MATCH (a:AlertRecord {alert_id: $aid}), (s:ServiceNode {name: $sname}) "
                "CREATE (a)-[:AFFECTS_SERVICE]->(s)",
                {"aid": alert_id, "sname": service_name},
            )
        except Exception as exc:
            print(f"link_alert_service failed {alert_id}->{service_name}: {exc}", file=sys.stderr)

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
    # M4 helper – graph context enrichment for get_alerts
    # ------------------------------------------------------------------

    def get_event_context(self, event_id: str) -> list[dict]:
        """Return related alerts and services for a given event_id."""
        if not self._available:
            return []

        alert_rows = self.run_query(
            "MATCH (e:GeoEvent {event_id: $id})-[:TRIGGERS_ALERT]->(a:AlertRecord) "
            "RETURN a.alert_id AS alert_id, a.name AS name, a.severity AS severity, "
            "'triggered_alert' AS relation LIMIT 10",
            {"id": event_id},
        )
        service_rows = self.run_query(
            "MATCH (e:GeoEvent {event_id: $id})-[:MONITORED_BY]->(s:ServiceNode) "
            "RETURN s.name AS service_name, s.endpoint AS endpoint, "
            "'monitored_by' AS relation LIMIT 10",
            {"id": event_id},
        )
        return alert_rows + service_rows

    def get_alert_context(self, alert_id: str) -> list[dict]:
        """Return correlated events and affected services for a given alert_id."""
        if not self._available:
            return []

        event_rows = self.run_query(
            "MATCH (e:GeoEvent)-[:TRIGGERS_ALERT]->(a:AlertRecord {alert_id: $id}) "
            "RETURN e.event_id AS event_id, e.event_type AS event_type, "
            "e.country AS country, 'correlated_event' AS relation LIMIT 10",
            {"id": alert_id},
        )
        service_rows = self.run_query(
            "MATCH (a:AlertRecord {alert_id: $id})-[:AFFECTS_SERVICE]->(s:ServiceNode) "
            "RETURN s.name AS service_name, s.endpoint AS endpoint, "
            "'affects_service' AS relation LIMIT 10",
            {"id": alert_id},
        )
        return event_rows + service_rows
