"""
HANA Cloud Vector Store for OData Vocabularies

Production-ready SAP HANA Cloud vector store integration for vocabulary
search and indexing using HANA Cloud's native REAL_VECTOR column type
for semantic search and
full-text search via CONTAINS().
"""

import logging
from typing import Any, Dict, List, Optional
from dataclasses import dataclass
from datetime import datetime

logger = logging.getLogger(__name__)


@dataclass
class VectorStoreStats:
    """HANA vector store statistics"""
    total_requests: int = 0
    failed_requests: int = 0
    avg_response_time_ms: float = 0
    last_error: Optional[str] = None
    last_error_time: Optional[datetime] = None
    tables_created: int = 0


class HANAVectorClient:
    """
    HANA Cloud vector store client for OData vocabulary operations.

    Features:
    - Table management with vocabulary-optimised column layouts
    - Bulk document upsert
    - Full-text search via CONTAINS()
    - Semantic (vector) search via COSINE_SIMILARITY on REAL_VECTOR columns
    - Vocabulary-aware query building
    """

    # DDL templates ----------------------------------------------------------

    _VOCABULARY_DDL = """
        CREATE COLUMN TABLE IF NOT EXISTS "{schema}"."{prefix}_VOCABULARY" (
            "TERM_NAME"       NVARCHAR(256) NOT NULL,
            "QUALIFIED_NAME"  NVARCHAR(512) PRIMARY KEY,
            "VOCABULARY"      NVARCHAR(128),
            "NAMESPACE"       NVARCHAR(512),
            "TERM_TYPE"       NVARCHAR(64),
            "DESCRIPTION"     NCLOB,
            "APPLIES_TO"      NVARCHAR(512),
            "BASE_TYPE"       NVARCHAR(256),
            "EMBEDDING"       REAL_VECTOR({embedding_dimensions}),
            "CREATED_AT"      TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            "UPDATED_AT"      TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        )
    """

    _ENTITY_DDL = """
        CREATE COLUMN TABLE IF NOT EXISTS "{schema}"."{prefix}_ENTITIES" (
            "ENTITY_TYPE"          NVARCHAR(256),
            "ENTITY_ID"            NVARCHAR(512) PRIMARY KEY,
            "SCHEMA_NAME"          NVARCHAR(128),
            "SERVICE"              NVARCHAR(256),
            "VOCABULARY_CONTEXT"   NVARCHAR(256),
            "EMBEDDING"            REAL_VECTOR({embedding_dimensions}),
            "SOURCE_SYSTEM"        NVARCHAR(128),
            "CREATED_AT"           TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            "UPDATED_AT"           TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        )
    """

    _AUDIT_DDL = """
        CREATE COLUMN TABLE IF NOT EXISTS "{schema}"."{prefix}_AUDIT" (
            "AUDIT_ID"         NVARCHAR(64) PRIMARY KEY,
            "TIMESTAMP"        TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            "QUERY_ID"         NVARCHAR(64),
            "EVENT_TYPE"       NVARCHAR(64),
            "QUERY"            NCLOB,
            "QUERY_HASH"       NVARCHAR(128),
            "USER_ID"          NVARCHAR(128),
            "USER_ROLE"        NVARCHAR(64),
            "CLIENT_IP"        NVARCHAR(45),
            "TOOL_NAME"        NVARCHAR(128),
            "DURATION_MS"      DOUBLE,
            "SUCCESS"          BOOLEAN,
            "ERROR_MESSAGE"    NCLOB
        )
    """

    def __init__(self, config: "HANAConfig"):
        """
        Initialize HANA vector store client.

        Args:
            config: HANAConfig from settings
        """
        self.config = config
        self.stats = VectorStoreStats()
        self._connector = None
        self._connected = False

    def _schema(self) -> str:
        return self.config.get_vector_schema()

    def _table_prefix(self) -> str:
        return self.config.vector_table_prefix

    def attach_connector(self, connector) -> None:
        """Attach an existing HANAConnector for SQL execution."""
        self._connector = connector
        self._connected = connector._connected

    def connect(self) -> bool:
        """
        Establish connection via the underlying HANAConnector.

        Returns:
            True if connection successful
        """
        if self._connector is None:
            from connectors.hana import get_hana_connector
            self._connector = get_hana_connector(self.config)

        if not self._connector._connected:
            ok = self._connector.connect()
            if not ok:
                return False

        self._connected = True
        return True

    # -- Table management ----------------------------------------------------

    def create_vocabulary_table(self, table_suffix: str = None) -> Dict:
        """Create table with vocabulary-optimised layout."""
        return self._create_table(
            self._VOCABULARY_DDL, table_suffix or "VOCABULARY"
        )

    def create_entity_table(self, table_suffix: str = None) -> Dict:
        """Create table for OData entities."""
        return self._create_table(
            self._ENTITY_DDL, table_suffix or "ENTITIES"
        )

    def create_audit_table(self, table_suffix: str = None) -> Dict:
        """Create table for audit logs."""
        return self._create_table(
            self._AUDIT_DDL, table_suffix or "AUDIT"
        )

    def _create_table(self, ddl_template: str, suffix: str) -> Dict:
        """Execute a DDL template."""
        if self._connector is None or not self._connected:
            self.stats.tables_created += 1
            table = f"{self._table_prefix()}_{suffix}"
            return {"simulated": True, "table": table, "acknowledged": True}

        ddl = ddl_template.format(
            schema=self._schema(),
            prefix=self._table_prefix(),
            embedding_dimensions=self.config.vector_embedding_dimensions,
        )
        result = self._connector.execute(ddl)
        if "error" not in result:
            self.stats.tables_created += 1
            table = f"{self._table_prefix()}_{suffix}"
            logger.info(f"Created table: {table}")
            return {"acknowledged": True, "table": table}
        return result

    # -- Indexing / upsert ---------------------------------------------------

    def index_vocabulary_term(self, term: Dict, table_suffix: str = None) -> Dict:
        """
        Upsert a vocabulary term.

        Args:
            term: Term document with at least ``qualified_name``
            table_suffix: Override table suffix (default VOCABULARY)

        Returns:
            Upsert result
        """
        table = f"{self._table_prefix()}_{table_suffix or 'VOCABULARY'}"
        term["updated_at"] = datetime.utcnow().isoformat()

        if self._connector is None or not self._connected:
            return {
                "simulated": True,
                "result": "created",
                "_id": term.get("qualified_name"),
            }

        sql = f"""
            UPSERT "{self._schema()}"."{table}"
            ("TERM_NAME", "QUALIFIED_NAME", "VOCABULARY", "DESCRIPTION", "UPDATED_AT")
            VALUES (?, ?, ?, ?, CURRENT_TIMESTAMP)
            WITH PRIMARY KEY
        """
        params = (
            term.get("term_name", ""),
            term.get("qualified_name", term.get("term_name", "")),
            term.get("vocabulary", ""),
            term.get("description", ""),
        )
        result = self._connector.execute(sql, params)
        self.stats.total_requests += 1
        if "error" in result:
            self.stats.failed_requests += 1
            self.stats.last_error = result["error"]
            self.stats.last_error_time = datetime.utcnow()
            return result
        return {"result": "upserted", "_id": params[1]}

    def bulk_index(self, documents: List[Dict], table_suffix: str) -> Dict:
        """
        Bulk upsert documents.

        Args:
            documents: List of documents
            table_suffix: Target table suffix

        Returns:
            Bulk result
        """
        if self._connector is None or not self._connected:
            return {"simulated": True, "indexed": len(documents), "errors": False}

        errors = 0
        for doc in documents:
            r = self.index_vocabulary_term(doc, table_suffix)
            if "error" in r:
                errors += 1

        return {
            "indexed": len(documents) - errors,
            "errors": errors > 0,
            "error_count": errors,
        }

    # -- Search --------------------------------------------------------------

    def search(self, query: str, table_suffix: str = None, size: int = 10) -> Dict:
        """
        Full-text search for vocabulary terms using CONTAINS().

        Args:
            query: Search query
            table_suffix: Table suffix (default VOCABULARY)
            size: Max results

        Returns:
            Search results
        """
        table = f"{self._table_prefix()}_{table_suffix or 'VOCABULARY'}"

        if self._connector is None or not self._connected:
            return self._simulate_search(query, size)

        sql = f"""
            SELECT "TERM_NAME", "QUALIFIED_NAME", "VOCABULARY", "DESCRIPTION",
                   SCORE() AS "SCORE"
            FROM "{self._schema()}"."{table}"
            WHERE CONTAINS(("TERM_NAME", "DESCRIPTION", "VOCABULARY"), ?, FUZZY(0.7))
            ORDER BY SCORE() DESC
            LIMIT {int(size)}
        """
        result = self._connector.execute(sql, (query,))
        self.stats.total_requests += 1

        if "error" in result:
            self.stats.failed_requests += 1
            return {"error": result["error"]}

        hits = []
        for row in result.get("rows", []):
            hits.append({
                "id": row[1],
                "score": row[4] if len(row) > 4 else 1.0,
                "source": {
                    "term_name": row[0],
                    "vocabulary": row[2],
                    "description": row[3],
                },
            })

        return {
            "total": len(hits),
            "hits": hits,
            "took_ms": result.get("duration_ms", 0),
        }

    def semantic_search(
        self,
        embedding: List[float],
        table_suffix: str = None,
        size: int = 10,
    ) -> Dict:
        """
        Semantic search using COSINE_SIMILARITY on REAL_VECTOR columns.

        Args:
            embedding: Query embedding vector
            table_suffix: Table suffix (default VOCABULARY)
            size: Max results

        Returns:
            Search results
        """
        table = f"{self._table_prefix()}_{table_suffix or 'VOCABULARY'}"

        if self._connector is None or not self._connected:
            return {"simulated": True, "hits": [], "total": 0}

        vec_literal = "[" + ",".join(str(v) for v in embedding) + "]"
        sql = f"""
            SELECT "TERM_NAME", "QUALIFIED_NAME", "VOCABULARY", "DESCRIPTION",
                   COSINE_SIMILARITY("EMBEDDING", TO_REAL_VECTOR('{vec_literal}')) AS "SCORE"
            FROM "{self._schema()}"."{table}"
            WHERE "EMBEDDING" IS NOT NULL
            ORDER BY "SCORE" DESC
            LIMIT {int(size)}
        """
        result = self._connector.execute(sql)
        self.stats.total_requests += 1

        if "error" in result:
            self.stats.failed_requests += 1
            return {"error": result["error"]}

        hits = []
        for row in result.get("rows", []):
            hits.append({
                "id": row[1],
                "score": row[4] if len(row) > 4 else 0.0,
                "source": {
                    "term_name": row[0],
                    "vocabulary": row[2],
                    "description": row[3],
                },
            })

        return {
            "total": len(hits),
            "hits": hits,
            "took_ms": result.get("duration_ms", 0),
        }

    # -- Helpers -------------------------------------------------------------

    def _simulate_search(self, query: str, size: int) -> Dict:
        """Simulate search for testing"""
        simulated_hits = [
            {
                "id": "UI.LineItem",
                "score": 0.95,
                "source": {
                    "term_name": "LineItem",
                    "vocabulary": "UI",
                    "description": "Collection of line items for a list report",
                },
            },
            {
                "id": "Common.Label",
                "score": 0.88,
                "source": {
                    "term_name": "Label",
                    "vocabulary": "Common",
                    "description": "Human-readable label for a field",
                },
            },
        ]

        return {
            "total": len(simulated_hits),
            "hits": simulated_hits[:size],
            "took_ms": 25,
            "simulated": True,
        }

    def get_stats(self) -> Dict:
        """Get client statistics"""
        return {
            "total_requests": self.stats.total_requests,
            "failed_requests": self.stats.failed_requests,
            "avg_response_time_ms": round(self.stats.avg_response_time_ms, 2),
            "tables_created": self.stats.tables_created,
            "last_error": self.stats.last_error,
            "last_error_time": (
                self.stats.last_error_time.isoformat()
                if self.stats.last_error_time
                else None
            ),
            "connected": self._connected,
            "schema": self._schema(),
            "table_prefix": self._table_prefix(),
        }

    def close(self):
        """Close underlying HANA connection (delegates to connector)."""
        self._connected = False
        logger.info("HANA vector store client closed")


# Singleton instance
_client: Optional[HANAVectorClient] = None


def get_hana_vector_client(config: "HANAConfig" = None) -> HANAVectorClient:
    """Get or create the HANAVectorClient singleton"""
    global _client
    if _client is None:
        if config is None:
            from config.settings import get_settings
            config = get_settings().hana
        _client = HANAVectorClient(config)
    return _client
