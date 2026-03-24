"""
AI Model management routes for SAP AI Fabric Console.
State persisted via the configured shared store backend.
"""

from dataclasses import asdict
from typing import List, Optional

from fastapi import APIRouter, Depends, HTTPException, status
from pydantic import BaseModel, Field

from ..models import AIModel as AIModelDC
from ..routes.auth import UserInfo, get_current_user, require_admin
from ..store import StoreBackend, get_store

router = APIRouter()


# ---------------------------------------------------------------------------
# Pydantic schemas
# ---------------------------------------------------------------------------

class AIModelOut(BaseModel):
    id: str
    name: str
    provider: str
    version: str
    status: str
    description: Optional[str]
    context_window: int
    capabilities: List[str]


class AIModelCreateRequest(BaseModel):
    id: str
    name: str
    provider: str = "sap-ai-core"
    version: str = "1.0"
    description: Optional[str] = None
    context_window: int = 4096
    capabilities: List[str] = Field(default_factory=list)


class ModelListResponse(BaseModel):
    models: List[AIModelOut]
    total: int


def _dict_to_out(d: dict) -> AIModelOut:
    return AIModelOut(
        id=d["id"],
        name=d["name"],
        provider=d.get("provider", "sap-ai-core"),
        version=d.get("version", "1.0"),
        status=d.get("status", "available"),
        description=d.get("description"),
        context_window=d.get("context_window", 4096),
        capabilities=d.get("capabilities") or [],
    )


# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------

@router.get("", response_model=ModelListResponse)
async def list_models(
    store: StoreBackend = Depends(get_store),
    _: UserInfo = Depends(get_current_user),
):
    """List all available AI models from the persistent store."""
    rows = sorted(store.list_records("models"), key=lambda m: m["name"])
    return ModelListResponse(models=[_dict_to_out(r) for r in rows], total=len(rows))


@router.get("/{model_id}", response_model=AIModelOut)
async def get_model(
    model_id: str,
    store: StoreBackend = Depends(get_store),
    _: UserInfo = Depends(get_current_user),
):
    """Get details for a specific model."""
    row = store.get_record("models", model_id)
    if row is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=f"Model '{model_id}' not found")
    return _dict_to_out(row)


@router.post("", response_model=AIModelOut, status_code=status.HTTP_201_CREATED)
async def register_model(
    body: AIModelCreateRequest,
    store: StoreBackend = Depends(get_store),
    _: UserInfo = Depends(require_admin),
):
    """Register a new AI model in the catalogue."""
    if store.has_record("models", body.id):
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail=f"Model '{body.id}' already exists")
    model = AIModelDC(
        id=body.id,
        name=body.name,
        provider=body.provider,
        version=body.version,
        description=body.description,
        context_window=body.context_window,
        capabilities=body.capabilities,
    )
    created = store.set_record("models", body.id, asdict(model))
    return _dict_to_out(created)


@router.delete("/{model_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_model(
    model_id: str,
    store: StoreBackend = Depends(get_store),
    _: UserInfo = Depends(require_admin),
):
    """Remove a model from the catalogue."""
    if not store.delete_record("models", model_id):
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=f"Model '{model_id}' not found")
