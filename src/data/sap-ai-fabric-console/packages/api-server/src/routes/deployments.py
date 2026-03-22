"""
Deployment management routes for SAP AI Fabric Console.
Manages AI Core / KServe model deployments.
"""

from datetime import datetime, timezone
from typing import Any, Dict, List, Optional

from fastapi import APIRouter, HTTPException, status
from pydantic import BaseModel, Field

router = APIRouter()


# ---------------------------------------------------------------------------
# Models
# ---------------------------------------------------------------------------

class Deployment(BaseModel):
    id: str
    status: str = "PENDING"
    target_status: Optional[str] = None
    scenario_id: Optional[str] = None
    creation_time: str = Field(default_factory=lambda: datetime.now(timezone.utc).isoformat())
    details: Dict[str, Any] = Field(default_factory=dict)


class DeploymentCreateRequest(BaseModel):
    scenario_id: str
    configuration: Dict[str, Any] = Field(default_factory=dict)


class DeploymentListResponse(BaseModel):
    resources: List[Deployment]
    count: int


# ---------------------------------------------------------------------------
# In-memory store (replace with AI Core SDK in production)
# ---------------------------------------------------------------------------

_deployments: List[Deployment] = []
_counter = 0


# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------

@router.get("/", response_model=DeploymentListResponse)
async def list_deployments():
    """List all deployments."""
    return DeploymentListResponse(resources=_deployments, count=len(_deployments))


@router.post("/", response_model=Deployment, status_code=status.HTTP_201_CREATED)
async def create_deployment(body: DeploymentCreateRequest):
    """Create a new model deployment."""
    global _counter
    _counter += 1
    deployment = Deployment(
        id=f"d-{_counter:06d}",
        status="PENDING",
        target_status="RUNNING",
        scenario_id=body.scenario_id,
        details=body.configuration,
    )
    _deployments.append(deployment)
    return deployment


@router.get("/{deployment_id}", response_model=Deployment)
async def get_deployment(deployment_id: str):
    """Get details for a specific deployment."""
    for dep in _deployments:
        if dep.id == deployment_id:
            return dep
    raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=f"Deployment '{deployment_id}' not found")


@router.delete("/{deployment_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_deployment(deployment_id: str):
    """Delete (stop) a deployment."""
    global _deployments
    before = len(_deployments)
    _deployments = [d for d in _deployments if d.id != deployment_id]
    if len(_deployments) == before:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=f"Deployment '{deployment_id}' not found")


@router.patch("/{deployment_id}/status")
async def update_deployment_status(deployment_id: str, target_status: str):
    """Update deployment target status (e.g. RUNNING, STOPPED)."""
    for dep in _deployments:
        if dep.id == deployment_id:
            dep.target_status = target_status
            return {"id": dep.id, "target_status": target_status}
    raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=f"Deployment '{deployment_id}' not found")
