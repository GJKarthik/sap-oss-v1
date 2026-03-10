"""
KùzuDB Graph Store for SAP OData Entity Relationships.

Provides an embedded property graph layer over the Elasticsearch search
results and HANA DTA data.  The graph is used to enrich RAG prompts with
relational context (M4) that plain vector similarity cannot capture.

Schema
------
Node tables
  Entity   – an OData entity type (SalesOrder, Customer, Product …)
  Index    – an Elasticsearch index that stores entities of a type

Relationship tables
  RELATED_TO   – semantic/FK link between two entities found in the same doc
  STORED_IN    – maps an Entity to the Index that contains it

Usage
-----
    from graph.kuzu_store import KuzuStore

    store = KuzuStore()           # in-memory by default
    store.ensure_schema()
    store.upsert_entity("SalesOrder", "SO-1001", {"customer": "CUST-1"})
    store.link_entities("SalesOrder", "SO-1001", "Customer", "CUST-1", "REFERENCES")
    context = store.get_entity_context("SalesOrder", "SO-1001", hops=2)
"""

from __future__ import annotations

import json
import logging
import os
import threading
from typing import Any

logger = logging.getLogger("elasticsearch-mcp.graph")

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
                "Add 'kuzu' to Dockerfile.sap pip install to enable."
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
                # Node: OData entity instance
                """CREATE NODE TABLE IF NOT EXISTS Entity (
                    entity_type STRING,
                    entity_id   STRING,
                    props       STRING,
                    PRIMARY KEY (entity_id)
                )""",
                # Node: Elasticsearch index
                """CREATE NODE TABLE IF NOT EXISTS EsIndex (
                    index_name STRING,
                    PRIMARY KEY (index_name)
                )""",
                # Relationship: entity → entity (FK / semantic)
                """CREATE REL TABLE IF NOT EXISTS RELATED_TO (
                    FROM Entity TO Entity,
                    relation_type STRING
                )""",
                # Relationship: entity → index
                """CREATE REL TABLE IF NOT EXISTS STORED_IN (
                    FROM Entity TO EsIndex
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

    def upsert_entity(
        self,
        entity_type: str,
        entity_id: str,
        props: dict | None = None,
    ) -> None:
        """Insert or update an Entity node."""
        if not self._available:
            return
        props_json = json.dumps(props or {})
        with self._lock:
            try:
                self._conn.execute(
                    "MERGE (e:Entity {entity_id: $id}) "
                    "SET e.entity_type = $type, e.props = $props",
                    {"id": entity_id, "type": entity_type, "props": props_json},
                )
            except Exception:
                try:
                    self._conn.execute(
                        "CREATE (e:Entity {entity_type: $type, entity_id: $id, props: $props})",
                        {"type": entity_type, "id": entity_id, "props": props_json},
                    )
                except Exception as exc:
                    logger.debug("upsert_entity failed for %s/%s: %s", entity_type, entity_id, exc)

    def upsert_index_node(self, index_name: str) -> None:
        """Insert or update an EsIndex node."""
        if not self._available:
            return
        with self._lock:
            try:
                self._conn.execute(
                    "MERGE (i:EsIndex {index_name: $name})",
                    {"name": index_name},
                )
            except Exception:
                try:
                    self._conn.execute(
                        "CREATE (i:EsIndex {index_name: $name})",
                        {"name": index_name},
                    )
                except Exception as exc:
                    logger.debug("upsert_index_node failed for %s: %s", index_name, exc)

    def link_entities(
        self,
        src_type: str,
        src_id: str,
        dst_type: str,
        dst_id: str,
        relation_type: str = "REFERENCES",
    ) -> None:
        """Create a RELATED_TO edge between two entities."""
        if not self._available:
            return
        with self._lock:
            try:
                self._conn.execute(
                    "MATCH (a:Entity {entity_id: $src}), (b:Entity {entity_id: $dst}) "
                    "CREATE (a)-[:RELATED_TO {relation_type: $rel}]->(b)",
                    {"src": src_id, "dst": dst_id, "rel": relation_type},
                )
            except Exception as exc:
                logger.debug("link_entities failed %s->%s: %s", src_id, dst_id, exc)

    def link_entity_to_index(self, entity_id: str, index_name: str) -> None:
        """Create a STORED_IN edge from entity to index."""
        if not self._available:
            return
        with self._lock:
            try:
                self._conn.execute(
                    "MATCH (e:Entity {entity_id: $eid}), (i:EsIndex {index_name: $idx}) "
                    "CREATE (e)-[:STORED_IN]->(i)",
                    {"eid": entity_id, "idx": index_name},
                )
            except Exception as exc:
                logger.debug("link_entity_to_index failed %s->%s: %s", entity_id, index_name, exc)

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
    # M4 helper – graph context enrichment for RAG
    # ------------------------------------------------------------------

    def get_entity_context(
        self,
        entity_type: str,
        entity_id: str,
        hops: int = 2,
    ) -> list[dict]:
        """Return neighbouring entities within `hops` relationship steps.

        The result is used to build the graph-context paragraph injected
        into the ``ai_semantic_search`` RAG prompt (M4).
        """
        if not self._available:
            return []
        cypher = (
            "MATCH p = (src:Entity {entity_id: $id})"
            "-[:RELATED_TO*1.." + str(min(hops, 4)) + "]->(nb:Entity) "
            "RETURN nb.entity_type AS type, nb.entity_id AS id, "
            "nb.props AS props "
            "LIMIT 20"
        )
        return self.run_query(cypher, {"id": entity_id})

    def get_index_entities(self, index_name: str, limit: int = 20) -> list[dict]:
        """Return entities stored in the given Elasticsearch index."""
        if not self._available:
            return []
        cypher = (
            "MATCH (e:Entity)-[:STORED_IN]->(i:EsIndex {index_name: $idx}) "
            "RETURN e.entity_type AS type, e.entity_id AS id, e.props AS props "
            "LIMIT $lim"
        )
        return self.run_query(cypher, {"idx": index_name, "lim": limit})
