"""
AI Model management routes for SAP AI Fabric Console.
"""

from typing import List, Optional

from fastapi import APIRouter, HTTPException, status
from pydantic import BaseModel, Field

router = APIRouter()


# ---------------------------------------------------------------------------
# Models
# ---------------------------------------------------------------------------

class AIModel(BaseModel):
    id: str
    name: str
    provider: str = "sap-ai-core"
    version: str = "1.0"
    status: str = "available"
    description: Optional[str] = None
    context_window: int = 4096
    capabilities: List[str] = Field(default_factory=list)


class ModelListResponse(BaseModel):
    models: List[AIModel]
    total: int


# ---------------------------------------------------------------------------
# In-memory store (replace with DB/AI Core SDK in production)
# ---------------------------------------------------------------------------

_models: List[AIModel] = [
    AIModel(
        id="mistral-7b",
        name="Mistral 7B",
        version="0.3",
        description="Open-weight 7B parameter model",
        context_window=8192,
        capabilities=["chat", "completion"],
    ),
    AIModel(
        id="gpt-4o",
        name="GPT-4o",
        provider="azure-openai",
        description="Azure OpenAI GPT-4o deployment",
        context_window=128000,
        capabilities=["chat", "completion", "vision"],
    ),
]


# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------

@router.get("/", response_model=ModelListResponse)
async def list_models():
    """List all available AI models."""
    return ModelListResponse(models=_models, total=len(_models))


@router.get("/{model_id}", response_model=AIModel)
async def get_model(model_id: str):
    """Get details for a specific model."""
    for model in _models:
        if model.id == model_id:
            return model
    raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=f"Model '{model_id}' not found")
