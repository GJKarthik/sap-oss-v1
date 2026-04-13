"""
Notification REST endpoints — CRUD backed by the unified Store (HANA / SQLite).
"""

from __future__ import annotations

from typing import Any, Dict, List

from fastapi import APIRouter, Request
from pydantic import BaseModel, Field

from .identity import resolve_request_identity
from .store import get_store

router = APIRouter()


class NotificationCreateBody(BaseModel):
    title: str
    description: str = ""
    icon: str = "message-information"
    severity: str = "info"
    user_id: str | None = Field(
        default=None,
        description="Target user; defaults to the authenticated caller.",
    )


class NotificationOut(BaseModel):
    id: str
    user_id: str
    icon: str
    title: str
    description: str
    severity: str
    read: bool
    created_at: str | None


class NotificationListResponse(BaseModel):
    notifications: List[NotificationOut]
    unread_count: int


@router.get("", response_model=NotificationListResponse)
async def list_notifications(request: Request, limit: int = 50):
    identity = resolve_request_identity(request)
    store = get_store()
    items = store.list_notifications(identity.user_id, limit=limit)
    unread = store.unread_count(identity.user_id)
    return NotificationListResponse(
        notifications=[NotificationOut(**n) for n in items],
        unread_count=unread,
    )


@router.post("", response_model=NotificationOut, status_code=201)
async def create_notification(request: Request, body: NotificationCreateBody):
    identity = resolve_request_identity(request)
    store = get_store()
    data = body.model_dump()
    data["user_id"] = data["user_id"] or identity.user_id
    result = store.create_notification(data)
    return NotificationOut(**result)


@router.put("/{notification_id}/read")
async def mark_read(request: Request, notification_id: str):
    identity = resolve_request_identity(request)
    store = get_store()
    ok = store.mark_notification_read(notification_id, identity.user_id)
    return {"ok": ok}


@router.put("/read-all")
async def mark_all_read(request: Request):
    identity = resolve_request_identity(request)
    store = get_store()
    count = store.mark_all_read(identity.user_id)
    return {"marked": count}
