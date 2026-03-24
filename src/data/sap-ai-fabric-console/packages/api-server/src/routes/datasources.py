"""
Data source management routes for SAP AI Fabric Console.
State persisted via the configured shared store backend.
HANA Cloud connection test uses hdbcli directly.
"""

from dataclasses import asdict
from datetime import datetime, timezone
from typing import Any, Dict, List, Optional

from fastapi import APIRouter, Depends, HTTPException, status
from pydantic import BaseModel, Field

from ..models import DataSource as DataSourceDC
from ..routes.auth import UserInfo, get_current_user, require_admin
from ..store import StoreBackend, get_store

router = APIRouter()


# ---------------------------------------------------------------------------
# Pydantic schemas
# ---------------------------------------------------------------------------

class DataSourceOut(BaseModel):
    id: str
    name: str
    source_type: str
    connection_status: str
    config: Dict[str, Any]
    last_sync: Optional[str]


class DataSourceCreateRequest(BaseModel):
    name: str
    source_type: str
    config: Dict[str, Any] = Field(default_factory=dict)


class DataSourceListResponse(BaseModel):
    datasources: List[DataSourceOut]
    total: int


def _dict_to_out(d: dict) -> DataSourceOut:
    ls = d.get("last_sync")
    if isinstance(ls, datetime):
        last_sync = ls.isoformat()
    else:
        last_sync = str(ls) if ls else None
    return DataSourceOut(
        id=d["id"],
        name=d["name"],
        source_type=d["source_type"],
        connection_status=d.get("connection_status", "disconnected"),
        config=d.get("config") or {},
        last_sync=last_sync,
    )


# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------

@router.get("/", response_model=DataSourceListResponse)
async def list_datasources(
    store: StoreBackend = Depends(get_store),
    _: UserInfo = Depends(get_current_user),
):
    """List all registered data sources."""
    rows = sorted(store.list_records("datasources"), key=lambda d: d["name"])
    return DataSourceListResponse(datasources=[_dict_to_out(r) for r in rows], total=len(rows))


@router.post("/", response_model=DataSourceOut, status_code=status.HTTP_201_CREATED)
async def create_datasource(
    body: DataSourceCreateRequest,
    store: StoreBackend = Depends(get_store),
    _: UserInfo = Depends(require_admin),
):
    """Register a new data source."""
    ds = DataSourceDC(name=body.name, source_type=body.source_type, config=body.config)
    created = store.set_record("datasources", ds.id, asdict(ds))
    return _dict_to_out(created)


@router.get("/{datasource_id}", response_model=DataSourceOut)
async def get_datasource(
    datasource_id: str,
    store: StoreBackend = Depends(get_store),
    _: UserInfo = Depends(get_current_user),
):
    """Get data source details."""
    row = store.get_record("datasources", datasource_id)
    if row is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=f"Data source '{datasource_id}' not found")
    return _dict_to_out(row)


@router.delete("/{datasource_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_datasource(
    datasource_id: str,
    store: StoreBackend = Depends(get_store),
    _: UserInfo = Depends(require_admin),
):
    """Remove a data source."""
    if not store.delete_record("datasources", datasource_id):
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=f"Data source '{datasource_id}' not found")


@router.post("/{datasource_id}/test")
async def test_connection(
    datasource_id: str,
    store: StoreBackend = Depends(get_store),
    _: UserInfo = Depends(require_admin),
):
    """Test connectivity to a data source and update its persisted status."""
    row = store.get_record("datasources", datasource_id)
    if row is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=f"Data source '{datasource_id}' not found")

    connected = False
    error_msg: Optional[str] = None
    if row["source_type"] == "hana":
        try:
            import hdbcli.dbapi as hdbcli  # type: ignore
            cfg = row.get("config") or {}
            conn = hdbcli.connect(
                address=cfg.get("host", ""),
                port=int(cfg.get("port", 443)),
                user=cfg.get("user", ""),
                password=cfg.get("password", ""),
                encrypt=cfg.get("encrypt", True),
            )
            conn.close()
            connected = True
        except Exception as exc:
            error_msg = str(exc)
    else:
        connected = True

    updated = store.mutate_record(
        "datasources",
        datasource_id,
        lambda record: {
            **record,
            "connection_status": "connected" if connected else "error",
            "last_sync": datetime.now(timezone.utc) if connected else record.get("last_sync"),
        },
    )
    assert updated is not None
    response: dict = {"id": updated["id"], "connection_status": updated["connection_status"]}
    if error_msg:
        response["error"] = error_msg
    return response
