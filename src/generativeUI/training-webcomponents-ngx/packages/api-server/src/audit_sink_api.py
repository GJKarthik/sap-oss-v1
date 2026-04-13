"""
Batch sink for GenUI governance audit entries (AuditService.flushBatch).

When ``AUDIT_SINK_TOKEN`` is set, requests must send matching ``X-Internal-Token``.
"""

from __future__ import annotations

import os
from typing import Any, Dict, List

from fastapi import APIRouter, Header, HTTPException, Request, status
from pydantic import BaseModel, Field

from .store import get_store

router = APIRouter()

AUDIT_SINK_TOKEN = os.getenv("AUDIT_SINK_TOKEN", "").strip()
MAX_BATCH = 100


class AuditBatchBody(BaseModel):
    entries: List[Dict[str, Any]] = Field(default_factory=list)


def _verify_sink_token(request: Request, x_internal_token: str | None) -> None:
    if not AUDIT_SINK_TOKEN:
        return
    sent = (x_internal_token or "").strip()
    if sent != AUDIT_SINK_TOKEN:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid or missing X-Internal-Token for audit sink.",
        )


@router.get("/batch")
async def get_audit_batch(
    request: Request,
    x_internal_token: str | None = Header(default=None, alias="X-Internal-Token"),
) -> Dict[str, Any]:
    """
    Compatibility GET for AuditService.refreshFromEndpoint (same base URL as POST).
    Returns an empty log list until a query API is implemented.
    """
    _verify_sink_token(request, x_internal_token)
    return {"logs": []}


@router.post("/batch")
async def post_audit_batch(
    request: Request,
    body: AuditBatchBody,
    x_internal_token: str | None = Header(default=None, alias="X-Internal-Token"),
) -> Dict[str, Any]:
    _verify_sink_token(request, x_internal_token)
    entries = body.entries
    if len(entries) > MAX_BATCH:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"At most {MAX_BATCH} entries per batch.",
        )
    if not entries:
        return {"inserted": 0}

    store = get_store()
    inserted = store.insert_audit_batch(entries)
    return {"inserted": inserted}
