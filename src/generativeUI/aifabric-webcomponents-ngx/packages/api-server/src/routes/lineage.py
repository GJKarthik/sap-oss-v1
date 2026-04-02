"""
Data lineage routes for SAP AI Fabric Console.
KùzuDB graph query and indexing endpoints.
Falls back gracefully if KùzuDB is not configured.
"""

import os
from typing import Any, Dict, List, Optional

import structlog
from fastapi import APIRouter, Depends, HTTPException, status
from pydantic import BaseModel, Field

from ..routes.auth import UserInfo, get_current_user, log_admin_action, require_admin

router = APIRouter()
logger = structlog.get_logger()

# Path to the KùzuDB database directory (can be overridden by env var)
_KUZU_DB_PATH = os.environ.get("KUZU_DB_PATH", "/tmp/sap-ai-fabric-lineage-db")


# ---------------------------------------------------------------------------
# KùzuDB connection helper
# ---------------------------------------------------------------------------

def _get_kuzu_conn():
    """Return a KùzuDB connection. Raises ImportError if kuzu is not installed."""
    import kuzu  # type: ignore
    db = kuzu.Database(_KUZU_DB_PATH)
    return kuzu.Connection(db)


def _ensure_schema(conn) -> None:
    """Ensure base node/edge tables exist in KùzuDB."""
    stmts = [
        "CREATE NODE TABLE IF NOT EXISTS VectorStore(table_name STRING, embedding_model STRING, documents_added INT64, PRIMARY KEY(table_name))",
        "CREATE NODE TABLE IF NOT EXISTS Deployment(id STRING, status STRING, scenario_id STRING, PRIMARY KEY(id))",
        "CREATE NODE TABLE IF NOT EXISTS Schema(name STRING, source_type STRING, PRIMARY KEY(name))",
        "CREATE REL TABLE IF NOT EXISTS USES(FROM Deployment TO VectorStore)",
        "CREATE REL TABLE IF NOT EXISTS SOURCED_FROM(FROM VectorStore TO Schema)",
    ]
    for stmt in stmts:
        try:
            conn.execute(stmt)
        except Exception:
            pass  # Table may already exist


# ---------------------------------------------------------------------------
# Pydantic schemas
# ---------------------------------------------------------------------------

class GraphQueryRequest(BaseModel):
    cypher: str
    params: Optional[Dict[str, Any]] = None


class GraphQueryResponse(BaseModel):
    rows: List[Any] = Field(default_factory=list)
    row_count: int = 0
    status: str = "completed"


class GraphIndexRequest(BaseModel):
    vector_stores: List[Any] = Field(default_factory=list)
    deployments: List[Any] = Field(default_factory=list)
    schemas: List[Any] = Field(default_factory=list)


class GraphIndexResponse(BaseModel):
    stores_indexed: int = 0
    deployments_indexed: int = 0
    schemas_indexed: int = 0
    status: str = "completed"


# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------

@router.post("/query", response_model=GraphQueryResponse)
async def graph_query(
    body: GraphQueryRequest,
    _: UserInfo = Depends(get_current_user),
):
    """Execute a Cypher query against the KùzuDB lineage graph."""
    if not body.cypher.strip():
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="Cypher query cannot be empty")

    try:
        conn = _get_kuzu_conn()
        _ensure_schema(conn)
        result = conn.execute(body.cypher)
        rows = []
        while result.has_next():
            rows.append(result.get_next())
        return GraphQueryResponse(rows=rows, row_count=len(rows))
    except ImportError:
        logger.warning("kuzu package not installed — lineage queries unavailable")
        return GraphQueryResponse(rows=[], row_count=0, status="kuzu_unavailable")
    except Exception as exc:
        logger.error("KùzuDB query failed", error=str(exc), cypher=body.cypher)
        raise HTTPException(status_code=status.HTTP_500_INTERNAL_SERVER_ERROR, detail=f"Graph query error: {exc}")


@router.post("/index", response_model=GraphIndexResponse)
async def index_entities(
    body: GraphIndexRequest,
    current_user: UserInfo = Depends(require_admin),
):
    """Upsert entities (vector stores, deployments, schemas) into the KùzuDB lineage graph."""
    stores_indexed = 0
    deployments_indexed = 0
    schemas_indexed = 0

    try:
        conn = _get_kuzu_conn()
        _ensure_schema(conn)

        for vs in body.vector_stores:
            table_name = vs.get("table_name", "") if isinstance(vs, dict) else str(vs)
            embedding_model = vs.get("embedding_model", "default") if isinstance(vs, dict) else "default"
            docs = vs.get("documents_added", 0) if isinstance(vs, dict) else 0
            conn.execute(
                "MERGE (v:VectorStore {table_name: $t}) SET v.embedding_model = $e, v.documents_added = $d",
                {"t": table_name, "e": embedding_model, "d": docs},
            )
            stores_indexed += 1

        for dep in body.deployments:
            dep_id = dep.get("id", "") if isinstance(dep, dict) else str(dep)
            dep_status = dep.get("status", "UNKNOWN") if isinstance(dep, dict) else "UNKNOWN"
            scenario = dep.get("scenario_id", "") if isinstance(dep, dict) else ""
            conn.execute(
                "MERGE (d:Deployment {id: $i}) SET d.status = $s, d.scenario_id = $sc",
                {"i": dep_id, "s": dep_status, "sc": scenario},
            )
            deployments_indexed += 1

        for schema in body.schemas:
            name = schema.get("name", "") if isinstance(schema, dict) else str(schema)
            source_type = schema.get("source_type", "unknown") if isinstance(schema, dict) else "unknown"
            conn.execute(
                "MERGE (s:Schema {name: $n}) SET s.source_type = $st",
                {"n": name, "st": source_type},
            )
            schemas_indexed += 1

    except ImportError:
        logger.warning("kuzu package not installed — lineage indexing unavailable")
        stores_indexed = len(body.vector_stores)
        deployments_indexed = len(body.deployments)
        schemas_indexed = len(body.schemas)
    except Exception as exc:
        logger.error("KùzuDB index failed", error=str(exc))
        log_admin_action(
            actor=current_user,
            resource="lineage",
            action="index",
            result="failure",
            reason=str(exc),
        )
        raise HTTPException(status_code=status.HTTP_500_INTERNAL_SERVER_ERROR, detail=f"Graph index error: {exc}")

    log_admin_action(
        actor=current_user,
        resource="lineage",
        action="index",
        result="success",
        stores_indexed=stores_indexed,
        deployments_indexed=deployments_indexed,
        schemas_indexed=schemas_indexed,
    )
    return GraphIndexResponse(
        stores_indexed=stores_indexed,
        deployments_indexed=deployments_indexed,
        schemas_indexed=schemas_indexed,
    )


@router.get("/graph/summary")
async def graph_summary(_: UserInfo = Depends(get_current_user)):
    """Return a summary of the lineage graph (node/edge counts by type)."""
    try:
        conn = _get_kuzu_conn()
        _ensure_schema(conn)

        node_counts: Dict[str, int] = {}
        for label in ("VectorStore", "Deployment", "Schema"):
            r = conn.execute(f"MATCH (n:{label}) RETURN COUNT(n)")
            if r.has_next():
                node_counts[label] = int(r.get_next()[0])

        edge_counts: Dict[str, int] = {}
        for rel in ("USES", "SOURCED_FROM"):
            r = conn.execute(f"MATCH ()-[e:{rel}]->() RETURN COUNT(e)")
            if r.has_next():
                edge_counts[rel] = int(r.get_next()[0])

        total_nodes = sum(node_counts.values())
        total_edges = sum(edge_counts.values())
        return {
            "node_count": total_nodes,
            "edge_count": total_edges,
            "node_types": [{"type": k, "count": v} for k, v in node_counts.items()],
            "edge_types": [{"type": k, "count": v} for k, v in edge_counts.items()],
        }
    except ImportError:
        return {"node_count": 0, "edge_count": 0, "node_types": [], "edge_types": [], "status": "kuzu_unavailable"}
    except Exception as exc:
        logger.error("KùzuDB summary failed", error=str(exc))
        return {"node_count": 0, "edge_count": 0, "node_types": [], "edge_types": [], "error": str(exc)}
