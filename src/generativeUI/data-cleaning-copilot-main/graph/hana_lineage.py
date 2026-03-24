# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2024 SAP SE
"""
KùzuDB-HANA Cross-Database Lineage.

Provides federated schema lineage tracking across:
- KùzuDB (local graph for fast traversals)
- HANA Cloud (persistent storage for audit/compliance)

Features:
- Bidirectional sync between KùzuDB and HANA
- Data flow lineage tracking
- Check result correlation
- PII column tracking across tables
"""

from dataclasses import dataclass, field
from datetime import datetime
from typing import Any, Optional
from enum import Enum
import json
import logging
import os

logger = logging.getLogger(__name__)


class LineageType(Enum):
    """Types of data lineage relationships."""
    
    FOREIGN_KEY = "foreign_key"
    DERIVED_FROM = "derived_from"
    COPIED_FROM = "copied_from"
    TRANSFORMED_FROM = "transformed_from"
    AGGREGATED_FROM = "aggregated_from"
    FILTERED_FROM = "filtered_from"
    JOINED_FROM = "joined_from"


class NodeType(Enum):
    """Types of nodes in the lineage graph."""
    
    TABLE = "Table"
    COLUMN = "Column"
    CHECK = "Check"
    VALIDATION_RESULT = "ValidationResult"
    DATA_FLOW = "DataFlow"
    TRANSFORM = "Transform"


@dataclass
class LineageEdge:
    """Represents a lineage relationship."""
    
    source_table: str
    source_column: Optional[str]
    target_table: str
    target_column: Optional[str]
    lineage_type: LineageType
    metadata: dict = field(default_factory=dict)
    created_at: datetime = field(default_factory=datetime.utcnow)


@dataclass
class DataFlowStep:
    """Represents a step in a data flow pipeline."""
    
    step_id: str
    step_name: str
    source_tables: list[str]
    target_tables: list[str]
    transform_type: str  # e.g., "ETL", "CDC", "VIEW", "PROCEDURE"
    transform_sql: Optional[str] = None
    created_by: str = ""
    created_at: datetime = field(default_factory=datetime.utcnow)


class KuzuHANALineage:
    """
    Federated lineage tracking across KùzuDB and HANA Cloud.
    
    Uses KùzuDB for fast graph traversals and HANA for persistent storage.
    """
    
    # Cypher schema for lineage nodes and relationships
    LINEAGE_SCHEMA = """
        -- Node types
        CREATE NODE TABLE IF NOT EXISTS DataFlow (
            flow_id STRING PRIMARY KEY,
            flow_name STRING,
            description STRING,
            created_at TIMESTAMP,
            created_by STRING
        );
        
        CREATE NODE TABLE IF NOT EXISTS Transform (
            transform_id STRING PRIMARY KEY,
            transform_name STRING,
            transform_type STRING,
            transform_sql STRING,
            created_at TIMESTAMP
        );
        
        -- Lineage relationship types
        CREATE REL TABLE IF NOT EXISTS DERIVES_FROM (
            FROM Column TO Column,
            lineage_type STRING,
            confidence FLOAT,
            detected_at TIMESTAMP
        );
        
        CREATE REL TABLE IF NOT EXISTS FLOWS_TO (
            FROM Table TO Table,
            flow_id STRING,
            step_order INT32
        );
        
        CREATE REL TABLE IF NOT EXISTS TRANSFORMED_BY (
            FROM Column TO Transform
        );
        
        CREATE REL TABLE IF NOT EXISTS TRANSFORM_OUTPUT (
            FROM Transform TO Column
        );
        
        CREATE REL TABLE IF NOT EXISTS PART_OF_FLOW (
            FROM Transform TO DataFlow,
            step_order INT32
        );
    """
    
    # HANA DDL for lineage tables
    HANA_LINEAGE_TABLES = {
        "LINEAGE_EDGES": """
            CREATE TABLE IF NOT EXISTS DCC_STORE.LINEAGE_EDGES (
                ID VARCHAR(36) PRIMARY KEY,
                SOURCE_TABLE VARCHAR(256) NOT NULL,
                SOURCE_COLUMN VARCHAR(256),
                TARGET_TABLE VARCHAR(256) NOT NULL,
                TARGET_COLUMN VARCHAR(256),
                LINEAGE_TYPE VARCHAR(64) NOT NULL,
                CONFIDENCE DECIMAL(5,4),
                METADATA NCLOB,
                CREATED_AT TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                CREATED_BY VARCHAR(256)
            )
        """,
        "DATA_FLOWS": """
            CREATE TABLE IF NOT EXISTS DCC_STORE.DATA_FLOWS (
                FLOW_ID VARCHAR(36) PRIMARY KEY,
                FLOW_NAME VARCHAR(256) NOT NULL,
                DESCRIPTION NCLOB,
                SOURCE_SYSTEM VARCHAR(256),
                TARGET_SYSTEM VARCHAR(256),
                SCHEDULE VARCHAR(64),
                CREATED_AT TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                CREATED_BY VARCHAR(256),
                ACTIVE BOOLEAN DEFAULT TRUE
            )
        """,
        "FLOW_STEPS": """
            CREATE TABLE IF NOT EXISTS DCC_STORE.FLOW_STEPS (
                STEP_ID VARCHAR(36) PRIMARY KEY,
                FLOW_ID VARCHAR(36) NOT NULL,
                STEP_ORDER INT NOT NULL,
                STEP_NAME VARCHAR(256),
                TRANSFORM_TYPE VARCHAR(64),
                TRANSFORM_SQL NCLOB,
                SOURCE_TABLES NCLOB,
                TARGET_TABLES NCLOB,
                CREATED_AT TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                FOREIGN KEY (FLOW_ID) REFERENCES DCC_STORE.DATA_FLOWS(FLOW_ID)
            )
        """,
        "PII_LINEAGE": """
            CREATE TABLE IF NOT EXISTS DCC_STORE.PII_LINEAGE (
                ID VARCHAR(36) PRIMARY KEY,
                SOURCE_TABLE VARCHAR(256) NOT NULL,
                SOURCE_COLUMN VARCHAR(256) NOT NULL,
                TARGET_TABLE VARCHAR(256) NOT NULL,
                TARGET_COLUMN VARCHAR(256) NOT NULL,
                PII_TYPE VARCHAR(64),
                PROPAGATION_TYPE VARCHAR(64),
                DETECTED_AT TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                REVIEWED_BY VARCHAR(256),
                REVIEWED_AT TIMESTAMP
            )
        """
    }
    
    def __init__(self, kuzu_store=None, hana_client=None):
        """
        Initialize with optional KùzuDB and HANA connections.
        
        Args:
            kuzu_store: KuzuSchemaStore instance (from graph/kuzu_store.py)
            hana_client: HANAClient instance (from hana/client.py)
        """
        self._kuzu = kuzu_store
        self._hana = hana_client
        self._initialized = False
    
    def _get_kuzu(self):
        """Lazy-load KùzuDB store."""
        if self._kuzu is None:
            try:
                from graph.kuzu_store import get_store
                self._kuzu = get_store()
            except ImportError:
                logger.warning("KùzuDB store not available")
        return self._kuzu
    
    def _get_hana(self):
        """Lazy-load HANA client."""
        if self._hana is None:
            try:
                from hana.client import get_client
                self._hana = get_client()
            except ImportError:
                logger.warning("HANA client not available")
        return self._hana
    
    def initialize(self) -> bool:
        """
        Initialize lineage schema in both KùzuDB and HANA.
        
        Returns:
            True if at least one backend is available
        """
        kuzu_ok = self._init_kuzu_schema()
        hana_ok = self._init_hana_schema()
        self._initialized = kuzu_ok or hana_ok
        return self._initialized
    
    def _init_kuzu_schema(self) -> bool:
        """Create lineage schema in KùzuDB."""
        kuzu = self._get_kuzu()
        if not kuzu:
            return False
        
        try:
            # Schema statements are idempotent
            for stmt in self.LINEAGE_SCHEMA.split(";"):
                stmt = stmt.strip()
                if stmt and not stmt.startswith("--"):
                    kuzu.execute(stmt)
            return True
        except Exception as e:
            logger.error(f"Failed to initialize KùzuDB lineage schema: {e}")
            return False
    
    def _init_hana_schema(self) -> bool:
        """Create lineage tables in HANA."""
        hana = self._get_hana()
        if not hana or not hana.available():
            return False
        
        try:
            for table_name, ddl in self.HANA_LINEAGE_TABLES.items():
                hana.execute(ddl)
            return True
        except Exception as e:
            logger.error(f"Failed to initialize HANA lineage schema: {e}")
            return False
    
    # =========================================================================
    # Lineage Edge Operations
    # =========================================================================
    
    def add_lineage_edge(self, edge: LineageEdge) -> str:
        """
        Add a lineage edge to both KùzuDB and HANA.
        
        Args:
            edge: LineageEdge to add
            
        Returns:
            Edge ID
        """
        import uuid
        edge_id = str(uuid.uuid4())
        
        # Add to KùzuDB for fast traversal
        self._add_edge_to_kuzu(edge_id, edge)
        
        # Persist to HANA for compliance
        self._add_edge_to_hana(edge_id, edge)
        
        return edge_id
    
    def _add_edge_to_kuzu(self, edge_id: str, edge: LineageEdge) -> bool:
        """Add lineage edge to KùzuDB."""
        kuzu = self._get_kuzu()
        if not kuzu:
            return False
        
        try:
            # Create DERIVES_FROM relationship between columns
            if edge.source_column and edge.target_column:
                cypher = """
                    MATCH (src:Column {name: $src_col})-[:BELONGS_TO]->(st:Table {name: $src_table})
                    MATCH (tgt:Column {name: $tgt_col})-[:BELONGS_TO]->(tt:Table {name: $tgt_table})
                    CREATE (src)-[:DERIVES_FROM {
                        lineage_type: $lineage_type,
                        confidence: 1.0,
                        detected_at: $detected_at
                    }]->(tgt)
                """
                kuzu.execute(cypher, {
                    "src_table": edge.source_table,
                    "src_col": edge.source_column,
                    "tgt_table": edge.target_table,
                    "tgt_col": edge.target_column,
                    "lineage_type": edge.lineage_type.value,
                    "detected_at": edge.created_at.isoformat(),
                })
            else:
                # Create FLOWS_TO relationship between tables
                cypher = """
                    MATCH (src:Table {name: $src_table})
                    MATCH (tgt:Table {name: $tgt_table})
                    CREATE (src)-[:FLOWS_TO {
                        flow_id: $edge_id,
                        step_order: 1
                    }]->(tgt)
                """
                kuzu.execute(cypher, {
                    "src_table": edge.source_table,
                    "tgt_table": edge.target_table,
                    "edge_id": edge_id,
                })
            return True
        except Exception as e:
            logger.error(f"Failed to add edge to KùzuDB: {e}")
            return False
    
    def _add_edge_to_hana(self, edge_id: str, edge: LineageEdge) -> bool:
        """Persist lineage edge to HANA."""
        hana = self._get_hana()
        if not hana or not hana.available():
            return False
        
        try:
            sql = """
                INSERT INTO DCC_STORE.LINEAGE_EDGES
                (ID, SOURCE_TABLE, SOURCE_COLUMN, TARGET_TABLE, TARGET_COLUMN, 
                 LINEAGE_TYPE, METADATA, CREATED_AT)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """
            hana.execute(sql, (
                edge_id,
                edge.source_table,
                edge.source_column,
                edge.target_table,
                edge.target_column,
                edge.lineage_type.value,
                json.dumps(edge.metadata),
                edge.created_at,
            ))
            return True
        except Exception as e:
            logger.error(f"Failed to add edge to HANA: {e}")
            return False
    
    # =========================================================================
    # Lineage Query Operations
    # =========================================================================
    
    def get_upstream_lineage(
        self, 
        table: str, 
        column: Optional[str] = None,
        max_depth: int = 10
    ) -> list[dict]:
        """
        Get upstream lineage (data sources) for a table or column.
        
        Uses KùzuDB for fast graph traversal.
        
        Args:
            table: Table name
            column: Optional column name
            max_depth: Maximum traversal depth
            
        Returns:
            List of upstream nodes with paths
        """
        kuzu = self._get_kuzu()
        if not kuzu:
            return []
        
        try:
            if column:
                # Column-level lineage
                cypher = """
                    MATCH path = (c:Column {name: $col})-[:BELONGS_TO]->(t:Table {name: $table})
                    MATCH (c)-[:DERIVES_FROM*1..$depth]->(upstream:Column)
                    RETURN upstream.name AS column, 
                           upstream.table AS table,
                           length(path) AS distance
                    ORDER BY distance
                """
            else:
                # Table-level lineage
                cypher = """
                    MATCH path = (t:Table {name: $table})<-[:FLOWS_TO*1..$depth]-(upstream:Table)
                    RETURN upstream.name AS table,
                           length(path) AS distance
                    ORDER BY distance
                """
            
            result = kuzu.execute(cypher, {
                "table": table,
                "col": column,
                "depth": max_depth,
            })
            return result.get_as_list() if hasattr(result, 'get_as_list') else []
        except Exception as e:
            logger.error(f"Failed to get upstream lineage: {e}")
            return []
    
    def get_downstream_lineage(
        self,
        table: str,
        column: Optional[str] = None,
        max_depth: int = 10
    ) -> list[dict]:
        """
        Get downstream lineage (data consumers) for a table or column.
        
        Args:
            table: Table name
            column: Optional column name
            max_depth: Maximum traversal depth
            
        Returns:
            List of downstream nodes with paths
        """
        kuzu = self._get_kuzu()
        if not kuzu:
            return []
        
        try:
            if column:
                cypher = """
                    MATCH (c:Column {name: $col})-[:BELONGS_TO]->(t:Table {name: $table})
                    MATCH (c)<-[:DERIVES_FROM*1..$depth]-(downstream:Column)
                    RETURN downstream.name AS column,
                           downstream.table AS table,
                           length(path) AS distance
                    ORDER BY distance
                """
            else:
                cypher = """
                    MATCH (t:Table {name: $table})-[:FLOWS_TO*1..$depth]->(downstream:Table)
                    RETURN downstream.name AS table,
                           length(path) AS distance
                    ORDER BY distance
                """
            
            result = kuzu.execute(cypher, {
                "table": table,
                "col": column,
                "depth": max_depth,
            })
            return result.get_as_list() if hasattr(result, 'get_as_list') else []
        except Exception as e:
            logger.error(f"Failed to get downstream lineage: {e}")
            return []
    
    # =========================================================================
    # PII Lineage Tracking
    # =========================================================================
    
    def track_pii_propagation(
        self,
        source_table: str,
        source_column: str,
        target_table: str,
        target_column: str,
        pii_type: str,
        propagation_type: str = "direct_copy"
    ) -> str:
        """
        Track PII data propagation between columns.
        
        This creates lineage specifically for PII fields, enabling:
        - Compliance reporting (GDPR, CCPA)
        - Data subject access requests
        - Impact analysis for PII changes
        
        Args:
            source_table: Source table name
            source_column: Source column name (PII source)
            target_table: Target table name
            target_column: Target column name (PII copy/transform)
            pii_type: Type of PII (email, phone, ssn, etc.)
            propagation_type: How PII was propagated (direct_copy, transformed, masked)
            
        Returns:
            Lineage ID
        """
        import uuid
        lineage_id = str(uuid.uuid4())
        
        # Record in HANA for compliance audit
        hana = self._get_hana()
        if hana and hana.available():
            try:
                sql = """
                    INSERT INTO DCC_STORE.PII_LINEAGE
                    (ID, SOURCE_TABLE, SOURCE_COLUMN, TARGET_TABLE, TARGET_COLUMN,
                     PII_TYPE, PROPAGATION_TYPE)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                """
                hana.execute(sql, (
                    lineage_id,
                    source_table,
                    source_column,
                    target_table,
                    target_column,
                    pii_type,
                    propagation_type,
                ))
            except Exception as e:
                logger.error(f"Failed to track PII propagation in HANA: {e}")
        
        # Also add to lineage graph
        edge = LineageEdge(
            source_table=source_table,
            source_column=source_column,
            target_table=target_table,
            target_column=target_column,
            lineage_type=LineageType.COPIED_FROM if propagation_type == "direct_copy" else LineageType.TRANSFORMED_FROM,
            metadata={"pii_type": pii_type, "propagation": propagation_type},
        )
        self.add_lineage_edge(edge)
        
        return lineage_id
    
    def get_pii_exposure(self, table: str, column: str) -> dict:
        """
        Get full PII exposure analysis for a column.
        
        Returns all places where PII data from this column may exist.
        
        Args:
            table: Table name
            column: Column name
            
        Returns:
            Dict with upstream sources and downstream copies
        """
        return {
            "source": {"table": table, "column": column},
            "upstream": self.get_upstream_lineage(table, column),
            "downstream": self.get_downstream_lineage(table, column),
            "pii_copies": self._get_pii_copies(table, column),
        }
    
    def _get_pii_copies(self, table: str, column: str) -> list[dict]:
        """Get all PII copies from HANA."""
        hana = self._get_hana()
        if not hana or not hana.available():
            return []
        
        try:
            sql = """
                SELECT TARGET_TABLE, TARGET_COLUMN, PII_TYPE, PROPAGATION_TYPE, DETECTED_AT
                FROM DCC_STORE.PII_LINEAGE
                WHERE SOURCE_TABLE = ? AND SOURCE_COLUMN = ?
            """
            result = hana.execute_query(sql, (table, column))
            return [
                {
                    "target_table": row[0],
                    "target_column": row[1],
                    "pii_type": row[2],
                    "propagation_type": row[3],
                    "detected_at": row[4].isoformat() if row[4] else None,
                }
                for row in result
            ]
        except Exception as e:
            logger.error(f"Failed to get PII copies: {e}")
            return []
    
    # =========================================================================
    # Data Flow Operations
    # =========================================================================
    
    def create_data_flow(
        self,
        flow_name: str,
        description: str,
        steps: list[DataFlowStep],
        created_by: str = ""
    ) -> str:
        """
        Create a data flow pipeline definition.
        
        Args:
            flow_name: Name of the data flow
            description: Description
            steps: List of DataFlowStep objects
            created_by: Creator user ID
            
        Returns:
            Flow ID
        """
        import uuid
        flow_id = str(uuid.uuid4())
        
        # Store in HANA
        hana = self._get_hana()
        if hana and hana.available():
            try:
                # Insert flow
                hana.execute("""
                    INSERT INTO DCC_STORE.DATA_FLOWS
                    (FLOW_ID, FLOW_NAME, DESCRIPTION, CREATED_BY)
                    VALUES (?, ?, ?, ?)
                """, (flow_id, flow_name, description, created_by))
                
                # Insert steps
                for i, step in enumerate(steps):
                    hana.execute("""
                        INSERT INTO DCC_STORE.FLOW_STEPS
                        (STEP_ID, FLOW_ID, STEP_ORDER, STEP_NAME, TRANSFORM_TYPE,
                         TRANSFORM_SQL, SOURCE_TABLES, TARGET_TABLES)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """, (
                        step.step_id or str(uuid.uuid4()),
                        flow_id,
                        i + 1,
                        step.step_name,
                        step.transform_type,
                        step.transform_sql,
                        json.dumps(step.source_tables),
                        json.dumps(step.target_tables),
                    ))
            except Exception as e:
                logger.error(f"Failed to create data flow in HANA: {e}")
        
        # Index in KùzuDB for traversal
        self._index_flow_in_kuzu(flow_id, flow_name, steps)
        
        return flow_id
    
    def _index_flow_in_kuzu(
        self, 
        flow_id: str, 
        flow_name: str, 
        steps: list[DataFlowStep]
    ) -> bool:
        """Index data flow in KùzuDB for traversal."""
        kuzu = self._get_kuzu()
        if not kuzu:
            return False
        
        try:
            # Create DataFlow node
            kuzu.execute("""
                CREATE (f:DataFlow {
                    flow_id: $flow_id,
                    flow_name: $flow_name,
                    created_at: datetime()
                })
            """, {"flow_id": flow_id, "flow_name": flow_name})
            
            # Create Transform nodes and relationships
            for i, step in enumerate(steps):
                kuzu.execute("""
                    CREATE (t:Transform {
                        transform_id: $step_id,
                        transform_name: $step_name,
                        transform_type: $transform_type,
                        transform_sql: $sql
                    })
                """, {
                    "step_id": step.step_id,
                    "step_name": step.step_name,
                    "transform_type": step.transform_type,
                    "sql": step.transform_sql or "",
                })
                
                # Link transform to flow
                kuzu.execute("""
                    MATCH (t:Transform {transform_id: $step_id})
                    MATCH (f:DataFlow {flow_id: $flow_id})
                    CREATE (t)-[:PART_OF_FLOW {step_order: $order}]->(f)
                """, {"step_id": step.step_id, "flow_id": flow_id, "order": i + 1})
                
                # Link tables to transform
                for src_table in step.source_tables:
                    kuzu.execute("""
                        MATCH (t:Transform {transform_id: $step_id})
                        MATCH (tbl:Table {name: $table})
                        MERGE (tbl)-[:INPUT_TO]->(t)
                    """, {"step_id": step.step_id, "table": src_table})
                
                for tgt_table in step.target_tables:
                    kuzu.execute("""
                        MATCH (t:Transform {transform_id: $step_id})
                        MATCH (tbl:Table {name: $table})
                        MERGE (t)-[:OUTPUT_TO]->(tbl)
                    """, {"step_id": step.step_id, "table": tgt_table})
            
            return True
        except Exception as e:
            logger.error(f"Failed to index flow in KùzuDB: {e}")
            return False
    
    # =========================================================================
    # Sync Operations
    # =========================================================================
    
    def sync_kuzu_to_hana(self) -> dict:
        """
        Sync lineage data from KùzuDB to HANA.
        
        Useful for batch persistence after many KùzuDB operations.
        
        Returns:
            Sync statistics
        """
        kuzu = self._get_kuzu()
        hana = self._get_hana()
        
        if not kuzu or not hana or not hana.available():
            return {"status": "skipped", "reason": "backends not available"}
        
        stats = {"edges_synced": 0, "flows_synced": 0, "errors": 0}
        
        # TODO: Implement full sync logic
        # This would query all lineage from KùzuDB and upsert to HANA
        
        return stats
    
    def sync_hana_to_kuzu(self) -> dict:
        """
        Sync lineage data from HANA to KùzuDB.
        
        Useful for rebuilding KùzuDB after restart.
        
        Returns:
            Sync statistics
        """
        kuzu = self._get_kuzu()
        hana = self._get_hana()
        
        if not kuzu or not hana or not hana.available():
            return {"status": "skipped", "reason": "backends not available"}
        
        stats = {"edges_synced": 0, "flows_synced": 0, "errors": 0}
        
        # TODO: Implement full sync logic
        # This would query all lineage from HANA and create in KùzuDB
        
        return stats


# =============================================================================
# Module-level convenience functions
# =============================================================================

_lineage: Optional[KuzuHANALineage] = None


def get_lineage() -> KuzuHANALineage:
    """Get singleton lineage instance."""
    global _lineage
    if _lineage is None:
        _lineage = KuzuHANALineage()
        _lineage.initialize()
    return _lineage


def add_lineage(
    source_table: str,
    target_table: str,
    source_column: Optional[str] = None,
    target_column: Optional[str] = None,
    lineage_type: str = "foreign_key"
) -> str:
    """
    Add a lineage relationship.
    
    Args:
        source_table: Source table name
        target_table: Target table name
        source_column: Optional source column
        target_column: Optional target column
        lineage_type: Type of lineage relationship
        
    Returns:
        Edge ID
    """
    edge = LineageEdge(
        source_table=source_table,
        source_column=source_column,
        target_table=target_table,
        target_column=target_column,
        lineage_type=LineageType(lineage_type),
    )
    return get_lineage().add_lineage_edge(edge)


def get_upstream(table: str, column: Optional[str] = None) -> list[dict]:
    """Get upstream lineage for table/column."""
    return get_lineage().get_upstream_lineage(table, column)


def get_downstream(table: str, column: Optional[str] = None) -> list[dict]:
    """Get downstream lineage for table/column."""
    return get_lineage().get_downstream_lineage(table, column)


def track_pii(
    source_table: str,
    source_column: str,
    target_table: str,
    target_column: str,
    pii_type: str
) -> str:
    """Track PII propagation."""
    return get_lineage().track_pii_propagation(
        source_table, source_column,
        target_table, target_column,
        pii_type
    )


def pii_exposure(table: str, column: str) -> dict:
    """Get full PII exposure analysis."""
    return get_lineage().get_pii_exposure(table, column)