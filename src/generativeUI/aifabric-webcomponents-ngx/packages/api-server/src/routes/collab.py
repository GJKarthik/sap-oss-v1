"""
Collaboration WebSocket endpoint for AI Fabric Console.

Room-based real-time presence and state synchronisation.
Manages participant join/leave, presence heartbeats, and message fan-out.
"""

from __future__ import annotations

import json
import asyncio
from collections import defaultdict
from datetime import datetime, timezone
from typing import Any

import structlog
from fastapi import APIRouter, WebSocket, WebSocketDisconnect, Query

logger = structlog.get_logger()

router = APIRouter(tags=["collaboration"])

# ---------------------------------------------------------------------------
# In-memory room state (production would use Redis pub/sub)
# ---------------------------------------------------------------------------

RoomId = str
UserId = str


class Participant:
    __slots__ = ("user_id", "display_name", "avatar_url", "status", "location", "ws", "joined_at", "last_seen")

    def __init__(self, user_id: str, display_name: str, ws: WebSocket, avatar_url: str | None = None):
        self.user_id = user_id
        self.display_name = display_name
        self.avatar_url = avatar_url
        self.ws = ws
        self.status = "active"
        self.location: str | None = None
        self.joined_at = datetime.now(timezone.utc).isoformat()
        self.last_seen = self.joined_at

    def to_dict(self) -> dict[str, Any]:
        return {
            "userId": self.user_id,
            "displayName": self.display_name,
            "avatarUrl": self.avatar_url,
            "status": self.status,
            "location": self.location,
            "joinedAt": self.joined_at,
            "lastSeenAt": self.last_seen,
            "color": "",
        }


_rooms: dict[RoomId, dict[UserId, Participant]] = defaultdict(dict)
_lock = asyncio.Lock()


async def _broadcast(room_id: RoomId, message: dict[str, Any], exclude: UserId | None = None) -> None:
    """Fan-out a JSON message to every participant in the room except *exclude*."""
    room = _rooms.get(room_id)
    if not room:
        return
    payload = json.dumps(message)
    stale: list[UserId] = []
    for uid, participant in room.items():
        if uid == exclude:
            continue
        try:
            await participant.ws.send_text(payload)
        except Exception:
            stale.append(uid)
    for uid in stale:
        room.pop(uid, None)


async def _send_sync(participant: Participant, room_id: RoomId) -> None:
    """Send a full room sync to a newly joined participant."""
    room = _rooms.get(room_id, {})
    participants = [p.to_dict() for p in room.values()]
    await participant.ws.send_text(json.dumps({"type": "sync", "participants": participants, "state": {}}))


# ---------------------------------------------------------------------------
# WebSocket endpoint
# ---------------------------------------------------------------------------

@router.websocket("/collab")
async def collab_websocket(ws: WebSocket, room: str = Query("default")):
    """
    Room-based collaboration WebSocket.

    Query params:
        room — room identifier (default: "default")

    Protocol messages (JSON):
        join:     { type: "join", roomId, userId, displayName, avatarUrl? }
        leave:    { type: "leave", roomId, userId }
        presence: { type: "presence", userId, status, location? }
        state:    { type: "state", ... }  — forwarded as-is to peers
    """
    await ws.accept()
    user_id: str | None = None
    room_id = room

    try:
        while True:
            raw = await ws.receive_text()
            try:
                msg = json.loads(raw)
            except json.JSONDecodeError:
                continue

            msg_type = msg.get("type")

            if msg_type == "join":
                user_id = msg.get("userId", "anonymous")
                display_name = msg.get("displayName", user_id)
                avatar_url = msg.get("avatarUrl")
                room_id = msg.get("roomId", room)
                p = Participant(user_id, display_name, ws, avatar_url)
                async with _lock:
                    _rooms[room_id][user_id] = p
                logger.info("collab.join", room=room_id, user=user_id)
                await _broadcast(room_id, msg, exclude=user_id)
                await _send_sync(p, room_id)

            elif msg_type == "leave":
                uid = msg.get("userId", user_id)
                async with _lock:
                    _rooms.get(room_id, {}).pop(uid or "", None)
                logger.info("collab.leave", room=room_id, user=uid)
                await _broadcast(room_id, msg)

            elif msg_type == "presence":
                uid = msg.get("userId", user_id)
                async with _lock:
                    p = _rooms.get(room_id, {}).get(uid or "")
                    if p:
                        p.status = msg.get("status", "active")
                        p.location = msg.get("location")
                        p.last_seen = datetime.now(timezone.utc).isoformat()
                await _broadcast(room_id, msg, exclude=uid)

            elif msg_type == "state":
                await _broadcast(room_id, msg, exclude=msg.get("userId", user_id))

            else:
                await _broadcast(room_id, msg, exclude=user_id)

    except WebSocketDisconnect:
        pass
    except Exception as exc:
        logger.warning("collab.error", room=room_id, user=user_id, error=str(exc))
    finally:
        if user_id:
            async with _lock:
                _rooms.get(room_id, {}).pop(user_id, None)
            await _broadcast(room_id, {"type": "leave", "roomId": room_id, "userId": user_id})
            logger.info("collab.disconnect", room=room_id, user=user_id)
