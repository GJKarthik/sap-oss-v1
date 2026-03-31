"""
Generative UI session persistence routes.
Stores saved UI/chat sessions with bookmarking and history for recreation.
"""

from datetime import datetime, timezone
from typing import Any, List, Literal, Optional
from uuid import uuid4

from fastapi import APIRouter, Depends, HTTPException, Response, status
from pydantic import BaseModel, Field

from ..routes.auth import UserInfo, get_current_user
from ..store import StoreBackend, get_store

router = APIRouter()


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


class SessionMessage(BaseModel):
    role: Literal["user", "assistant", "system"]
    content: str
    timestamp: Optional[str] = None


class SessionSaveRequest(BaseModel):
    session_id: Optional[str] = None
    title: Optional[str] = None
    messages: List[SessionMessage] = Field(default_factory=list)
    ui_state: dict[str, Any] = Field(default_factory=dict)


class SessionBookmarkRequest(BaseModel):
    is_bookmarked: bool


class SessionArchiveRequest(BaseModel):
    is_archived: bool


class GenUiSessionOut(BaseModel):
    id: str
    title: str
    owner_username: str
    is_bookmarked: bool
    messages: List[SessionMessage]
    ui_state: dict[str, Any]
    created_at: str
    updated_at: str
    last_message_at: Optional[str] = None
    is_archived: bool = False
    archived_at: Optional[str] = None


class GenUiSessionListOut(BaseModel):
    sessions: List[GenUiSessionOut]
    total: int


def _to_session_out(record: dict[str, Any]) -> GenUiSessionOut:
    return GenUiSessionOut(
        id=str(record["id"]),
        title=str(record.get("title") or "Untitled session"),
        owner_username=str(record.get("owner_username") or ""),
        is_bookmarked=bool(record.get("is_bookmarked", False)),
        messages=[SessionMessage(**m) for m in (record.get("messages") or []) if isinstance(m, dict)],
        ui_state=record.get("ui_state") if isinstance(record.get("ui_state"), dict) else {},
        created_at=str(record.get("created_at") or ""),
        updated_at=str(record.get("updated_at") or ""),
        last_message_at=str(record.get("last_message_at")) if record.get("last_message_at") else None,
        is_archived=bool(record.get("is_archived", False)),
        archived_at=str(record.get("archived_at")) if record.get("archived_at") else None,
    )


def _ensure_owner_or_404(record: Optional[dict[str, Any]], current_user: UserInfo, session_id: str) -> dict[str, Any]:
    if record is None or record.get("owner_username") != current_user.username:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"Session '{session_id}' not found",
        )
    return record


@router.get("/sessions", response_model=GenUiSessionListOut)
async def list_sessions(
    bookmarked_only: bool = False,
    include_archived: bool = False,
    archived_only: bool = False,
    query: str = "",
    limit: int = 50,
    store: StoreBackend = Depends(get_store),
    current_user: UserInfo = Depends(get_current_user),
):
    safe_limit = max(1, min(int(limit), 200))
    rows = [
        row for row in store.list_records("genui_sessions")
        if row.get("owner_username") == current_user.username
    ]
    if archived_only:
        rows = [row for row in rows if bool(row.get("is_archived", False))]
    elif not include_archived:
        rows = [row for row in rows if not bool(row.get("is_archived", False))]
    if bookmarked_only:
        rows = [row for row in rows if bool(row.get("is_bookmarked", False))]
    q = query.strip().lower()
    if q:
        def _matches(row: dict[str, Any]) -> bool:
            if q in str(row.get("title", "")).lower():
                return True
            for message in row.get("messages") or []:
                if isinstance(message, dict) and q in str(message.get("content", "")).lower():
                    return True
            return False
        rows = [row for row in rows if _matches(row)]
    rows.sort(key=lambda item: str(item.get("updated_at") or ""), reverse=True)
    sessions = [_to_session_out(row) for row in rows[:safe_limit]]
    return GenUiSessionListOut(sessions=sessions, total=len(rows))


@router.get("/sessions/{session_id}", response_model=GenUiSessionOut)
async def get_session(
    session_id: str,
    store: StoreBackend = Depends(get_store),
    current_user: UserInfo = Depends(get_current_user),
):
    row = _ensure_owner_or_404(store.get_record("genui_sessions", session_id), current_user, session_id)
    return _to_session_out(row)


@router.post("/sessions/save", response_model=GenUiSessionOut)
async def save_session(
    body: SessionSaveRequest,
    response: Response,
    store: StoreBackend = Depends(get_store),
    current_user: UserInfo = Depends(get_current_user),
):
    now = _now_iso()
    title = (body.title or "").strip() or "Untitled session"
    messages = [
        {
            "role": msg.role,
            "content": msg.content,
            "timestamp": msg.timestamp or now,
        }
        for msg in body.messages
    ]
    last_message_at = messages[-1]["timestamp"] if messages else None

    if body.session_id:
        existing = _ensure_owner_or_404(
            store.get_record("genui_sessions", body.session_id),
            current_user,
            body.session_id,
        )
        updated = {
            **existing,
            "title": title,
            "messages": messages,
            "ui_state": body.ui_state,
            "updated_at": now,
            "last_message_at": last_message_at,
        }
        record = store.set_record("genui_sessions", body.session_id, updated)
        response.status_code = status.HTTP_200_OK
        return _to_session_out(record)

    session_id = str(uuid4())
    record = {
        "id": session_id,
        "title": title,
        "owner_username": current_user.username,
        "is_bookmarked": False,
        "messages": messages,
        "ui_state": body.ui_state,
        "created_at": now,
        "updated_at": now,
        "last_message_at": last_message_at,
        "is_archived": False,
        "archived_at": None,
    }
    created = store.set_record("genui_sessions", session_id, record)
    response.status_code = status.HTTP_201_CREATED
    return _to_session_out(created)


@router.patch("/sessions/{session_id}/bookmark", response_model=GenUiSessionOut)
async def set_bookmark(
    session_id: str,
    body: SessionBookmarkRequest,
    store: StoreBackend = Depends(get_store),
    current_user: UserInfo = Depends(get_current_user),
):
    existing = _ensure_owner_or_404(store.get_record("genui_sessions", session_id), current_user, session_id)
    updated = store.set_record(
        "genui_sessions",
        session_id,
        {
            **existing,
            "is_bookmarked": body.is_bookmarked,
            "updated_at": _now_iso(),
        },
    )
    return _to_session_out(updated)


@router.patch("/sessions/{session_id}/archive", response_model=GenUiSessionOut)
async def set_archive(
    session_id: str,
    body: SessionArchiveRequest,
    store: StoreBackend = Depends(get_store),
    current_user: UserInfo = Depends(get_current_user),
):
    existing = _ensure_owner_or_404(store.get_record("genui_sessions", session_id), current_user, session_id)
    now = _now_iso()
    updated = store.set_record(
        "genui_sessions",
        session_id,
        {
            **existing,
            "is_archived": body.is_archived,
            "archived_at": now if body.is_archived else None,
            "updated_at": now,
        },
    )
    return _to_session_out(updated)


@router.delete("/sessions/{session_id}", status_code=status.HTTP_204_NO_CONTENT)
async def archive_session(
    session_id: str,
    store: StoreBackend = Depends(get_store),
    current_user: UserInfo = Depends(get_current_user),
):
    existing = _ensure_owner_or_404(store.get_record("genui_sessions", session_id), current_user, session_id)
    now = _now_iso()
    store.set_record(
        "genui_sessions",
        session_id,
        {
            **existing,
            "is_archived": True,
            "archived_at": now,
            "updated_at": now,
        },
    )
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@router.post("/sessions/{session_id}/clone", response_model=GenUiSessionOut, status_code=status.HTTP_201_CREATED)
async def clone_session(
    session_id: str,
    store: StoreBackend = Depends(get_store),
    current_user: UserInfo = Depends(get_current_user),
):
    existing = _ensure_owner_or_404(store.get_record("genui_sessions", session_id), current_user, session_id)
    now = _now_iso()
    clone_id = str(uuid4())
    clone_record = {
        **existing,
        "id": clone_id,
        "title": f"{str(existing.get('title') or 'Untitled session')} (copy)",
        "owner_username": current_user.username,
        "is_bookmarked": False,
        "is_archived": False,
        "archived_at": None,
        "created_at": now,
        "updated_at": now,
    }
    created = store.set_record("genui_sessions", clone_id, clone_record)
    return _to_session_out(created)

