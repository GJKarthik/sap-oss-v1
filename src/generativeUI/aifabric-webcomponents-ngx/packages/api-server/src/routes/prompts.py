"""
Shared Prompt Template Library API.

Team-curated prompt templates with categories, usage tracking, and version history.
"""

from __future__ import annotations

import uuid
from datetime import datetime, timezone
from typing import Optional

import structlog
from fastapi import APIRouter, HTTPException
from pydantic import BaseModel, Field

logger = structlog.get_logger()
router = APIRouter()

# ---------------------------------------------------------------------------
# Models
# ---------------------------------------------------------------------------

class PromptTemplate(BaseModel):
    id: str = Field(default_factory=lambda: str(uuid.uuid4()))
    name: str
    content: str
    category: str = "general"
    description: str = ""
    created_by: str = "system"
    created_at: str = Field(default_factory=lambda: datetime.now(timezone.utc).isoformat())
    updated_at: str = Field(default_factory=lambda: datetime.now(timezone.utc).isoformat())
    usage_count: int = 0
    tags: list[str] = Field(default_factory=list)
    version: int = 1
    is_shared: bool = True

class PromptCreate(BaseModel):
    name: str
    content: str
    category: str = "general"
    description: str = ""
    tags: list[str] = Field(default_factory=list)

class PromptUpdate(BaseModel):
    name: Optional[str] = None
    content: Optional[str] = None
    category: Optional[str] = None
    description: Optional[str] = None
    tags: Optional[list[str]] = None

# ---------------------------------------------------------------------------
# In-memory store (production: use the shared HANA/SQLite store)
# ---------------------------------------------------------------------------

_prompts: dict[str, PromptTemplate] = {}

# Seed some defaults
_defaults = [
    PromptTemplate(id="seed-1", name="Data Analysis", content="Analyze the following dataset and provide key insights:\n\n{{data}}\n\nFocus on trends, anomalies, and actionable recommendations.", category="analysis", description="General data analysis prompt", tags=["data", "analysis"], created_by="system"),
    PromptTemplate(id="seed-2", name="Code Review", content="Review the following code for:\n1. Security vulnerabilities\n2. Performance issues\n3. Best practice violations\n\n```{{language}}\n{{code}}\n```", category="development", description="Code review with security focus", tags=["code", "security", "review"], created_by="system"),
    PromptTemplate(id="seed-3", name="SAP Document Summary", content="Summarize the following SAP document in {{language}}:\n\n{{document}}\n\nProvide: Executive summary, key points, and action items.", category="sap", description="SAP document summarization", tags=["sap", "summary", "document"], created_by="system"),
]
for p in _defaults:
    _prompts[p.id] = p

# ---------------------------------------------------------------------------
# Endpoints
# ---------------------------------------------------------------------------

@router.get("")
async def list_prompts(category: str | None = None, tag: str | None = None):
    """List all shared prompt templates, optionally filtered."""
    prompts = list(_prompts.values())
    if category:
        prompts = [p for p in prompts if p.category == category]
    if tag:
        prompts = [p for p in prompts if tag in p.tags]
    prompts.sort(key=lambda p: p.usage_count, reverse=True)
    return {"prompts": [p.model_dump() for p in prompts], "total": len(prompts)}


@router.get("/categories")
async def list_categories():
    """List all unique categories."""
    cats = sorted({p.category for p in _prompts.values()})
    return {"categories": cats}


@router.get("/{prompt_id}")
async def get_prompt(prompt_id: str):
    """Get a specific prompt template."""
    prompt = _prompts.get(prompt_id)
    if not prompt:
        raise HTTPException(status_code=404, detail="Prompt not found")
    return prompt.model_dump()


@router.post("", status_code=201)
async def create_prompt(body: PromptCreate):
    """Create a new shared prompt template."""
    prompt = PromptTemplate(name=body.name, content=body.content, category=body.category, description=body.description, tags=body.tags)
    _prompts[prompt.id] = prompt
    logger.info("prompt.created", id=prompt.id, name=prompt.name)
    return prompt.model_dump()


@router.patch("/{prompt_id}")
async def update_prompt(prompt_id: str, body: PromptUpdate):
    """Update an existing prompt template."""
    prompt = _prompts.get(prompt_id)
    if not prompt:
        raise HTTPException(status_code=404, detail="Prompt not found")
    updates = body.model_dump(exclude_none=True)
    for key, value in updates.items():
        setattr(prompt, key, value)
    prompt.updated_at = datetime.now(timezone.utc).isoformat()
    prompt.version += 1
    return prompt.model_dump()


@router.delete("/{prompt_id}")
async def delete_prompt(prompt_id: str):
    """Delete a prompt template."""
    if prompt_id not in _prompts:
        raise HTTPException(status_code=404, detail="Prompt not found")
    _prompts.pop(prompt_id)
    return {"ok": True, "id": prompt_id}


@router.post("/{prompt_id}/use")
async def record_usage(prompt_id: str):
    """Record a usage of a prompt template (increments counter)."""
    prompt = _prompts.get(prompt_id)
    if not prompt:
        raise HTTPException(status_code=404, detail="Prompt not found")
    prompt.usage_count += 1
    return {"id": prompt_id, "usage_count": prompt.usage_count}
