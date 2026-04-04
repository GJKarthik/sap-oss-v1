"""FastAPI + WebSocket server for the Coloured Petri Net engine.

Exposes CPN creation, execution, real-time streaming, and workflow templates.

Start standalone:
    uvicorn intelligence.petri_net.server:app --port 8002 --reload
"""

from __future__ import annotations

import asyncio
import copy
import time
import uuid
from datetime import datetime, timezone
from enum import Enum
from typing import Any, Dict, List, Optional

from fastapi import FastAPI, HTTPException, WebSocket, WebSocketDisconnect
from fastapi.routing import APIRouter
from pydantic import BaseModel, Field

from .core import PetriNet, Place, TokenColour, Transition
from .engine import CPNEngine
from .persistence import _serialize_marking, _serialize_net_structure
from .templates import model_deploy_net, ocr_batch_net, training_pipeline_net

# ---------------------------------------------------------------------------
# Pydantic models
# ---------------------------------------------------------------------------


class NetStatus(str, Enum):
    idle = "idle"
    running = "running"
    paused = "paused"
    completed = "completed"
    deadlocked = "deadlocked"


class CreateNetRequest(BaseModel):
    template: Optional[str] = Field(None, description="Template name")
    definition: Optional[Dict[str, Any]] = Field(None, description="Custom net JSON")
    name: Optional[str] = None


class FireRequest(BaseModel):
    transition: str = Field(..., description="Transition name")
    binding: Optional[Dict[str, Any]] = Field(default_factory=dict)


class RunRequest(BaseModel):
    max_steps: Optional[int] = Field(100, ge=1)


class NetInfo(BaseModel):
    net_id: str
    name: str
    status: str
    step_count: int
    created_at: str


# ---------------------------------------------------------------------------
# In-memory store
# ---------------------------------------------------------------------------

TEMPLATES = {
    "training_pipeline": training_pipeline_net,
    "ocr_batch": ocr_batch_net,
    "model_deploy": model_deploy_net,
}


class _NetInstance:
    """Wrapper holding engine + metadata for one CPN instance."""

    def __init__(self, engine: CPNEngine, name: str):
        self.id = str(uuid.uuid4())
        self.engine = engine
        self.name = name
        self.status: NetStatus = NetStatus.idle
        self.created_at = datetime.now(timezone.utc).isoformat()
        self.history: List[Dict[str, Any]] = []
        self.subscribers: List[WebSocket] = []
        self._run_task: Optional[asyncio.Task] = None
        self._pause_event = asyncio.Event()
        self._pause_event.set()  # not paused initially
        self._lock = asyncio.Lock()

    async def broadcast(self, message: Dict[str, Any]) -> None:
        dead: List[WebSocket] = []
        for ws in self.subscribers:
            try:
                await ws.send_json(message)
            except Exception:
                dead.append(ws)
        for ws in dead:
            self.subscribers.remove(ws)


_instances: Dict[str, _NetInstance] = {}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

router = APIRouter(prefix="/api/cpn", tags=["cpn"])


def _get_instance(net_id: str) -> _NetInstance:
    inst = _instances.get(net_id)
    if inst is None:
        raise HTTPException(status_code=404, detail=f"Net '{net_id}' not found")
    return inst


def _build_net_from_definition(defn: Dict[str, Any]) -> PetriNet:
    """Build a PetriNet from a simple JSON definition."""
    from .persistence import _rebuild_net_from_json
    return _rebuild_net_from_json(defn)


def _marking_summary(engine: CPNEngine) -> Dict[str, Any]:
    return _serialize_marking(engine.net)


def _enabled_names(engine: CPNEngine) -> List[str]:
    return list({t.name for t, _ in engine.enabled_transitions()})


def _compute_status(inst: _NetInstance) -> NetStatus:
    if inst._run_task and not inst._run_task.done():
        if not inst._pause_event.is_set():
            return NetStatus.paused
        return NetStatus.running
    engine = inst.engine
    if engine.enabled_transitions():
        return inst.status if inst.status in (NetStatus.idle, NetStatus.paused) else NetStatus.idle
    if engine.is_deadlocked():
        return NetStatus.deadlocked
    return NetStatus.completed


# ---------------------------------------------------------------------------
# REST endpoints
# ---------------------------------------------------------------------------


@router.get("/templates")
async def list_templates():
    """List available workflow templates."""
    return {
        "templates": [
            {"name": name, "description": fn.__doc__ or ""}
            for name, fn in TEMPLATES.items()
        ]
    }


@router.post("/nets")
async def create_net(req: CreateNetRequest):
    """Create a new CPN instance from a template or custom definition."""
    if req.template:
        factory = TEMPLATES.get(req.template)
        if factory is None:
            raise HTTPException(
                status_code=400,
                detail=f"Unknown template '{req.template}'. "
                       f"Available: {list(TEMPLATES.keys())}",
            )
        net = factory()
    elif req.definition:
        try:
            net = _build_net_from_definition(req.definition)
        except Exception as e:
            raise HTTPException(status_code=400, detail=f"Invalid definition: {e}")
    else:
        raise HTTPException(
            status_code=400,
            detail="Provide either 'template' or 'definition'",
        )

    if req.name:
        net.name = req.name

    engine = CPNEngine(net)
    inst = _NetInstance(engine, net.name)
    _instances[inst.id] = inst
    return {
        "net_id": inst.id,
        "name": inst.name,
        "status": _compute_status(inst).value,
        "step_count": 0,
    }


@router.get("/nets")
async def list_nets():
    """List active CPN instances."""
    return {
        "nets": [
            {
                "net_id": inst.id,
                "name": inst.name,
                "status": _compute_status(inst).value,
                "step_count": inst.engine.step_count,
                "created_at": inst.created_at,
            }
            for inst in _instances.values()
        ]
    }


@router.get("/nets/{net_id}")
async def get_net(net_id: str):
    """Get CPN state: marking, enabled transitions, metadata."""
    inst = _get_instance(net_id)
    status = _compute_status(inst)
    inst.status = status
    return {
        "net_id": inst.id,
        "name": inst.name,
        "status": status.value,
        "step_count": inst.engine.step_count,
        "created_at": inst.created_at,
        "marking": _marking_summary(inst.engine),
        "enabled_transitions": _enabled_names(inst.engine),
        "structure": _serialize_net_structure(inst.engine.net),
    }


@router.delete("/nets/{net_id}")
async def delete_net(net_id: str):
    """Destroy a CPN instance."""
    inst = _get_instance(net_id)
    if inst._run_task and not inst._run_task.done():
        inst._run_task.cancel()
    del _instances[net_id]
    return {"deleted": True, "net_id": net_id}


@router.post("/nets/{net_id}/fire")
async def fire_transition(net_id: str, req: FireRequest):
    """Fire a specific transition with optional binding."""
    inst = _get_instance(net_id)
    async with inst._lock:
        try:
            t = inst.engine.net.transition_by_name(req.transition)
        except KeyError:
            raise HTTPException(
                status_code=404,
                detail=f"Transition '{req.transition}' not found",
            )

        bindings = inst.engine._find_bindings(t)
        if not bindings:
            raise HTTPException(
                status_code=409,
                detail=f"Transition '{req.transition}' is not enabled",
            )

        binding = bindings[0]
        try:
            result = inst.engine.fire(t, binding)
        except Exception as e:
            error_msg = {
                "type": "error",
                "transition": req.transition,
                "message": str(e),
                "timestamp": datetime.now(timezone.utc).isoformat(),
            }
            await inst.broadcast(error_msg)
            raise HTTPException(status_code=409, detail=str(e))

        ts = datetime.now(timezone.utc).isoformat()
        event = {
            "type": "fire",
            "transition": req.transition,
            "binding": {k: repr(v) for k, v in binding.items()},
            "marking": _marking_summary(inst.engine),
            "timestamp": ts,
        }
        inst.history.append(event)
        await inst.broadcast(event)

        new_status = _compute_status(inst)
        if new_status != inst.status:
            inst.status = new_status
            await inst.broadcast({
                "type": "state",
                "status": new_status.value,
                "timestamp": ts,
            })

        return {
            "fired": req.transition,
            "marking": _marking_summary(inst.engine),
            "status": new_status.value,
            "step_count": inst.engine.step_count,
        }


@router.post("/nets/{net_id}/step")
async def step_net(net_id: str):
    """Fire one enabled transition (highest priority, random among equal)."""
    inst = _get_instance(net_id)
    async with inst._lock:
        result = inst.engine.step()
        if result is None:
            raise HTTPException(status_code=409, detail="No enabled transitions")

        t_name, binding = result
        ts = datetime.now(timezone.utc).isoformat()
        event = {
            "type": "fire",
            "transition": t_name,
            "binding": {k: repr(v) for k, v in binding.items()},
            "marking": _marking_summary(inst.engine),
            "timestamp": ts,
        }
        inst.history.append(event)
        await inst.broadcast(event)

        new_status = _compute_status(inst)
        if new_status != inst.status:
            inst.status = new_status
            await inst.broadcast({
                "type": "state",
                "status": new_status.value,
                "timestamp": ts,
            })

        return {
            "fired": t_name,
            "marking": _marking_summary(inst.engine),
            "status": new_status.value,
            "step_count": inst.engine.step_count,
        }


@router.post("/nets/{net_id}/run")
async def run_net(net_id: str, req: RunRequest = RunRequest()):
    """Auto-run until completion or max steps. Runs in background."""
    inst = _get_instance(net_id)
    if inst._run_task and not inst._run_task.done():
        raise HTTPException(status_code=409, detail="Already running")

    async def _run_loop():
        steps = 0
        max_steps = req.max_steps or 100
        inst.status = NetStatus.running
        await inst.broadcast({
            "type": "state",
            "status": "running",
            "timestamp": datetime.now(timezone.utc).isoformat(),
        })
        try:
            while steps < max_steps:
                await inst._pause_event.wait()
                async with inst._lock:
                    result = inst.engine.step()
                    if result is None:
                        break
                    t_name, binding = result
                    steps += 1
                    ts = datetime.now(timezone.utc).isoformat()
                    event = {
                        "type": "fire",
                        "transition": t_name,
                        "binding": {k: repr(v) for k, v in binding.items()},
                        "marking": _marking_summary(inst.engine),
                        "timestamp": ts,
                    }
                    inst.history.append(event)
                    await inst.broadcast(event)
                await asyncio.sleep(0)  # yield
        finally:
            final_status = _compute_status(inst)
            inst.status = final_status
            await inst.broadcast({
                "type": "state",
                "status": final_status.value,
                "timestamp": datetime.now(timezone.utc).isoformat(),
            })

    inst._run_task = asyncio.create_task(_run_loop())
    return {
        "status": "running",
        "max_steps": req.max_steps,
        "net_id": net_id,
    }


@router.post("/nets/{net_id}/pause")
async def pause_net(net_id: str):
    """Pause auto-run."""
    inst = _get_instance(net_id)
    if not inst._run_task or inst._run_task.done():
        raise HTTPException(status_code=409, detail="Not currently running")
    inst._pause_event.clear()
    inst.status = NetStatus.paused
    await inst.broadcast({
        "type": "state",
        "status": "paused",
        "timestamp": datetime.now(timezone.utc).isoformat(),
    })
    return {"status": "paused", "net_id": net_id}


@router.post("/nets/{net_id}/reset")
async def reset_net(net_id: str):
    """Reset the net to its initial state by re-creating from template."""
    inst = _get_instance(net_id)
    if inst._run_task and not inst._run_task.done():
        inst._run_task.cancel()
        try:
            await inst._run_task
        except asyncio.CancelledError:
            pass

    # Look up original template
    factory = TEMPLATES.get(inst.name)
    if factory:
        net = factory()
    else:
        # Re-create from current structure (loses initial tokens for custom nets)
        net = copy.deepcopy(inst.engine.net)
        for p in net.places.values():
            p._tokens.clear()

    inst.engine = CPNEngine(net)
    inst.status = NetStatus.idle
    inst.history.clear()
    inst._run_task = None
    inst._pause_event.set()

    ts = datetime.now(timezone.utc).isoformat()
    await inst.broadcast({
        "type": "state",
        "status": "idle",
        "timestamp": ts,
    })
    return {
        "status": "idle",
        "net_id": net_id,
        "marking": _marking_summary(inst.engine),
    }


@router.get("/nets/{net_id}/history")
async def get_history(net_id: str):
    """Get firing history with timestamps."""
    inst = _get_instance(net_id)
    return {"net_id": net_id, "history": inst.history}


# ---------------------------------------------------------------------------
# WebSocket
# ---------------------------------------------------------------------------


@router.websocket("/nets/{net_id}/stream")
async def websocket_stream(websocket: WebSocket, net_id: str):
    """Real-time state updates via WebSocket."""
    inst = _instances.get(net_id)
    if inst is None:
        await websocket.close(code=4004, reason=f"Net '{net_id}' not found")
        return

    await websocket.accept()
    inst.subscribers.append(websocket)

    # Send initial state
    try:
        await websocket.send_json({
            "type": "state",
            "status": _compute_status(inst).value,
            "marking": _marking_summary(inst.engine),
            "timestamp": datetime.now(timezone.utc).isoformat(),
        })
    except Exception:
        inst.subscribers.remove(websocket)
        return

    try:
        while True:
            # Keep connection alive; client can send pings or commands
            data = await websocket.receive_text()
            # Optional: handle client commands like {"action": "step"}
    except WebSocketDisconnect:
        pass
    finally:
        if websocket in inst.subscribers:
            inst.subscribers.remove(websocket)


# ---------------------------------------------------------------------------
# App
# ---------------------------------------------------------------------------

app = FastAPI(title="CPN Engine Server", version="1.0.0")
app.include_router(router)


@app.get("/health")
async def health():
    return {"status": "ok", "active_nets": len(_instances)}
