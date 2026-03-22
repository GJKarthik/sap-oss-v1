"""
Data source management routes for SAP AI Fabric Console.
"""

from typing import Any, Dict, List, Optional

from fastapi import APIRouter, HTTPException, status
from pydantic import BaseModel, Field

router = APIRouter()


# ---------------------------------------------------------------------------
# Models
# ---------------------------------------------------------------------------

class DataSource(BaseModel):
    id: str
    name: str
    source_type: str  # "hana", "s3", "blob", "jdbc"
    connection_status: str = "disconnected"
    config: Dict[str, Any] = Field(default_factory=dict)
    last_sync: Optional[str] = None


class DataSourceCreateRequest(BaseModel):
    name: str
    source_type: str
    config: Dict[str, Any] = Field(default_factory=dict)


class DataSourceListResponse(BaseModel):
    datasources: List[DataSource]
    total: int


# ---------------------------------------------------------------------------
# In-memory store
# ---------------------------------------------------------------------------

_datasources: List[DataSource] = []
_counter = 0


# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------

@router.get("/", response_model=DataSourceListResponse)
async def list_datasources():
    """List all registered data sources."""
    return DataSourceListResponse(datasources=_datasources, total=len(_datasources))


@router.post("/", response_model=DataSource, status_code=status.HTTP_201_CREATED)
async def create_datasource(body: DataSourceCreateRequest):
    """Register a new data source."""
    global _counter
    _counter += 1
    ds = DataSource(
        id=f"ds-{_counter:04d}",
        name=body.name,
        source_type=body.source_type,
        config=body.config,
    )
    _datasources.append(ds)
    return ds


@router.get("/{datasource_id}", response_model=DataSource)
async def get_datasource(datasource_id: str):
    """Get data source details."""
    for ds in _datasources:
        if ds.id == datasource_id:
            return ds
    raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=f"Data source '{datasource_id}' not found")


@router.delete("/{datasource_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_datasource(datasource_id: str):
    """Remove a data source."""
    global _datasources
    before = len(_datasources)
    _datasources = [ds for ds in _datasources if ds.id != datasource_id]
    if len(_datasources) == before:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=f"Data source '{datasource_id}' not found")


@router.post("/{datasource_id}/test")
async def test_connection(datasource_id: str):
    """Test connectivity to a data source."""
    for ds in _datasources:
        if ds.id == datasource_id:
            # In production, actually test the connection
            ds.connection_status = "connected"
            return {"id": ds.id, "connection_status": "connected"}
    raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=f"Data source '{datasource_id}' not found")
