# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2024 SAP SE
"""
KùzuDB Graph-RAG store for langchain-integration-for-sap-hana-cloud MCP server.

Schema:
  Nodes  : HanaVectorStore, EmbeddingDeployment, HanaSchema
  Edges  : USES_DEPLOYMENT  (HanaVectorStore → EmbeddingDeployment)
           LIVES_IN          (HanaVectorStore → HanaSchema)
           RELATED_SCHEMA    (HanaSchema → HanaSchema)

Gracefully degrades when the `kuzu` Python package is not installed.
"""
from __future__ import annotations

import os
from typing import Any

# ---------------------------------------------------------------------------
# KuzuStore
# ---------------------------------------------------------------------------

class KuzuStore:
    """Embedded KùzuDB graph store for HANA LangChain entity relationships."""

    def __init__(self, db_path: str = ".kuzu-langchain-hana") -> None:
        self._db_path = db_path
        self._db: Any = None
        self._conn: Any = None
        self._available: bool = False
        self._schema_ready: bool = False
        self._init()

    def _init(self) -> None:
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
            """CREATE NODE TABLE IF NOT EXISTS HanaVectorStore (
                storeId        STRING,
                tableName      STRING,
                embeddingModel STRING,
                schema         STRING,
                PRIMARY KEY (storeId)
            )""",
            """CREATE NODE TABLE IF NOT EXISTS EmbeddingDeployment (
                deploymentId  STRING,
                modelName     STRING,
                resourceGroup STRING,
                status        STRING,
                PRIMARY KEY (deploymentId)
            )""",
            """CREATE NODE TABLE IF NOT EXISTS HanaSchema (
                schemaId       STRING,
                schemaName     STRING,
                classification STRING,
                PRIMARY KEY (schemaId)
            )""",
            # Relationship tables
            """CREATE REL TABLE IF NOT EXISTS USES_DEPLOYMENT (
                FROM HanaVectorStore TO EmbeddingDeployment
            )""",
            """CREATE REL TABLE IF NOT EXISTS LIVES_IN (
                FROM HanaVectorStore TO HanaSchema
            )""",
            """CREATE REL TABLE IF NOT EXISTS RELATED_SCHEMA (
                FROM HanaSchema TO HanaSchema
            )""",
        ]

        for stmt in ddl:
            self._conn.execute(stmt)

        self._schema_ready = True

    # ------------------------------------------------------------------
    # Upsert helpers
    # ------------------------------------------------------------------

    def upsert_vector_store(
        self,
        store_id: str,
        table_name: str,
        embedding_model: str,
        schema: str,
    ) -> None:
        if not self._available or not self._conn:
            return
        self._conn.execute(
            "MERGE (s:HanaVectorStore {storeId: $id}) "
            "ON MATCH SET s.tableName = $tn, s.embeddingModel = $em, s.schema = $sc "
            "ON CREATE SET s.tableName = $tn, s.embeddingModel = $em, s.schema = $sc",
            {"id": store_id, "tn": table_name, "em": embedding_model, "sc": schema},
        )

    def upsert_deployment(
        self,
        deployment_id: str,
        model_name: str,
        resource_group: str,
        status: str,
    ) -> None:
        if not self._available or not self._conn:
            return
        self._conn.execute(
            "MERGE (d:EmbeddingDeployment {deploymentId: $id}) "
            "ON MATCH SET d.modelName = $mn, d.resourceGroup = $rg, d.status = $st "
            "ON CREATE SET d.modelName = $mn, d.resourceGroup = $rg, d.status = $st",
            {"id": deployment_id, "mn": model_name, "rg": resource_group, "st": status},
        )

    def upsert_schema(
        self,
        schema_id: str,
        schema_name: str,
        classification: str,
    ) -> None:
        if not self._available or not self._conn:
            return
        self._conn.execute(
            "MERGE (h:HanaSchema {schemaId: $id}) "
            "ON MATCH SET h.schemaName = $sn, h.classification = $cl "
            "ON CREATE SET h.schemaName = $sn, h.classification = $cl",
            {"id": schema_id, "sn": schema_name, "cl": classification},
        )

    # ------------------------------------------------------------------
    # Link helpers
    # ------------------------------------------------------------------

    def link_store_deployment(self, store_id: str, deployment_id: str) -> None:
        if not self._available or not self._conn:
            return
        self._conn.execute(
            "MATCH (s:HanaVectorStore {storeId: $sid}), "
            "(d:EmbeddingDeployment {deploymentId: $did}) "
            "MERGE (s)-[:USES_DEPLOYMENT]->(d)",
            {"sid": store_id, "did": deployment_id},
        )

    def link_store_schema(self, store_id: str, schema_id: str) -> None:
        if not self._available or not self._conn:
            return
        self._conn.execute(
            "MATCH (s:HanaVectorStore {storeId: $sid}), "
            "(h:HanaSchema {schemaId: $hid}) "
            "MERGE (s)-[:LIVES_IN]->(h)",
            {"sid": store_id, "hid": schema_id},
        )

    def link_schemas(self, from_id: str, to_id: str) -> None:
        if not self._available or not self._conn:
            return
        self._conn.execute(
            "MATCH (a:HanaSchema {schemaId: $from}), (b:HanaSchema {schemaId: $to}) "
            "MERGE (a)-[:RELATED_SCHEMA]->(b)",
            {"from": from_id, "to": to_id},
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

    def get_store_context(self, store_id: str) -> list[dict]:
        """Return embedding deployments connected to a vector store."""
        if not self._available:
            return []
        return self.run_query(
            "MATCH (s:HanaVectorStore {storeId: $id})-[:USES_DEPLOYMENT]->(d:EmbeddingDeployment) "
            "RETURN d.deploymentId AS deploymentId, d.modelName AS modelName, "
            "d.resourceGroup AS resourceGroup, d.status AS status, "
            "'uses_deployment' AS relation",
            {"id": store_id},
        )

    def get_schema_context(self, schema_id: str) -> list[dict]:
        """Return vector stores that live in a given HANA schema."""
        if not self._available:
            return []
        return self.run_query(
            "MATCH (s:HanaVectorStore)-[:LIVES_IN]->(h:HanaSchema {schemaId: $id}) "
            "RETURN s.storeId AS storeId, s.tableName AS tableName, "
            "s.embeddingModel AS embeddingModel, 'lives_in' AS relation",
            {"id": schema_id},
        )


# ---------------------------------------------------------------------------
# Singleton
# ---------------------------------------------------------------------------

_instance: KuzuStore | None = None


def get_kuzu_store() -> KuzuStore:
    global _instance
    if _instance is None:
        _instance = KuzuStore(os.environ.get("KUZU_DB_PATH", ".kuzu-langchain-hana"))
    return _instance


def _reset_kuzu_store() -> None:
    global _instance
    _instance = None
