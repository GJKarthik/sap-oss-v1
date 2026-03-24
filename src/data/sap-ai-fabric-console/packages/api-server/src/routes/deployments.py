"""
Deployment management routes for SAP AI Fabric Console.
State persisted via the configured shared store backend.
AI Core deployment IDs are tracked; no Kubernetes / KServe dependency.
"""

from dataclasses import asdict
from datetime import datetime, timezone
from typing import Any, Dict, List, Optional

import structlog
from fastapi import APIRouter, Depends, HTTPException, status
from pydantic import BaseModel, Field

from ..models import Deployment as DeploymentDC
from ..routes.auth import UserInfo, get_current_user, require_admin
from ..store import StoreBackend, get_store

router = APIRouter()
logger = structlog.get_logger()


# ---------------------------------------------------------------------------
# Pydantic schemas
# ---------------------------------------------------------------------------

class DeploymentOut(BaseModel):
    id: str
    status: str
    target_status: Optional[str]
    scenario_id: Optional[str]
    creation_time: str
    details: Dict[str, Any]


class DeploymentCreateRequest(BaseModel):
    scenario_id: str
    configuration: Dict[str, Any] = Field(default_factory=dict)


class DeploymentListResponse(BaseModel):
    resources: List[DeploymentOut]
    count: int


class DeploymentStatusUpdateRequest(BaseModel):
    target_status: str = Field(min_length=1)


def _dict_to_out(d: dict) -> DeploymentOut:
    ct = d.get("creation_time")
    if isinstance(ct, datetime):
        creation_time = ct.isoformat()
    else:
        creation_time = str(ct) if ct else datetime.now(timezone.utc).isoformat()
    return DeploymentOut(
        id=d["id"],
        status=d.get("status", "PENDING"),
        target_status=d.get("target_status"),
        scenario_id=d.get("scenario_id"),
        creation_time=creation_time,
        details=d.get("details") or {},
    )


# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------

@router.get("", response_model=DeploymentListResponse)
async def list_deployments(
    store: StoreBackend = Depends(get_store),
    _: UserInfo = Depends(get_current_user),
):
    """List all deployments from the persistent store."""
    rows = sorted(
        store.list_records("deployments"),
        key=lambda d: d.get("creation_time", ""),
        reverse=True,
    )
    return DeploymentListResponse(resources=[_dict_to_out(r) for r in rows], count=len(rows))


@router.post("", response_model=DeploymentOut, status_code=status.HTTP_201_CREATED)
async def create_deployment(
    body: DeploymentCreateRequest,
    store: StoreBackend = Depends(get_store),
    _: UserInfo = Depends(require_admin),
):
    """Create a new deployment record tracked against SAP AI Core scenario."""
    dep = DeploymentDC(
        status="PENDING",
        target_status="RUNNING",
        scenario_id=body.scenario_id,
        details=body.configuration,
    )
    created = store.set_record("deployments", dep.id, asdict(dep))
    logger.info("Deployment created", deployment_id=dep.id, scenario_id=body.scenario_id)
    return _dict_to_out(created)


@router.get("/{deployment_id}", response_model=DeploymentOut)
async def get_deployment(
    deployment_id: str,
    store: StoreBackend = Depends(get_store),
    _: UserInfo = Depends(get_current_user),
):
    """Get details for a specific deployment."""
    row = store.get_record("deployments", deployment_id)
    if row is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=f"Deployment '{deployment_id}' not found")
    return _dict_to_out(row)


@router.delete("/{deployment_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_deployment(
    deployment_id: str,
    store: StoreBackend = Depends(get_store),
    _: UserInfo = Depends(require_admin),
):
    """Delete a deployment record."""
    if not store.delete_record("deployments", deployment_id):
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=f"Deployment '{deployment_id}' not found")
    logger.info("Deployment deleted", deployment_id=deployment_id)


@router.patch("/{deployment_id}/status")
async def update_deployment_status(
    deployment_id: str,
    body: DeploymentStatusUpdateRequest,
    store: StoreBackend = Depends(get_store),
    _: UserInfo = Depends(require_admin),
):
    """Update deployment target status (e.g. RUNNING, STOPPED)."""
    row = store.mutate_record(
        "deployments",
        deployment_id,
        lambda record: {**record, "target_status": body.target_status},
    )
    if row is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=f"Deployment '{deployment_id}' not found")
    return {"id": row["id"], "target_status": row["target_status"]}
