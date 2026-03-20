#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2024 SAP SE
"""FastAPI server exposing the Data Cleaning Copilot as REST endpoints."""

import asyncio
import argparse
import json
import os
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, AsyncIterator, Dict, List, Optional
from uuid import uuid4

from loguru import logger
from dotenv import load_dotenv
from fastapi import FastAPI, HTTPException, Query
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import StreamingResponse
from pydantic import BaseModel, Field

# Add parent directory to path
sys.path.insert(0, str(Path(__file__).parent.parent))

app = FastAPI(title="Data Cleaning Copilot API", version="1.0.0")

# CORS: use CORS_ALLOWED_ORIGINS (comma-separated). Do not use allow_credentials with "*".
_cors_origins_raw = os.getenv("CORS_ALLOWED_ORIGINS", "http://localhost:3000,http://127.0.0.1:3000").strip()
_cors_origins = [o.strip() for o in _cors_origins_raw.split(",") if o.strip()]
_allow_wildcard = "*" in _cors_origins
_origins_list = [o for o in _cors_origins if o != "*"] if _allow_wildcard else _cors_origins
app.add_middleware(
    CORSMiddleware,
    allow_origins=_origins_list if _origins_list else (["*"] if _allow_wildcard else []),
    allow_credentials=not _allow_wildcard and bool(_origins_list),
    allow_methods=["*"],
    allow_headers=["*"],
)

# Globals – initialised on startup
_interactive_session = None
_session_manager = None
_session_id: str = ""
_session_model: str = "claude-4"
_agent_model: str = "claude-4"
_pending_workflow_reviews: Dict[str, Dict[str, Any]] = {}
_workflow_audit_log: List[Dict[str, Any]] = []
_workflow_audit_counter = 0
_workflow_audit_limit = 250
_latest_workflow_run: Optional[Dict[str, Any]] = None
_latest_pending_review: Optional[Dict[str, Any]] = None


def _aicore_config_ready() -> bool:
    required = ["AICORE_BASE_URL", "AICORE_AUTH_URL", "AICORE_CLIENT_ID", "AICORE_CLIENT_SECRET"]
    return all((os.getenv(key) or "").strip() for key in required)


def _serialize_generated_checks() -> Dict[str, Dict[str, Any]]:
    if _interactive_session is None:
        return {}

    result: Dict[str, Dict[str, Any]] = {}
    for name, check in _interactive_session.database.generated_checks.items():
        display_name = name[4:] if name.startswith("llm_") else name
        result[display_name] = {
            "description": check.description,
            "scope": check.scope,
            "code": check.to_code(),
        }
    return result


def _build_session_config_payload() -> Dict[str, Any]:
    if _interactive_session is None:
        return {
            "main": {"error": "Session not initialised."},
            "check_gen": {"error": "Session not initialised."},
            "session_model": _session_model,
            "agent_model": _agent_model,
        }

    return {
        "main": _interactive_session._get_session_config(_session_id),
        "check_gen": _interactive_session._get_session_config(
            _interactive_session.database.check_generator_session_id
        ),
        "session_model": _session_model,
        "agent_model": _agent_model,
    }


def _infer_request_kind(message: str, new_check_names: List[str]) -> str:
    normalized = message.lower()
    if new_check_names:
        return "check_generation"
    if any(keyword in normalized for keyword in ("schema", "column", "table", "fields")):
        return "schema_review"
    if any(keyword in normalized for keyword in ("validate", "run checks", "violations", "quality")):
        return "validation_review"
    if any(keyword in normalized for keyword in ("history", "session", "config")):
        return "session_review"
    return "analysis"


def _build_workflow_snapshot(
    *,
    run_id: str,
    user_message: str,
    assistant_response: str,
    started_at: str,
    finished_at: str,
    previous_check_names: List[str],
) -> Dict[str, Any]:
    checks = _serialize_generated_checks()
    new_check_names = [name for name in checks.keys() if name not in previous_check_names]
    session_history = _interactive_session._get_session_history(_session_id, limit=10)
    check_history = _interactive_session._get_session_history(
        _interactive_session.database.check_generator_session_id,
        limit=5,
    )
    session_config = _build_session_config_payload()
    status = "error" if assistant_response.startswith("Error:") else "completed"

    generated_check_artifacts = [
        {
            "name": name,
            "description": info["description"],
            "scope": info["scope"],
            "code": info["code"],
            "isNew": name in new_check_names,
        }
        for name, info in checks.items()
    ]

    summary = {
        "runId": run_id,
        "status": status,
        "startedAt": started_at,
        "finishedAt": finished_at,
        "userMessage": user_message,
        "assistantResponse": assistant_response,
        "requestKind": _infer_request_kind(user_message, new_check_names),
        "newCheckNames": new_check_names,
        "newCheckCount": len(new_check_names),
        "totalChecks": len(checks),
        "sessionModel": _session_model,
        "agentModel": _agent_model,
        "generatedChecks": generated_check_artifacts,
    }

    return {
        "summary": summary,
        "checks": checks,
        "sessionHistory": session_history,
        "checkHistory": check_history,
        "sessionConfig": session_config,
    }


def _build_workflow_state_snapshot(
    *,
    run_id: str,
    status: str,
    started_at: str,
    user_message: str,
    assistant_response: str,
    request_kind: str,
    finished_at: Optional[str] = None,
) -> Dict[str, Any]:
    checks = _serialize_generated_checks()
    session_history = _interactive_session._get_session_history(_session_id, limit=10) if _interactive_session else []
    check_history = (
        _interactive_session._get_session_history(_interactive_session.database.check_generator_session_id, limit=5)
        if _interactive_session
        else []
    )
    session_config = _build_session_config_payload()

    return {
        "summary": {
            "runId": run_id,
            "status": status,
            "startedAt": started_at,
            "finishedAt": finished_at,
            "userMessage": user_message,
            "assistantResponse": assistant_response,
            "requestKind": request_kind,
            "newCheckNames": [],
            "newCheckCount": 0,
            "totalChecks": len(checks),
            "sessionModel": _session_model,
            "agentModel": _agent_model,
            "generatedChecks": [
                {
                    "name": name,
                    "description": info["description"],
                    "scope": info["scope"],
                    "code": info["code"],
                    "isNew": False,
                }
                for name, info in checks.items()
            ],
        },
        "checks": checks,
        "sessionHistory": session_history,
        "checkHistory": check_history,
        "sessionConfig": session_config,
    }


def _set_workflow_state(*, workflow_run: Optional[Dict[str, Any]] = None, pending_review: Optional[Dict[str, Any]] = None) -> None:
    global _latest_workflow_run, _latest_pending_review

    _latest_workflow_run = workflow_run
    _latest_pending_review = pending_review


def _sse_event(payload: Dict[str, Any]) -> str:
    return f"data: {json.dumps(payload, default=str)}\n\n"


def _append_workflow_audit(
    *,
    run_id: str,
    event_type: str,
    status: str,
    message: str,
    request_kind: Optional[str] = None,
    review_id: Optional[str] = None,
    detail: Optional[str] = None,
) -> Dict[str, Any]:
    global _workflow_audit_counter

    _workflow_audit_counter += 1
    entry = {
        "id": f"audit-{_workflow_audit_counter}",
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "runId": run_id,
        "eventType": event_type,
        "status": status,
        "message": message,
    }
    if request_kind:
        entry["requestKind"] = request_kind
    if review_id:
        entry["reviewId"] = review_id
    if detail:
        entry["detail"] = detail

    _workflow_audit_log.append(entry)
    if len(_workflow_audit_log) > _workflow_audit_limit:
        del _workflow_audit_log[0 : len(_workflow_audit_log) - _workflow_audit_limit]
    return entry


def _summarize_planned_call(call: Any) -> Dict[str, str]:
    call_type = getattr(call, "type", call.__class__.__name__)
    if call_type in {"check_generation_v1", "check_generation_v2", "check_generation_v3"}:
        force_regenerate = bool(getattr(call, "force_regenerate", False))
        regeneration_label = "with regeneration of existing checks" if force_regenerate else "without overwriting existing checks"
        return {
            "name": call_type,
            "summary": f"Generate or update validation checks {regeneration_label}.",
        }
    if call_type == "corrupt":
        percentage = float(getattr(call, "percentage", 0.0) or 0.0) * 100
        corruptor_name = getattr(call, "corruptor_name", "unknown_corruptor")
        return {
            "name": "corrupt",
            "summary": f"Apply corruptor {corruptor_name} at {percentage:.1f}% of target rows.",
        }
    if call_type == "export_validation_result":
        directory = getattr(call, "directory", "<unset>")
        return {
            "name": "export_validation_result",
            "summary": f"Export validation findings to {directory}.",
        }
    return {
        "name": call_type,
        "summary": f"Execute planned operation {call_type}.",
    }


def _build_request_review(calls: List[Any], message: str, started_at: str) -> Optional[Dict[str, Any]]:
    review_id = f"review-{uuid4().hex[:12]}"
    call_types = {getattr(call, "type", call.__class__.__name__) for call in calls}
    planned_calls = [_summarize_planned_call(call) for call in calls]
    planned_check_generation = [
        call for call in calls if getattr(call, "type", call.__class__.__name__) in {"check_generation_v1", "check_generation_v2", "check_generation_v3"}
    ]

    if "corrupt" in call_types:
        return {
            "reviewId": review_id,
            "createdAt": started_at,
            "requestKind": "data_mutation",
            "riskLevel": "high",
            "title": "Review data mutation request",
            "summary": "This workflow plans to mutate dataset values through an explicit corruption step.",
            "affectedScope": [
                "Active database tables in the current session",
                "Generated validation results after the mutation",
            ],
            "guardrails": [
                "Confirm the target tables and corruption percentage before continuing.",
                "Run validation immediately after approval to inspect the resulting violations.",
            ],
            "plannedCalls": planned_calls,
            "userMessage": message,
        }

    if planned_check_generation:
        force_regenerate = any(bool(getattr(call, "force_regenerate", False)) for call in planned_check_generation)
        return {
            "reviewId": review_id,
            "createdAt": started_at,
            "requestKind": "validation_rule_update",
            "riskLevel": "high" if force_regenerate else "medium",
            "title": "Review generated validation updates",
            "summary": (
                "This workflow plans to add or replace generated validation checks."
                if force_regenerate
                else "This workflow plans to add new generated validation checks to the active session."
            ),
            "affectedScope": [
                "Generated validation checks available in the current session",
                "Subsequent validation runs and violation summaries",
            ],
            "guardrails": [
                "Review the planned check-generation mode before continuing.",
                "Run validation after approval to confirm the new checks behave as expected.",
            ],
            "plannedCalls": planned_calls,
            "userMessage": message,
        }

    if "export_validation_result" in call_types:
        return {
            "reviewId": review_id,
            "createdAt": started_at,
            "requestKind": "data_export",
            "riskLevel": "medium",
            "title": "Review validation export request",
            "summary": "This workflow plans to export validation findings to the local filesystem.",
            "affectedScope": [
                "Validation result files generated from the current session",
                "Local filesystem path selected by the workflow",
            ],
            "guardrails": [
                "Confirm the export destination before writing any files.",
                "Review the generated findings before sharing exported output.",
            ],
            "plannedCalls": planned_calls,
            "userMessage": message,
        }

    return None


# ---------------------------------------------------------------------------
# Request / Response models
# ---------------------------------------------------------------------------

class ChatRequest(BaseModel):
    message: str = Field(..., min_length=1, max_length=12000)


class WorkflowRunRequest(ChatRequest):
    review_id: Optional[str] = None


class ChatResponse(BaseModel):
    response: str


class ClearResponse(BaseModel):
    status: str


# ---------------------------------------------------------------------------
# Endpoints
# ---------------------------------------------------------------------------

@app.post("/api/chat", response_model=ChatResponse)
async def chat(req: ChatRequest):
    if _interactive_session is None:
        raise HTTPException(status_code=503, detail="Session not initialised. Start the server with --database flag.")
    message = req.message.strip()
    if not message:
        raise HTTPException(status_code=400, detail="Message must not be blank.")

    try:
        response = _interactive_session.process_request(message)
        return ChatResponse(response=response)
    except Exception as exc:
        logger.error(f"Chat error: {exc}")
        raise HTTPException(status_code=500, detail="Failed to process chat request.")


@app.get("/api/checks")
async def get_checks():
    if _interactive_session is None:
        raise HTTPException(status_code=503, detail="Session not initialised.")
    return _serialize_generated_checks()


@app.get("/api/session-history")
async def get_session_history(limit: int = Query(10, ge=1, le=100)):
    if _interactive_session is None:
        raise HTTPException(status_code=503, detail="Session not initialised.")
    return _interactive_session._get_session_history(_session_id, limit=limit)


@app.get("/api/check-history")
async def get_check_history(limit: int = Query(5, ge=1, le=100)):
    if _interactive_session is None:
        raise HTTPException(status_code=503, detail="Session not initialised.")
    check_session_id = _interactive_session.database.check_generator_session_id
    return _interactive_session._get_session_history(check_session_id, limit=limit)


@app.get("/api/session-config")
async def get_session_config():
    if _interactive_session is None:
        raise HTTPException(status_code=503, detail="Session not initialised.")
    return _build_session_config_payload()


@app.post("/api/workflow/run")
async def run_workflow(req: WorkflowRunRequest):
    if _interactive_session is None:
        raise HTTPException(status_code=503, detail="Session not initialised. Start the server with --database flag.")
    message = req.message.strip()
    if not message:
        raise HTTPException(status_code=400, detail="Message must not be blank.")

    approved_review: Optional[Dict[str, Any]] = None
    if req.review_id:
        approved_review = _pending_workflow_reviews.pop(req.review_id, None)
        if approved_review is None:
            raise HTTPException(status_code=404, detail="Workflow review not found or already resolved.")
        if approved_review["message"] != message:
            raise HTTPException(status_code=409, detail="Workflow review message does not match the approval request.")

    async def event_stream() -> AsyncIterator[str]:
        run_id = approved_review["runId"] if approved_review else f"dcc-{int(time.time() * 1000)}"
        started_at = approved_review["startedAt"] if approved_review else datetime.now(timezone.utc).isoformat()
        previous_check_names = list(_serialize_generated_checks().keys())
        request_kind = approved_review["review"]["requestKind"] if approved_review else _infer_request_kind(message, [])
        planned_response = approved_review["plannedResponse"] if approved_review else None
        planned_calls: List[Any] = []
        _set_workflow_state(
            workflow_run=_build_workflow_state_snapshot(
                run_id=run_id,
                status="processing",
                started_at=started_at,
                user_message=message,
                assistant_response="Planning workflow run...",
                request_kind=request_kind,
            ),
            pending_review=approved_review["review"] if approved_review else None,
        )

        yield _sse_event(
            {
                "type": "run.started",
                "runId": run_id,
                "startedAt": started_at,
                "userMessage": message,
            }
        )

        try:
            if planned_response is None:
                planned_response = await asyncio.to_thread(_interactive_session.plan_request, message)
            planned_calls = list(getattr(planned_response.output, "calls", []))
        except Exception as exc:
            logger.error(f"Workflow planning error: {exc}")
            _append_workflow_audit(
                run_id=run_id,
                event_type="run.error",
                status="error",
                message=message,
                request_kind=request_kind,
                detail=str(exc),
            )
            _set_workflow_state(
                workflow_run=_build_workflow_state_snapshot(
                    run_id=run_id,
                    status="error",
                    started_at=started_at,
                    finished_at=datetime.now(timezone.utc).isoformat(),
                    user_message=message,
                    assistant_response=str(exc),
                    request_kind=request_kind,
                ),
                pending_review=None,
            )
            yield _sse_event(
                {
                    "type": "run.error",
                    "runId": run_id,
                    "status": "error",
                    "finishedAt": datetime.now(timezone.utc).isoformat(),
                    "error": str(exc),
                }
            )
            return

        if approved_review is None:
            review = _build_request_review(planned_calls, message, started_at)
            if review:
                _pending_workflow_reviews[review["reviewId"]] = {
                    "runId": run_id,
                    "message": message,
                    "review": review,
                    "plannedResponse": planned_response,
                    "startedAt": started_at,
                }
                _append_workflow_audit(
                    run_id=run_id,
                    event_type="approval.required",
                    status="awaiting_approval",
                    message=message,
                    request_kind=review["requestKind"],
                    review_id=review["reviewId"],
                    detail=review["summary"],
                )
                _set_workflow_state(
                    workflow_run=_build_workflow_state_snapshot(
                        run_id=run_id,
                        status="awaiting_approval",
                        started_at=started_at,
                        user_message=message,
                        assistant_response=f"Approval required: {review['summary']}",
                        request_kind=review["requestKind"],
                    ),
                    pending_review=review,
                )
                yield _sse_event(
                    {
                        "type": "approval.required",
                        "runId": run_id,
                        "status": "awaiting_approval",
                        "review": review,
                    }
                )
                return

        if approved_review is not None:
            _append_workflow_audit(
                run_id=run_id,
                event_type="approval.approved",
                status="approved",
                message=message,
                request_kind=request_kind,
                review_id=req.review_id,
                detail=approved_review["review"]["summary"],
            )
            _set_workflow_state(
                workflow_run=_build_workflow_state_snapshot(
                    run_id=run_id,
                    status="processing",
                    started_at=started_at,
                    user_message=message,
                    assistant_response="Approval granted. Executing planned workflow...",
                    request_kind=request_kind,
                ),
                pending_review=None,
            )
            yield _sse_event(
                {
                    "type": "run.status",
                    "runId": run_id,
                    "status": "processing",
                    "phase": "approval_granted",
                }
            )

        _append_workflow_audit(
            run_id=run_id,
            event_type="run.started",
            status="processing",
            message=message,
            request_kind=request_kind,
        )
        _set_workflow_state(
            workflow_run=_build_workflow_state_snapshot(
                run_id=run_id,
                status="processing",
                started_at=started_at,
                user_message=message,
                assistant_response="Processing executing tools...",
                request_kind=request_kind,
            ),
            pending_review=None,
        )
        yield _sse_event(
            {
                "type": "run.status",
                "runId": run_id,
                "status": "processing",
                "phase": "executing_tools",
            }
        )

        try:
            response = await asyncio.to_thread(_interactive_session.execute_planned_response, message, planned_response)
            finished_at = datetime.now(timezone.utc).isoformat()
            snapshot = _build_workflow_snapshot(
                run_id=run_id,
                user_message=message,
                assistant_response=response,
                started_at=started_at,
                finished_at=finished_at,
                previous_check_names=previous_check_names,
            )

            yield _sse_event(
                {
                    "type": "assistant.message",
                    "runId": run_id,
                    "content": response,
                }
            )
            yield _sse_event(
                {
                    "type": "workflow.snapshot",
                    "runId": run_id,
                    "snapshot": snapshot,
                }
            )
            _set_workflow_state(workflow_run=snapshot, pending_review=None)

            result_type = "run.error" if snapshot["summary"]["status"] == "error" else "run.finished"
            yield _sse_event(
                {
                    "type": result_type,
                    "runId": run_id,
                    "status": snapshot["summary"]["status"],
                    "finishedAt": finished_at,
                    **({"error": response} if result_type == "run.error" else {}),
                }
            )
            _append_workflow_audit(
                run_id=run_id,
                event_type=result_type,
                status=snapshot["summary"]["status"],
                message=message,
                request_kind=snapshot["summary"]["requestKind"],
                detail=snapshot["summary"]["assistantResponse"][:500],
            )
        except Exception as exc:
            logger.error(f"Workflow run error: {exc}")
            _append_workflow_audit(
                run_id=run_id,
                event_type="run.error",
                status="error",
                message=message,
                request_kind=request_kind,
                detail=str(exc),
            )
            _set_workflow_state(
                workflow_run=_build_workflow_state_snapshot(
                    run_id=run_id,
                    status="error",
                    started_at=started_at,
                    finished_at=datetime.now(timezone.utc).isoformat(),
                    user_message=message,
                    assistant_response=str(exc),
                    request_kind=request_kind,
                ),
                pending_review=None,
            )
            yield _sse_event(
                {
                    "type": "run.error",
                    "runId": run_id,
                    "status": "error",
                    "finishedAt": datetime.now(timezone.utc).isoformat(),
                    "error": str(exc),
                }
            )

    return StreamingResponse(
        event_stream(),
        media_type="text/event-stream",
        headers={
            "Cache-Control": "no-cache",
            "Connection": "keep-alive",
            "X-Accel-Buffering": "no",
        },
    )


@app.get("/api/workflow/audit")
async def get_workflow_audit(limit: int = Query(50, ge=1, le=250)):
    return list(reversed(_workflow_audit_log[-limit:]))


@app.get("/api/workflow/state")
async def get_workflow_state():
    return {
        "workflowRun": _latest_workflow_run,
        "pendingReview": _latest_pending_review,
    }


@app.post("/api/workflow/reviews/{review_id}/reject")
async def reject_workflow_review(review_id: str):
    review_context = _pending_workflow_reviews.pop(review_id, None)
    if review_context is None:
        raise HTTPException(status_code=404, detail="Workflow review not found or already resolved.")

    _append_workflow_audit(
        run_id=review_context["runId"],
        event_type="approval.rejected",
        status="rejected",
        message=review_context["message"],
        request_kind=review_context["review"]["requestKind"],
        review_id=review_id,
        detail=review_context["review"]["summary"],
    )
    _set_workflow_state(
        workflow_run=_build_workflow_state_snapshot(
            run_id=review_context["runId"],
            status="error",
            started_at=review_context["startedAt"],
            finished_at=datetime.now(timezone.utc).isoformat(),
            user_message=review_context["message"],
            assistant_response=f"Rejected before execution: {review_context['review']['summary']}",
            request_kind=review_context["review"]["requestKind"],
        ),
        pending_review=None,
    )
    return {
        "status": "rejected",
        "reviewId": review_id,
    }


@app.delete("/api/session", response_model=ClearResponse)
async def clear_session():
    if _interactive_session is None or _session_manager is None:
        raise HTTPException(status_code=503, detail="Session not initialised.")
    _session_manager.clear_session_history(_session_id)
    _pending_workflow_reviews.clear()
    _workflow_audit_log.clear()
    _set_workflow_state(workflow_run=None, pending_review=None)
    return ClearResponse(status="cleared")


@app.get("/api/health")
async def health():
    config_ready = _aicore_config_ready()
    return {
        "status": "ok" if _interactive_session is not None and config_ready else "degraded",
        "session_ready": _interactive_session is not None,
        "session_model": _session_model,
        "agent_model": _agent_model,
        "aicore_config_ready": config_ready,
    }


# ---------------------------------------------------------------------------
# Startup
# ---------------------------------------------------------------------------

def _init_session(
    database_type: str,
    data_dir: Optional[str],
    session_model_key: str,
    agent_model_key: str,
    session_deployment_id: Optional[str],
    agent_deployment_id: Optional[str],
    timeout: int,
    max_tokens: int,
    table_scopes: str,
) -> None:
    global _interactive_session, _session_manager, _session_id, _session_model, _agent_model

    from definition.impl.database.finsight import FinSight, load_finsight_data
    from definition.impl.database.rel_stack import RelStack
    from definition.llm.session_manager import LLMSessionManager
    from definition.llm.models import LLMProvider, LLMSessionConfig
    from definition.llm.interactive.session import InteractiveSession

    model_map = {
        "claude-3.7": LLMProvider.ANTHROPIC_CLAUDE_3_7,
        "claude-4": LLMProvider.ANTHROPIC_CLAUDE_4,
    }

    if session_model_key not in model_map:
        raise ValueError(f"Unsupported session model: {session_model_key}")
    if agent_model_key not in model_map:
        raise ValueError(f"Unsupported agent model: {agent_model_key}")

    _session_model = session_model_key
    _agent_model = agent_model_key

    table_scope_set = {t.strip() for t in table_scopes.split(",") if t.strip()} if table_scopes else set()

    session_manager = LLMSessionManager()

    session_config = LLMSessionConfig(
        model_name=model_map[session_model_key],
        temperature=0.1,
        max_tokens=max_tokens,
        deployment_id=session_deployment_id,
        base_url=os.getenv("AICORE_BASE_URL"),
        auth_url=os.getenv("AICORE_AUTH_URL"),
        client_id=os.getenv("AICORE_CLIENT_ID"),
        client_secret=os.getenv("AICORE_CLIENT_SECRET"),
        resource_group=os.getenv("AICORE_RESOURCE_GROUP", "default"),
    )

    agent_config = LLMSessionConfig(
        model_name=model_map[agent_model_key],
        temperature=0.7,
        max_tokens=max_tokens,
        deployment_id=agent_deployment_id,
        base_url=os.getenv("AICORE_BASE_URL"),
        auth_url=os.getenv("AICORE_AUTH_URL"),
        client_id=os.getenv("AICORE_CLIENT_ID"),
        client_secret=os.getenv("AICORE_CLIENT_SECRET"),
        resource_group=os.getenv("AICORE_RESOURCE_GROUP", "default"),
    )

    max_output_tokens = max(256, max_tokens - 500)

    if database_type == "rel-stack":
        db = RelStack(
            database_id="rel_stack_agent",
            max_output_tokens=max_output_tokens,
            table_scopes=table_scope_set,
            max_execution_time=timeout,
        )

        # Load data
        from bin.copilot import load_relstack_data
        data_path = Path(data_dir) if data_dir else None
        loaded, total = load_relstack_data(db, data_path)
        logger.info(f"Loaded {loaded}/{total} tables")
    elif database_type == "finsight":
        phase2_dir = (Path(data_dir) / "odata_phase2") if data_dir else None
        db = FinSight(
            database_id="finsight_agent",
            max_output_tokens=max_output_tokens,
            table_scopes=table_scope_set,
            max_execution_time=timeout,
            phase2_dir=phase2_dir,
        )
        data_path = Path(data_dir) if data_dir else None
        loaded, total = load_finsight_data(db, data_path)
        logger.info(f"Loaded {loaded}/{total} tables")
    else:
        raise ValueError(f"Unsupported database type: {database_type}")

    sid = f"{database_type}_api_session"
    _session_id = sid
    _session_manager = session_manager

    _interactive_session = InteractiveSession(
        database=db,
        session_manager=session_manager,
        config=session_config,
        session_id=sid,
        agent_config=agent_config,
    )

    logger.success(f"Interactive session '{sid}' ready.")


# ---------------------------------------------------------------------------
# CLI entry-point
# ---------------------------------------------------------------------------

def main() -> None:
    import uvicorn

    def bounded_int(name: str, min_value: int, max_value: int):
        def _parse(value: str) -> int:
            parsed = int(value)
            if parsed < min_value or parsed > max_value:
                raise argparse.ArgumentTypeError(f"{name} must be between {min_value} and {max_value}")
            return parsed
        return _parse

    parser = argparse.ArgumentParser(description="Data Cleaning Copilot - FastAPI Server")
    parser.add_argument("--database", "-d", choices=["rel-stack", "finsight"], required=True)
    parser.add_argument("--session-model", choices=["claude-3.7", "claude-4"], default="claude-4")
    parser.add_argument("--agent-model", choices=["claude-3.7", "claude-4"], default="claude-4")
    parser.add_argument("--session-deployment-id", type=str, default=None)
    parser.add_argument("--agent-deployment-id", type=str, default=None)
    parser.add_argument(
        "--data-dir",
        default="",
        help=(
            "Input data directory. For rel-stack this is optional CSV input; "
            "for finsight this should point to docs/Archive/machine-readable "
            "(or omit to use default workspace path)."
        ),
    )
    parser.add_argument("--timeout", type=bounded_int("timeout", 1, 600), default=120)
    parser.add_argument("--max-tokens", type=bounded_int("max-tokens", 256, 64000), default=10000)
    parser.add_argument("--table-scopes", type=str, default="")
    parser.add_argument("--port", type=bounded_int("port", 1, 65535), default=8000)
    parser.add_argument("--verbose", "-v", action="store_true")
    args = parser.parse_args()

    log_level = "DEBUG" if args.verbose else "INFO"
    logger.remove()
    logger.add(sys.stderr, level=log_level)

    load_dotenv()

    try:
        _init_session(
            database_type=args.database,
            data_dir=args.data_dir,
            session_model_key=args.session_model,
            agent_model_key=args.agent_model,
            session_deployment_id=args.session_deployment_id,
            agent_deployment_id=args.agent_deployment_id,
            timeout=args.timeout,
            max_tokens=args.max_tokens,
            table_scopes=args.table_scopes,
        )
    except Exception as exc:
        logger.error(f"Failed to initialise session: {exc}")
        raise SystemExit(1) from exc

    uvicorn.run(app, host="0.0.0.0", port=args.port)


if __name__ == "__main__":
    main()
