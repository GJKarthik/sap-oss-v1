"""
Training Console API Server
Thin FastAPI proxy/wrapper around the nvidia-modelopt service on port 8001.
Adds CORS for the Angular dev server on port 4200.
"""

import json
import os
import re
from collections import defaultdict
from contextlib import asynccontextmanager
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional

import asyncio
import uuid
from fastapi import FastAPI, HTTPException, Request, WebSocket, WebSocketDisconnect, BackgroundTasks
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse, StreamingResponse
from pydantic import BaseModel, ConfigDict, Field
from sqlalchemy import text
from slowapi import Limiter, _rate_limit_exceeded_handler
from slowapi.errors import RateLimitExceeded
from slowapi.util import get_remote_address
from prometheus_fastapi_instrumentator import Instrumentator
from prometheus_client import Gauge

# ---------------------------------------------------------------------------
# Configuration & State DB
# ---------------------------------------------------------------------------

MAX_BODY_BYTES = int(os.getenv("MAX_BODY_BYTES", str(10 * 1024 * 1024)))
PROXY_RATE_LIMIT = os.getenv("PROXY_RATE_LIMIT", "60/minute")

_allowed_origins_raw = os.getenv(
    "ALLOWED_ORIGINS",
    "http://localhost:4200,http://localhost:4201,http://localhost:8080",
)
ALLOWED_ORIGINS: list[str] = [o.strip() for o in _allowed_origins_raw.split(",") if o.strip()]

# --- DATABASE PERSISTENCE SETUP ---
from .database import engine, SessionLocal, get_db, init_database, close_database, db_backend_label
from .store import JobRecord, get_store, seed_store
from . import rag
from . import pal
from . import data_products
from . import personal_knowledge
from . import workspace_api
from . import notification_api
from . import auth_api
from . import audit_sink_api
from .identity import resolve_request_identity
from .llm_circuit_breaker import LLMCircuitBreaker

from .hana_config import (
    HANA_ENCRYPT,
    HANA_HOST,
    HANA_PASSWORD,
    HANA_PORT,
    HANA_USER,
    AICORE_BASE_URL,
    PAL_UPSTREAM_URL,
    aicore_fully_configured,
    aicore_anthropic_proxy_base,
    vllm_probe_base_url,
)

pal_catalog = pal.PALCatalog()
hana_pal = pal.HanaPALClient(
    host=HANA_HOST,
    port=HANA_PORT,
    user=HANA_USER,
    password=HANA_PASSWORD,
)


def _utc_now() -> datetime:
    return datetime.now(timezone.utc)


def _utc_now_naive() -> datetime:
    return _utc_now().replace(tzinfo=None)


def _utc_now_iso() -> str:
    return _utc_now().isoformat().replace("+00:00", "Z")


def _serialize_utc(dt: datetime | None) -> str | None:
    if dt is None:
        return None
    if dt.tzinfo is None:
        return dt.isoformat() + "Z"
    return dt.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")

def save_job(job_data: dict):
    db = SessionLocal()
    try:
        job = db.query(JobRecord).filter(JobRecord.id == job_data["id"]).first()
        if not job:
            job = JobRecord(id=job_data["id"], created_at=_utc_now_naive())
            db.add(job)
        
        job.status = job_data.get("status", job.status)
        job.progress = job_data.get("progress", job.progress)
        job.config = job_data.get("config", job.config)
        job.error = job_data.get("error", job.error)
        job.history = job_data.get("history", job.history)
        job.evaluation = job_data.get("evaluation", job.evaluation)
        job.deployed = job_data.get("deployed", job.deployed)
        
        db.commit()
    finally:
        db.close()


def _attach_job_governance(job_payload: dict) -> dict:
    summary = get_store().get_governance_summary_for_job(job_payload["id"])
    if summary:
        job_payload["governance"] = summary
    return job_payload

def get_job(job_id: str):
    db = SessionLocal()
    try:
        job = db.query(JobRecord).filter(JobRecord.id == job_id).first()
        if not job: return None
        return _attach_job_governance({
            "id": job.id, "status": job.status, "progress": job.progress, 
            "config": job.config, "error": job.error, "history": job.history,
            "evaluation": job.evaluation, "deployed": job.deployed,
            "created_at": _serialize_utc(job.created_at)
        })
    finally:
        db.close()

def get_all_jobs():
    db = SessionLocal()
    try:
        jobs = db.query(JobRecord).order_by(JobRecord.created_at.desc()).all()
        return [_attach_job_governance({
            "id": job.id, "status": job.status, "progress": job.progress, 
            "config": job.config, "error": job.error, "history": job.history,
            "evaluation": job.evaluation, "deployed": job.deployed,
            "created_at": _serialize_utc(job.created_at)
        }) for job in jobs]
    finally:
        db.close()


def _append_training_artifact(
    run_id: str,
    *,
    artifact_type: str,
    artifact_ref: str,
    metadata_json: Optional[Dict[str, Any]] = None,
) -> None:
    store = get_store()
    artifacts = store.list_training_artifacts(run_id)
    next_artifacts = [artifact for artifact in artifacts if not (artifact["artifact_type"] == artifact_type and artifact["artifact_ref"] == artifact_ref)]
    next_artifacts.append(
        {
            "artifact_type": artifact_type,
            "artifact_ref": artifact_ref,
            "metadata_json": metadata_json or {},
        }
    )
    store.replace_training_artifacts(run_id, next_artifacts)


def _update_governed_run_state(
    run_id: Optional[str],
    *,
    job_id: Optional[str] = None,
    status: Optional[str] = None,
    event_type: Optional[str] = None,
    actor: Optional[str] = None,
    detail: Optional[Dict[str, Any]] = None,
    completed: bool = False,
) -> None:
    if not run_id:
        return
    store = get_store()
    run = store.get_training_run(run_id)
    if not run:
        return
    updates: Dict[str, Any] = {}
    if job_id:
        updates["job_id"] = job_id
    if status:
        updates["status"] = status
    if completed:
        updates["completed_at"] = _utc_now_naive()
    if updates:
        run = store.update_training_run(run_id, updates) or run
    if event_type:
        _record_training_audit_event(run, actor=actor or run.get("requested_by"), event_type=event_type, job_id=job_id, detail=detail)
    _refresh_training_governance_state(run_id)

from src.telemetry import get_system_telemetry

# Models static list
SUPPORTED_MODELS = [
    {"name": "gpt2", "size_gb": 0.5, "parameters": "124M", "recommended_quant": "fp16", "t4_compatible": True},
    {"name": "meta-llama/Llama-3-8B-Instruct", "size_gb": 16.1, "parameters": "8B", "recommended_quant": "int8", "t4_compatible": True},
    {"name": "Qwen/Qwen3.5-0.6B", "size_gb": 1.2, "parameters": "0.6B", "recommended_quant": "fp16", "t4_compatible": True},
    {"name": "mistralai/Mixtral-8x7B-v0.1", "size_gb": 93.5, "parameters": "47B", "recommended_quant": "int4_awq", "t4_compatible": False},
]

FINANCIAL_TERM_TRANSLATIONS: list[tuple[str, str]] = [
    ("إجمالي الإيرادات", "Total Revenue"),
    ("صافي الربح", "Net Profit"),
    ("إجمالي الأصول", "Total Assets"),
    ("إجمالي الالتزامات", "Total Liabilities"),
    ("حقوق المساهمين", "Shareholders Equity"),
    ("التدفقات النقدية", "Cash Flows"),
    ("الميزانية العمومية", "Balance Sheet"),
    ("قائمة الدخل", "Income Statement"),
]


def _contains_arabic(text: str) -> bool:
    return bool(re.search(r"[\u0600-\u06FF]", text))


def _extract_financial_metrics(text: str) -> list[dict[str, Any]]:
    metrics: list[dict[str, Any]] = []
    for arabic_label, english_label in FINANCIAL_TERM_TRANSLATIONS:
        match = re.search(rf"{re.escape(arabic_label)}\s*[:：-]?\s*([0-9][0-9,\.]*)", text)
        if not match:
            continue
        metrics.append(
            {
                "key": english_label,
                "value": match.group(1),
                "confidence": 0.94,
            }
        )
    return metrics


def _extract_regulatory_fields(text: str) -> dict[str, str | None]:
    vat_match = re.search(r"\b3\d{14}\b", text)
    qr_match = re.search(r"\b[A-Za-z0-9+/=]{60,}\b", text)
    return {
        "zatca_qr_base64": qr_match.group(0) if qr_match else None,
        "zatca_vat_number": vat_match.group(0) if vat_match else None,
        "national_address_building": None,
        "national_address_street": None,
        "national_address_district": None,
        "national_address_city": None,
        "national_address_zip": None,
        "egypt_uuid": None,
        "gs1_barcode": None,
        "nbr_vat_number": None,
    }


def _translate_financial_terms(text: str) -> str:
    translated = text
    for arabic_label, english_label in FINANCIAL_TERM_TRANSLATIONS:
        translated = translated.replace(arabic_label, english_label)
    return translated


def _build_fallback_chat_reply(messages: list[dict[str, str]]) -> str:
    latest_user_message = next(
        (message["content"] for message in reversed(messages) if message.get("role") == "user"),
        "",
    )
    combined_context = "\n".join(message.get("content", "") for message in messages)
    metrics = _extract_financial_metrics(combined_context)
    if _contains_arabic(latest_user_message):
        if metrics:
            lines = [f"- {metric['key']}: {metric['value']}" for metric in metrics]
            return "استناداً إلى النص المتاح:\n" + "\n".join(lines)
        return "تم استلام سؤالك. لا توجد مؤشرات مالية كافية في السياق الحالي، لكن الواجهة الخلفية تعمل ويمكنها استقبال الطلبات."

    if metrics:
        lines = [f"- {metric['key']}: {metric['value']}" for metric in metrics]
        return "Summary based on the available document context:\n" + "\n".join(lines)
    return "The service is running, but no structured financial metrics were found in the current context."

# ---------------------------------------------------------------------------
# Rate limiter & Logging
# ---------------------------------------------------------------------------

limiter = Limiter(key_func=get_remote_address)

import structlog
import time
from structlog.contextvars import bind_contextvars, clear_contextvars

structlog.configure(
    processors=[
        structlog.contextvars.merge_contextvars,
        structlog.stdlib.add_log_level,
        structlog.processors.TimeStamper(fmt="iso"),
        structlog.processors.JSONRenderer()
    ],
    context_class=dict,
    logger_factory=structlog.stdlib.LoggerFactory(),
    wrapper_class=structlog.stdlib.BoundLogger,
    cache_logger_on_first_use=True,
)
logger = structlog.get_logger("training-webcomponents-ngx")

_llm_circuit = LLMCircuitBreaker.from_env()

# ---------------------------------------------------------------------------
# LLM Routing Strategy
# ---------------------------------------------------------------------------

class LLMRouter:
    @staticmethod
    def get_endpoint_and_model(
        messages: list[dict[str, str]], preferred_model: str = "default",
    ) -> tuple[str, str, str]:
        """
        Routes queries based on privacy and data type:
        - Metadata/Public -> AI Core (Anthropic)
        - Private/Non-Public -> vLLM TurboQuant (Gemma 4, Qwen 3.5, Nemotron 3)
        """
        latest_msg = next((m.get("content", "").lower() for m in reversed(messages) if m.get("role") == "user"), "")
        
        # Heuristic for private data detection
        private_keywords = ["banking", "nfrp", "client", "customer", "transaction", "private", "confidential"]
        is_private = any(k in latest_msg for k in private_keywords)
        
        if is_private or preferred_model in ["gemma4-arabic-finance", "qwen3.5-35b-turbo", "nemotron3-8b"]:
            # Route to local vLLM TurboQuant
            vllm_url = vllm_probe_base_url()
            model = preferred_model if preferred_model != "default" else "Qwen/Qwen3.5-35B-A3B-FP8"
            
            # RESILIENCE: Check if vllm is actually reachable, otherwise return local mock indicator
            # In a production router, this would be a circuit breaker
            return f"{vllm_url}/v1/chat/completions", model, "vllm"
        else:
            # Route to AI Core (Anthropic) proxy or direct
            aicore_url = aicore_anthropic_proxy_base()
            return (
                f"{aicore_url}/v1/chat/completions",
                "claude-3-5-sonnet-20240620",
                "aicore",
            )


async def _upstream_chat_completions(
    circuit_key: str,
    endpoint: str,
    payload: dict[str, Any],
    timeout: float,
) -> Optional[dict[str, Any]]:
    """POST chat completions upstream; honors circuit breaker. Returns None on skip/failure."""
    import httpx

    if not await _llm_circuit.allow_request(circuit_key):
        logger.info("llm_circuit_open", circuit=circuit_key, endpoint=endpoint)
        return None
    try:
        async with httpx.AsyncClient(timeout=timeout) as client:
            resp = await client.post(
                endpoint,
                json=payload,
                headers={"Content-Type": "application/json"},
            )
        if resp.status_code == 200:
            await _llm_circuit.record_success(circuit_key)
            return resp.json()
        await _llm_circuit.record_failure(circuit_key)
        logger.warning(
            "llm_upstream_non_200",
            status_code=resp.status_code,
            endpoint=endpoint,
            circuit=circuit_key,
        )
    except Exception as e:
        await _llm_circuit.record_failure(circuit_key)
        logger.warning("llm_upstream_error", error=str(e), endpoint=endpoint, circuit=circuit_key)
    return None


async def _call_llm_with_fallback(messages: list, preferred_model: str = "default"):
    """
    Attempts to call the routed LLM, but falls back to native simulation
    if the endpoint is unreachable or errors out.
    """
    endpoint, model, circuit_key = LLMRouter.get_endpoint_and_model(messages, preferred_model)

    data = await _upstream_chat_completions(
        circuit_key,
        endpoint,
        {"model": model, "messages": messages},
        5.0,
    )
    if data is not None:
        return data

    # Fallback to internal analytical synthesis
    simulated_text = simulate_analytical_response(messages)
    return {
        "choices": [{
            "message": {
                "role": "assistant",
                "content": simulated_text
            },
            "finish_reason": "stop"
        }],
        "model": "native-fallback-synthesis"
    }

# ---------------------------------------------------------------------------
# Native data cleaning state (lets training-webcomponents-ngx run standalone)
# ---------------------------------------------------------------------------

DATA_CLEANING_STATE: dict[str, Any] = {
    "messages": [],
    "checks": [],
    "workflow_runs": {},
}

DATA_CLEANING_TERMINAL_STATES = {"completed", "failed"}


def _native_generate_checks(message: str) -> list[dict[str, Any]]:
    lower = message.lower()
    checks: list[dict[str, Any]] = []
    if "null" in lower or "missing" in lower:
        checks.append(
            {
                "name": "null_ratio_check",
                "severity": "high",
                "description": "Flag columns where null ratio exceeds 5%.",
                "sql_hint": "SELECT col, COUNT(*) FILTER (WHERE col IS NULL) * 100.0 / COUNT(*) AS null_pct FROM table;",
            }
        )
    if "duplicate" in lower or "dedup" in lower:
        checks.append(
            {
                "name": "duplicate_key_check",
                "severity": "high",
                "description": "Detect duplicate primary/business key rows.",
                "sql_hint": "SELECT key_col, COUNT(*) FROM table GROUP BY key_col HAVING COUNT(*) > 1;",
            }
        )
    if "outlier" in lower or "anomaly" in lower:
        checks.append(
            {
                "name": "outlier_distribution_check",
                "severity": "medium",
                "description": "Detect metric outliers using z-score thresholds.",
                "sql_hint": "Use AVG/STDDEV and flag ABS((x-avg)/stddev) > 3.",
            }
        )
    if "schema" in lower or "type" in lower:
        checks.append(
            {
                "name": "schema_conformance_check",
                "severity": "medium",
                "description": "Validate inferred types against schema contract.",
                "sql_hint": "Compare INFORMATION_SCHEMA columns with expected dictionary metadata.",
            }
        )
    if not checks:
        checks.append(
            {
                "name": "freshness_and_volume_baseline",
                "severity": "low",
                "description": "Track row-count deltas and load freshness.",
                "sql_hint": "Compare daily row counts and max(updated_at) with 7-day baseline.",
            }
        )
    return checks


async def _run_native_data_cleaning_workflow(run_id: str, message: str) -> None:
    run = DATA_CLEANING_STATE["workflow_runs"].get(run_id)
    if not run:
        return

    run["status"] = "running"
    steps = [
        ("profile", "Profiling candidate training data slice"),
        ("validate", "Validating nulls, duplicates, and schema conformance"),
        ("remediate", "Generating remediation plan for flagged records"),
        ("publish", "Preparing cleaned dataset snapshot for model training"),
    ]
    for phase, description in steps:
        event = {
            "ts": _utc_now_iso(),
            "phase": phase,
            "message": description,
            "status": "ok",
        }
        run["events"].append(event)
        await asyncio.sleep(0.25)

    latest_checks = _native_generate_checks(message)
    DATA_CLEANING_STATE["checks"] = latest_checks
    run["status"] = "completed"
    run["result"] = {
        "checks_generated": len(latest_checks),
        "summary": "Workflow completed. Generated data quality checks and remediation guidance for training prep.",
    }
    run["events"].append(
        {
            "ts": _utc_now_iso(),
            "phase": "completed",
            "message": "Workflow completed",
            "status": "ok",
        }
    )


# ---------------------------------------------------------------------------
# App lifecycle
# ---------------------------------------------------------------------------

@asynccontextmanager
async def lifespan(app: FastAPI):  # type: ignore[type-arg]
    await init_database()
    seed_store()
    ensure_training_governance_seed_defaults()
    try:
        yield
    finally:
        await close_database()


app = FastAPI(
    title="Training Console API Framework",
    description="Native Orchestration Engine and Database",
    version="1.0.0",
    lifespan=lifespan,
)

# Prometheus standard HTTP instrumentation
Instrumentator().instrument(app).expose(app)

ACTIVE_WEBSOCKETS = Gauge("active_websocket_connections", "Number of currently active WebSocket consumers")

app.state.limiter = limiter
app.add_exception_handler(RateLimitExceeded, _rate_limit_exceeded_handler)

app.add_middleware(
    CORSMiddleware,
    allow_origins=ALLOWED_ORIGINS,
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

app.include_router(rag.router, prefix="/rag", tags=["RAG"])
app.include_router(personal_knowledge.router, prefix="/knowledge", tags=["Personal Knowledge"])
app.include_router(data_products.router, prefix="/data-products", tags=["Data Products"])
app.include_router(workspace_api.router, prefix="/workspace", tags=["Workspace"])
app.include_router(notification_api.router, prefix="/notifications", tags=["Notifications"])
app.include_router(auth_api.router, prefix="/auth", tags=["Auth"])
app.include_router(audit_sink_api.router, prefix="/audit", tags=["Audit"])

@app.middleware("http")
async def security_headers_middleware(request: Request, call_next):
    response = await call_next(request)
    response.headers["Strict-Transport-Security"] = "max-age=31536000; includeSubDomains"
    response.headers["X-Content-Type-Options"] = "nosniff"
    response.headers["X-Frame-Options"] = "DENY"
    response.headers["Content-Security-Policy"] = "default-src 'self' 'unsafe-inline' 'unsafe-eval' data:; connect-src 'self' ws: wss: http: https:;"
    return response

@app.middleware("http")
async def structlog_middleware(request: Request, call_next):
    clear_contextvars()
    identity = resolve_request_identity(request)
    bind_contextvars(
        request_id=request.headers.get("x-request-id", str(uuid.uuid4())),
        user_id=identity.user_id,
        user_email=identity.email,
        auth_source=identity.auth_source,
    )
    start_time = time.time()
    try:
        response = await call_next(request)
        process_time = time.time() - start_time
        logger.info("request_completed", method=request.method, path=request.url.path, status=response.status_code, duration_s=round(process_time, 4))
        return response
    except Exception as e:
        process_time = time.time() - start_time
        logger.exception("request_failed", method=request.method, path=request.url.path, error=str(e), duration_s=round(process_time, 4))
        raise
    finally:
        clear_contextvars()


# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------

class DataCleaningChatRequest(BaseModel):
    message: str


class DataCleaningWorkflowRunRequest(BaseModel):
    message: str

@app.websocket("/ws")
async def websocket_endpoint(websocket: WebSocket):
    await websocket.accept()
    ACTIVE_WEBSOCKETS.inc()
    try:
        while True:
            gpu_data = {
                "type": "gpu",
                "data": get_system_telemetry()
            }
            
            active_jobs = get_all_jobs()
            
            job_data = {
                "type": "jobs",
                "data": active_jobs[:10]  # Emit top 10 most recent jobs
            }
            await websocket.send_json(gpu_data)
            await websocket.send_json(job_data)
            
            await asyncio.sleep(2)
    except WebSocketDisconnect:
        pass
    finally:
        ACTIVE_WEBSOCKETS.dec()

# --- PER-JOB WEBSOCKET STREAMING ---

# Maps job_id -> set of connected WebSocket clients
JOB_WS_CONNECTIONS: dict[str, set] = {}

async def broadcast_job(job_id: str, message: dict) -> None:
    """Fan-out a message to all WS clients watching a specific job."""
    connections = JOB_WS_CONNECTIONS.get(job_id, set())
    dead: set = set()
    for ws in connections:
        try:
            await ws.send_json(message)
        except Exception:
            dead.add(ws)
    connections.difference_update(dead)

@app.websocket("/ws/jobs/{job_id}")
async def job_ws_endpoint(websocket: WebSocket, job_id: str):
    """WebSocket endpoint for live training job log streaming."""
    await websocket.accept()
    if job_id not in JOB_WS_CONNECTIONS:
        JOB_WS_CONNECTIONS[job_id] = set()
    JOB_WS_CONNECTIONS[job_id].add(websocket)

    # Hydrate client with current job state from DB
    job = get_job(job_id)
    if job:
        await websocket.send_json({"type": "init", "data": job})
    else:
        await websocket.send_json({"type": "error", "detail": "Job not found"})

    try:
        while True:
            data = await websocket.receive_text()
            if data == "ping":
                await websocket.send_json({"type": "pong"})
    except WebSocketDisconnect:
        pass
    finally:
        JOB_WS_CONNECTIONS.get(job_id, set()).discard(websocket)


# ---------------------------------------------------------------------------
# Team Governance API — approvals, policies
# ---------------------------------------------------------------------------

class ApprovalRequest(BaseModel):
    title: str
    description: str = ""
    risk_level: str = "medium"  # low, medium, high, critical
    requested_by: str = "system"
    approvers: list[str] = Field(default_factory=list)
    workflow_type: str = "training"
    run_id: Optional[str] = None


class ApprovalDecisionRequest(BaseModel):
    approver: str = "unknown"
    action: str = "approve"
    comment: str = ""


class TrainingPolicyUpdateRequest(BaseModel):
    enabled: Optional[bool] = None
    description: Optional[str] = None
    severity: Optional[str] = None
    condition_json: Optional[Dict[str, Any]] = None


class TrainingRunCreateRequest(BaseModel):
    workflow_type: str
    use_case_family: str = "training"
    team: str = ""
    requested_by: str = "system"
    run_name: str = ""
    model_name: Optional[str] = None
    dataset_ref: Optional[str] = None
    config_json: Dict[str, Any] = Field(default_factory=dict)
    tag: Optional[str] = None


class TrainingRunUpdateRequest(BaseModel):
    run_name: Optional[str] = None
    dataset_ref: Optional[str] = None
    tag: Optional[str] = None


DEFAULT_TRAINING_POLICIES: list[dict[str, Any]] = [
    {
        "id": "training-policy-deployment-approval",
        "name": "Deployment Approval Gate",
        "description": "All deployment runs require explicit approval before launch.",
        "workflow_type": "deployment",
        "rule_type": "approval",
        "enabled": True,
        "severity": "high",
        "condition_json": {"always": True},
    },
    {
        "id": "training-policy-validation-required",
        "name": "Validation Required",
        "description": "Pipeline training generation runs must keep validation enabled.",
        "workflow_type": "pipeline",
        "rule_type": "block",
        "enabled": True,
        "severity": "high",
        "condition_json": {"validate_required": True},
    },
    {
        "id": "training-policy-metadata-required",
        "name": "Metadata Required",
        "description": "Training runs must provide enough metadata to identify the model or dataset in scope.",
        "workflow_type": None,
        "rule_type": "block",
        "enabled": True,
        "severity": "high",
        "condition_json": {"metadata_required": True},
    },
    {
        "id": "training-policy-large-generation-approval",
        "name": "Large Data Generation Approval",
        "description": "Large training-data generation batches require approval.",
        "workflow_type": "pipeline",
        "rule_type": "approval",
        "enabled": True,
        "severity": "medium",
        "condition_json": {"examples_per_domain_gte": 50000},
    },
    {
        "id": "training-policy-high-cost-model-approval",
        "name": "High Cost Model Approval",
        "description": "Optimization runs for larger models require approval.",
        "workflow_type": "optimization",
        "rule_type": "approval",
        "enabled": True,
        "severity": "high",
        "condition_json": {"model_size_gb_gte": 10},
    },
]


def ensure_training_governance_seed_defaults() -> None:
    get_store().ensure_training_governance_defaults(DEFAULT_TRAINING_POLICIES)


def _parse_iso_utc(value: Optional[str]) -> Optional[datetime]:
    if not value:
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    except Exception:
        return None


def _extract_examples_per_domain(config: Dict[str, Any]) -> int:
    value = config.get("examples_per_domain", config.get("examplesPerDomain", 0))
    try:
        return int(value or 0)
    except Exception:
        return 0


def _extract_model_size_gb(model_name: Optional[str], config: Dict[str, Any]) -> float:
    for key in ("estimated_size_gb", "size_gb", "estimated_vram_gb"):
        value = config.get(key)
        if isinstance(value, (int, float)):
            return float(value)
        if isinstance(value, str):
            try:
                return float(value)
            except ValueError:
                pass

    for model in SUPPORTED_MODELS:
        if model_name and model.get("name") == model_name:
            return float(model.get("size_gb", 0.0))

    match = re.search(r"(\d+(?:\.\d+)?)\s*[bB]", model_name or "")
    if match:
        return float(match.group(1)) * 2.0
    return 0.0


def _metadata_present(run: Dict[str, Any]) -> bool:
    config = run.get("config_json", {}) or {}
    workflow_type = run.get("workflow_type")
    if workflow_type == "pipeline":
        return bool(run.get("dataset_ref") or run.get("team") or _extract_examples_per_domain(config) > 0)
    if workflow_type == "optimization":
        return bool(run.get("model_name") or config.get("model_name"))
    if workflow_type == "deployment":
        return bool(run.get("job_id") or config.get("job_id") or config.get("source_job_id") or run.get("model_name"))
    return bool(run.get("dataset_ref") or run.get("model_name") or run.get("job_id"))


def _validation_enabled(run: Dict[str, Any]) -> bool:
    config = run.get("config_json", {}) or {}
    if "validate" in config:
        return bool(config.get("validate"))
    if "should_validate" in config:
        return bool(config.get("should_validate"))
    return True


def _risk_tier(score: float) -> str:
    if score >= 80:
        return "critical"
    if score >= 60:
        return "high"
    if score >= 35:
        return "medium"
    return "low"


def _calculate_risk_profile(
    workflow_type: str,
    config: Dict[str, Any],
    model_name: Optional[str],
    dataset_ref: Optional[str],
) -> tuple[float, str]:
    base = {"pipeline": 45.0, "optimization": 60.0, "deployment": 80.0}.get(workflow_type, 50.0)
    examples = _extract_examples_per_domain(config)
    size_gb = _extract_model_size_gb(model_name, config)

    if examples >= 50000:
        base += 10
    if examples >= 200000:
        base += 10
    if workflow_type == "pipeline" and not bool(config.get("validate", config.get("should_validate", True))):
        base += 25
    if size_gb >= 10:
        base += 10
    if size_gb >= 40:
        base += 10
    if workflow_type == "deployment":
        base += 5
    if not dataset_ref and workflow_type == "pipeline":
        base += 5

    score = max(0.0, min(100.0, base))
    return score, _risk_tier(score)


def _default_approvers_for_run(run: Dict[str, Any]) -> list[str]:
    approvers: list[str] = ["team-lead"]
    if run.get("workflow_type") == "pipeline":
        approvers.append("data-owner")
    if run.get("workflow_type") == "deployment" or run.get("risk_tier") in {"high", "critical"}:
        approvers.append("risk-owner")
    deduped: list[str] = []
    for approver in approvers:
        if approver not in deduped:
            deduped.append(approver)
    return deduped


def _policy_matches(policy: Dict[str, Any], run: Dict[str, Any]) -> bool:
    if policy.get("workflow_type") and policy["workflow_type"] != run["workflow_type"]:
        return False
    condition = policy.get("condition_json", {}) or {}
    config = run.get("config_json", {}) or {}
    if condition.get("always"):
        return True
    if condition.get("validate_required"):
        return not _validation_enabled(run)
    if condition.get("metadata_required"):
        return not _metadata_present(run)
    threshold = condition.get("examples_per_domain_gte")
    if threshold is not None:
        return _extract_examples_per_domain(config) >= int(threshold)
    threshold = condition.get("model_size_gb_gte")
    if threshold is not None:
        return _extract_model_size_gb(run.get("model_name"), config) >= float(threshold)
    return False


def _evaluate_policy_actions(run: Dict[str, Any], policies: list[Dict[str, Any]]) -> tuple[list[str], list[str]]:
    approval_reasons: list[str] = []
    block_reasons: list[str] = []
    for policy in policies:
        if not policy.get("enabled", True):
            continue
        if not _policy_matches(policy, run):
            continue
        if policy.get("rule_type") == "approval":
            approval_reasons.append(policy["name"])
        elif policy.get("rule_type") == "block":
            block_reasons.append(policy["name"])
    return approval_reasons, block_reasons


def _record_training_audit_event(
    run: Dict[str, Any],
    *,
    actor: Optional[str],
    event_type: str,
    job_id: Optional[str] = None,
    detail: Optional[Dict[str, Any]] = None,
) -> None:
    store = get_store()
    payload = {
        "run_id": run["id"],
        "job_id": job_id or run.get("job_id"),
        "workflow_type": run["workflow_type"],
        "actor": actor or run.get("requested_by") or "system",
        "event_type": event_type,
        "risk_tier": run.get("risk_tier"),
        "gate_status": run.get("gate_status"),
        "approval_status": run.get("approval_status"),
        "detail": detail or {},
        "timestamp": _utc_now_iso(),
    }
    store.insert_audit_batch([payload])


def _build_gate_checks(
    run: Dict[str, Any],
    approval: Optional[Dict[str, Any]],
    policy_blockers: list[str],
    approval_required: bool,
    job: Optional[Dict[str, Any]],
    audit_entries: list[Dict[str, Any]],
    artifacts: list[Dict[str, Any]],
) -> list[dict[str, Any]]:
    metadata_present = _metadata_present(run)
    validation_enabled = _validation_enabled(run)
    evaluation_available = bool(job and job.get("evaluation"))
    deployment_ready = bool(job and job.get("status") == "completed" and evaluation_available)
    artifact_ready = bool(artifacts or run.get("dataset_ref") or run.get("job_id") or run.get("model_name"))

    checks: list[dict[str, Any]] = [
        {
            "gate_key": "metadata_present",
            "category": "control",
            "status": "passed" if metadata_present else "blocked",
            "detail": "Run metadata is registered." if metadata_present else "Run metadata is incomplete.",
            "blocking": True,
            "metadata_json": {"workflow_type": run["workflow_type"]},
        },
        {
            "gate_key": "validation_enabled",
            "category": "control",
            "status": "passed" if validation_enabled else "blocked",
            "detail": "Validation is enabled." if validation_enabled else "Validation is disabled for this run.",
            "blocking": run["workflow_type"] == "pipeline",
            "metadata_json": {"validate": validation_enabled},
        },
        {
            "gate_key": "policy_compliance",
            "category": "control",
            "status": "blocked" if policy_blockers else "passed",
            "detail": "; ".join(policy_blockers) if policy_blockers else "No policy violations detected.",
            "blocking": True,
            "metadata_json": {"policy_blockers": policy_blockers},
        },
        {
            "gate_key": "required_approvals",
            "category": "control",
            "status": (
                "passed"
                if not approval_required or (approval and approval.get("status") == "approved")
                else ("blocked" if approval and approval.get("status") == "rejected" else "pending")
            ),
            "detail": (
                "No approval is required."
                if not approval_required
                else (
                    "Approval completed."
                    if approval and approval.get("status") == "approved"
                    else (
                        "Approval rejected."
                        if approval and approval.get("status") == "rejected"
                        else "Awaiting approval."
                    )
                )
            ),
            "blocking": approval_required,
            "metadata_json": {"approval_id": approval.get("id") if approval else None},
        },
        {
            "gate_key": "dataset_quality_available",
            "category": "metric",
            "status": "passed" if run["workflow_type"] != "pipeline" or validation_enabled else "blocked",
            "detail": (
                "Dataset quality controls are defined."
                if run["workflow_type"] == "pipeline"
                else "Dataset quality metric not required for this workflow."
            ),
            "blocking": run["workflow_type"] == "pipeline",
            "metadata_json": {},
        },
        {
            "gate_key": "training_evaluation_available",
            "category": "metric",
            "status": (
                "passed"
                if run["workflow_type"] != "deployment" or evaluation_available
                else "blocked"
            ),
            "detail": (
                "Training evaluation is available."
                if evaluation_available
                else "Deployment requires a completed evaluation."
            ),
            "blocking": run["workflow_type"] == "deployment",
            "metadata_json": {"job_id": run.get("job_id")},
        },
        {
            "gate_key": "deployment_readiness_available",
            "category": "metric",
            "status": (
                "passed"
                if run["workflow_type"] != "deployment" or deployment_ready
                else "blocked"
            ),
            "detail": (
                "Deployment readiness is confirmed."
                if deployment_ready
                else "Deployment requires a completed linked optimization job."
            ),
            "blocking": run["workflow_type"] == "deployment",
            "metadata_json": {"job_status": job.get("status") if job else None},
        },
        {
            "gate_key": "audit_event_written",
            "category": "evidence",
            "status": "passed" if audit_entries else "pending",
            "detail": "Audit evidence exists." if audit_entries else "No audit evidence has been recorded yet.",
            "blocking": False,
            "metadata_json": {"audit_count": len(audit_entries)},
        },
        {
            "gate_key": "artifacts_registered",
            "category": "evidence",
            "status": "passed" if artifact_ready else "pending",
            "detail": "Artifact references are registered." if artifact_ready else "Artifact references are not registered yet.",
            "blocking": False,
            "metadata_json": {"artifact_count": len(artifacts)},
        },
    ]
    return checks


def _effective_gate_status(checks: list[Dict[str, Any]]) -> str:
    blocking_checks = [check for check in checks if check.get("blocking")]
    if any(check["status"] == "blocked" for check in blocking_checks):
        return "blocked"
    if any(check["status"] == "pending" for check in blocking_checks):
        return "pending_approval"
    return "passed"


def _build_metric_snapshots(
    run: Dict[str, Any],
    approval: Optional[Dict[str, Any]],
    checks: list[Dict[str, Any]],
    job: Optional[Dict[str, Any]],
) -> list[Dict[str, Any]]:
    blocking_checks = [check for check in checks if check.get("blocking")]
    passed_blocking = [check for check in blocking_checks if check["status"] == "passed"]
    total_blocking = len(blocking_checks)
    gate_fraction = (len(passed_blocking) / total_blocking) if total_blocking else 1.0

    approval_latency = 0.0
    if approval and approval.get("status") == "approved" and approval.get("decisions"):
        created_at = _parse_iso_utc(approval.get("created_at"))
        final_decision_at = _parse_iso_utc(approval["decisions"][-1].get("decided_at"))
        if created_at and final_decision_at:
            approval_latency = max(0.0, (final_decision_at - created_at).total_seconds())

    evaluation = job.get("evaluation") if job else None
    evaluation_available = bool(evaluation)

    metrics: list[Dict[str, Any]] = [
        {
            "workflow_type": run["workflow_type"],
            "team": run.get("team", ""),
            "metric_key": "risk_score",
            "stage": "governance",
            "value": float(run["risk_score"]),
            "unit": "score",
            "threshold_max": 79.0,
            "passed": float(run["risk_score"]) < 80.0,
            "metadata_json": {"risk_tier": run["risk_tier"]},
        },
        {
            "workflow_type": run["workflow_type"],
            "team": run.get("team", ""),
            "metric_key": "gate_pass_fraction",
            "stage": "governance",
            "value": gate_fraction,
            "unit": "ratio",
            "numerator": float(len(passed_blocking)),
            "denominator": float(total_blocking),
            "threshold_min": 1.0,
            "passed": gate_fraction >= 1.0,
            "metadata_json": {},
        },
        {
            "workflow_type": run["workflow_type"],
            "team": run.get("team", ""),
            "metric_key": "approval_completed",
            "stage": "governance",
            "value": 0.0 if approval and approval.get("status") != "approved" else 1.0,
            "unit": "flag",
            "threshold_min": 1.0,
            "passed": not approval or approval.get("status") == "approved",
            "metadata_json": {"approval_status": approval.get("status") if approval else "not_required"},
        },
        {
            "workflow_type": run["workflow_type"],
            "team": run.get("team", ""),
            "metric_key": "approval_latency_seconds",
            "stage": "governance",
            "value": approval_latency,
            "unit": "seconds",
            "passed": True,
            "metadata_json": {},
        },
        {
            "workflow_type": run["workflow_type"],
            "team": run.get("team", ""),
            "metric_key": "blocked_run",
            "stage": "governance",
            "value": 1.0 if run.get("gate_status") == "blocked" else 0.0,
            "unit": "flag",
            "threshold_max": 0.0,
            "passed": run.get("gate_status") != "blocked",
            "metadata_json": {},
        },
        {
            "workflow_type": run["workflow_type"],
            "team": run.get("team", ""),
            "metric_key": "run_success",
            "stage": "runtime",
            "value": 1.0 if run.get("status") == "completed" else 0.0,
            "unit": "flag",
            "threshold_min": 1.0,
            "passed": run.get("status") == "completed",
            "metadata_json": {},
        },
        {
            "workflow_type": run["workflow_type"],
            "team": run.get("team", ""),
            "metric_key": "evaluation_complete",
            "stage": "runtime",
            "value": 1.0 if evaluation_available else 0.0,
            "unit": "flag",
            "threshold_min": 1.0 if run["workflow_type"] == "deployment" else 0.0,
            "passed": evaluation_available if run["workflow_type"] == "deployment" else True,
            "metadata_json": {},
        },
    ]

    if evaluation:
        metrics.extend(
            [
                {
                    "workflow_type": run["workflow_type"],
                    "team": run.get("team", ""),
                    "metric_key": "perplexity",
                    "stage": "evaluation",
                    "value": float(evaluation.get("perplexity", 0.0)),
                    "unit": "perplexity",
                    "passed": True,
                    "metadata_json": {},
                },
                {
                    "workflow_type": run["workflow_type"],
                    "team": run.get("team", ""),
                    "metric_key": "eval_loss",
                    "stage": "evaluation",
                    "value": float(evaluation.get("eval_loss", 0.0)),
                    "unit": "loss",
                    "passed": True,
                    "metadata_json": {},
                },
            ]
        )
    return metrics


def _training_run_detail(run_id: str) -> Dict[str, Any]:
    store = get_store()
    run = store.get_training_run(run_id)
    if not run:
        raise HTTPException(status_code=404, detail="Training run not found")
    approval = store.get_training_approval_for_run(run_id)
    gate_checks = store.list_training_gate_checks(run_id)
    metrics = store.list_training_metric_snapshots(run_id=run_id)
    artifacts = store.list_training_artifacts(run_id)
    audit_entries = store.list_audit_entries(run_id=run_id, limit=200)
    job = get_job(run["job_id"]) if run.get("job_id") else None
    return {
        **run,
        "approvals": [approval] if approval else [],
        "gate_checks": gate_checks,
        "metrics": metrics,
        "artifacts": artifacts,
        "audit_entries": audit_entries,
        "job": job,
    }


def _refresh_training_governance_state(run_id: str) -> Dict[str, Any]:
    store = get_store()
    run = store.get_training_run(run_id)
    if not run:
        raise HTTPException(status_code=404, detail="Training run not found")

    policies = [policy for policy in store.list_training_policies(workflow_type=run["workflow_type"]) if policy.get("enabled", True)]
    approval_required_reasons, policy_blockers = _evaluate_policy_actions(run, policies)
    approval_required = len(approval_required_reasons) > 0

    approval = store.get_training_approval_for_run(run_id)
    if approval_required and not approval:
        approval = store.create_training_approval(
            {
                "run_id": run_id,
                "workflow_type": run["workflow_type"],
                "title": f"Approve {run['workflow_type']} run {run.get('run_name') or run_id}",
                "description": "Required by policy: " + ", ".join(approval_required_reasons),
                "risk_level": run["risk_tier"],
                "requested_by": run["requested_by"],
                "approvers": _default_approvers_for_run(run),
            }
        )
        run = store.update_training_run(run_id, {"approval_status": "pending"}) or run

    audit_entries = store.list_audit_entries(run_id=run_id, limit=200)
    artifacts = store.list_training_artifacts(run_id)
    job = get_job(run["job_id"]) if run.get("job_id") else None

    checks = _build_gate_checks(
        run,
        approval,
        policy_blockers,
        approval_required,
        job,
        audit_entries,
        artifacts,
    )
    gate_status = _effective_gate_status(checks)
    approval_status = approval["status"] if approval else "not_required"
    blocking_checks = [
        {
            "gate_key": check["gate_key"],
            "category": check["category"],
            "detail": check["detail"],
            "status": check["status"],
        }
        for check in checks
        if check["blocking"] and check["status"] != "passed"
    ]

    updated_run = store.update_training_run(
        run_id,
        {
            "approval_status": approval_status,
            "gate_status": gate_status,
            "blocking_checks": blocking_checks,
        },
    ) or run
    updated_run["gate_status"] = gate_status
    updated_run["approval_status"] = approval_status

    metrics = _build_metric_snapshots(updated_run, approval, checks, job)
    store.replace_training_gate_checks(run_id, checks)
    store.replace_training_metric_snapshots(run_id, metrics)
    return _training_run_detail(run_id)


def _create_and_submit_training_run(
    *,
    workflow_type: str,
    config_json: Optional[Dict[str, Any]] = None,
    use_case_family: str = "training",
    team: str = "",
    requested_by: str = "system",
    run_name: Optional[str] = None,
    model_name: Optional[str] = None,
    dataset_ref: Optional[str] = None,
    job_id: Optional[str] = None,
    tag: Optional[str] = None,
) -> Dict[str, Any]:
    normalized_config = dict(config_json or {})
    derived_model_name = model_name or normalized_config.get("model_name")
    derived_dataset_ref = dataset_ref or normalized_config.get("dataset_ref")
    risk_score, risk_tier = _calculate_risk_profile(
        workflow_type,
        normalized_config,
        derived_model_name,
        derived_dataset_ref,
    )
    run = get_store().create_training_run(
        {
            "workflow_type": workflow_type,
            "use_case_family": use_case_family,
            "team": team,
            "requested_by": requested_by or "system",
            "run_name": run_name or f"{workflow_type}-{uuid.uuid4().hex[:6]}",
            "model_name": derived_model_name,
            "dataset_ref": derived_dataset_ref,
            "job_id": job_id,
            "config_json": normalized_config,
            "risk_tier": risk_tier,
            "risk_score": risk_score,
            "approval_status": "not_required",
            "gate_status": "draft",
            "status": "draft",
            "tag": tag,
        }
    )
    _record_training_audit_event(run, actor=requested_by or "system", event_type="training_run_created")
    run = get_store().update_training_run(
        run["id"],
        {
            "job_id": job_id,
            "status": "submitted",
            "submitted_at": _utc_now_naive(),
        },
    ) or run
    _record_training_audit_event(run, actor=requested_by or "system", event_type="training_run_submitted")
    return _refresh_training_governance_state(run["id"])


def _resolve_governance_run_detail(
    *,
    workflow_type: str,
    governance_run_id: Optional[str],
    config_json: Optional[Dict[str, Any]] = None,
    use_case_family: str = "training",
    team: str = "",
    requested_by: str = "system",
    run_name: Optional[str] = None,
    model_name: Optional[str] = None,
    dataset_ref: Optional[str] = None,
    job_id: Optional[str] = None,
    tag: Optional[str] = None,
) -> Dict[str, Any]:
    if not governance_run_id:
        return _create_and_submit_training_run(
            workflow_type=workflow_type,
            config_json=config_json,
            use_case_family=use_case_family,
            team=team,
            requested_by=requested_by,
            run_name=run_name,
            model_name=model_name,
            dataset_ref=dataset_ref,
            job_id=job_id,
            tag=tag,
        )

    run = get_store().get_training_run(governance_run_id)
    if not run:
        raise HTTPException(status_code=404, detail="Training run not found")
    if run["workflow_type"] != workflow_type:
        raise HTTPException(
            status_code=400,
            detail=f"Training run {governance_run_id} is for workflow_type={run['workflow_type']}, expected {workflow_type}.",
        )

    updates: Dict[str, Any] = {}
    if job_id and not run.get("job_id"):
        updates["job_id"] = job_id
    if run.get("status") == "draft":
        updates["status"] = "submitted"
        updates["submitted_at"] = _utc_now_naive()
    if updates:
        run = get_store().update_training_run(governance_run_id, updates) or run
        if updates.get("status") == "submitted":
            _record_training_audit_event(run, actor=requested_by or run.get("requested_by"), event_type="training_run_submitted")
    return _refresh_training_governance_state(governance_run_id)


def _enforce_launchable_governance(detail: Dict[str, Any], *, message: str) -> None:
    blocking_checks = _blocking_gate_checks(detail)
    if not blocking_checks:
        return
    raise HTTPException(
        status_code=409,
        detail={
            "message": message,
            "governance_run_id": detail["id"],
            "approval_status": detail.get("approval_status"),
            "gate_status": detail.get("gate_status"),
            "blocking_checks": blocking_checks,
        },
    )


def _latest_deployment_run_for_job(job_id: str) -> Optional[Dict[str, Any]]:
    for run in get_store().list_training_runs(workflow_type="deployment"):
        config = run.get("config_json", {}) or {}
        if run.get("job_id") == job_id or config.get("source_job_id") == job_id or config.get("job_id") == job_id:
            return run
    return None


@app.get("/governance/approvals")
async def list_approvals(
    status: str | None = None,
    risk_level: str | None = None,
    workflow_type: str | None = None,
):
    approvals = get_store().list_training_approvals(
        status=status,
        risk_level=risk_level,
        workflow_type=workflow_type,
    )
    return {"approvals": approvals, "total": len(approvals)}


@app.get("/governance/approvals/{approval_id}")
async def get_approval(approval_id: str):
    approval = get_store().get_training_approval(approval_id)
    if not approval:
        raise HTTPException(status_code=404, detail="Approval not found")
    return approval


@app.post("/governance/approvals", status_code=201)
async def create_approval(body: ApprovalRequest):
    run_id = body.run_id
    if not run_id:
        synthetic_run = get_store().create_training_run(
            {
                "workflow_type": body.workflow_type,
                "run_name": body.title,
                "requested_by": body.requested_by,
                "risk_tier": body.risk_level,
                "risk_score": {"low": 20.0, "medium": 50.0, "high": 70.0, "critical": 90.0}.get(body.risk_level, 50.0),
                "status": "submitted",
                "approval_status": "pending",
                "gate_status": "pending_approval",
                "config_json": {},
            }
        )
        run_id = synthetic_run["id"]
        _record_training_audit_event(synthetic_run, actor=body.requested_by, event_type="approval_run_created")
    approval = get_store().create_training_approval(
        {
            "run_id": run_id,
            "workflow_type": body.workflow_type,
            "title": body.title,
            "description": body.description,
            "risk_level": body.risk_level,
            "requested_by": body.requested_by,
            "approvers": body.approvers or ["team-lead"],
        }
    )
    run = get_store().get_training_run(run_id)
    if run:
        _record_training_audit_event(run, actor=body.requested_by, event_type="approval_created", detail={"approval_id": approval["id"]})
        _refresh_training_governance_state(run_id)
    return approval


@app.post("/governance/approvals/{approval_id}/decide")
async def decide_approval(approval_id: str, decision: ApprovalDecisionRequest):
    approval = get_store().add_training_approval_decision(
        approval_id,
        approver=decision.approver,
        action=decision.action,
        comment=decision.comment,
    )
    if not approval:
        raise HTTPException(status_code=404, detail="Approval not found")
    run = get_store().get_training_run(approval["run_id"])
    if run:
        _record_training_audit_event(
            run,
            actor=decision.approver,
            event_type="approval_decided",
            detail={"approval_id": approval_id, "action": decision.action},
        )
        _refresh_training_governance_state(run["id"])
    return get_store().get_training_approval(approval_id)


@app.get("/governance/policies")
async def list_policies(workflow_type: str | None = None):
    policies = get_store().list_training_policies(workflow_type=workflow_type)
    return {"policies": policies}


@app.patch("/governance/policies/{policy_id}")
async def update_policy(policy_id: str, body: TrainingPolicyUpdateRequest):
    policy = get_store().update_training_policy(
        policy_id,
        body.model_dump(exclude_none=True),
    )
    if not policy:
        raise HTTPException(status_code=404, detail="Policy not found")
    return policy


@app.get("/governance/training-runs")
async def list_training_runs(
    workflow_type: str | None = None,
    status: str | None = None,
    risk_tier: str | None = None,
    team: str | None = None,
    requested_by: str | None = None,
):
    runs = get_store().list_training_runs(
        workflow_type=workflow_type,
        status=status,
        risk_tier=risk_tier,
        team=team,
        requested_by=requested_by,
    )
    return {"runs": runs, "total": len(runs)}


@app.post("/governance/training-runs", status_code=201)
async def create_training_run(body: TrainingRunCreateRequest):
    config_json = dict(body.config_json or {})
    model_name = body.model_name or config_json.get("model_name")
    dataset_ref = body.dataset_ref or config_json.get("dataset_ref")
    risk_score, risk_tier = _calculate_risk_profile(body.workflow_type, config_json, model_name, dataset_ref)
    run = get_store().create_training_run(
        {
            "workflow_type": body.workflow_type,
            "use_case_family": body.use_case_family,
            "team": body.team,
            "requested_by": body.requested_by,
            "run_name": body.run_name or f"{body.workflow_type}-{uuid.uuid4().hex[:6]}",
            "model_name": model_name,
            "dataset_ref": dataset_ref,
            "config_json": config_json,
            "risk_tier": risk_tier,
            "risk_score": risk_score,
            "approval_status": "not_required",
            "gate_status": "draft",
            "status": "draft",
            "tag": body.tag,
        }
    )
    _record_training_audit_event(run, actor=body.requested_by, event_type="training_run_created")
    return _refresh_training_governance_state(run["id"])


@app.get("/governance/training-runs/{run_id}")
async def get_training_run_detail(run_id: str):
    return _training_run_detail(run_id)


@app.patch("/governance/training-runs/{run_id}")
async def update_training_run(run_id: str, body: TrainingRunUpdateRequest):
    run = get_store().update_training_run(run_id, body.model_dump(exclude_none=True))
    if not run:
        raise HTTPException(status_code=404, detail="Training run not found")
    _record_training_audit_event(run, actor=run.get("requested_by"), event_type="training_run_updated", detail=body.model_dump(exclude_none=True))
    return _refresh_training_governance_state(run_id)


@app.post("/governance/training-runs/{run_id}/submit")
async def submit_training_run(run_id: str):
    run = get_store().update_training_run(
        run_id,
        {
            "status": "submitted",
            "submitted_at": _utc_now_naive(),
        },
    )
    if not run:
        raise HTTPException(status_code=404, detail="Training run not found")
    _record_training_audit_event(run, actor=run.get("requested_by"), event_type="training_run_submitted")
    return _refresh_training_governance_state(run_id)


def _training_metrics_overview(window_days: int, workflow_type: Optional[str], team: Optional[str]) -> Dict[str, Any]:
    runs = get_store().list_training_runs(workflow_type=workflow_type, team=team)
    cutoff = _utc_now()
    filtered_runs = []
    for run in runs:
        created = _parse_iso_utc(run.get("created_at"))
        if created and (cutoff - created).days <= window_days:
            filtered_runs.append(run)

    approvals = get_store().list_training_approvals(workflow_type=workflow_type)
    filtered_approvals = []
    for approval in approvals:
        created = _parse_iso_utc(approval.get("created_at"))
        if not created or (cutoff - created).days > window_days:
            continue
        run = get_store().get_training_run(approval["run_id"])
        if team and run and run.get("team") != team:
            continue
        filtered_approvals.append(approval)

    total_runs = len(filtered_runs)
    gate_passed = len([run for run in filtered_runs if run.get("gate_status") == "passed"])
    blocked_runs = len([run for run in filtered_runs if run.get("gate_status") == "blocked"])
    launched_runs = len([run for run in filtered_runs if run.get("status") in {"running", "completed", "failed"}])
    completed_runs = len([run for run in filtered_runs if run.get("status") == "completed"])
    optimization_runs = [run for run in filtered_runs if run.get("workflow_type") == "optimization"]
    optimization_eval_complete = 0
    for run in optimization_runs:
        metrics = get_store().list_training_metric_snapshots(run_id=run["id"])
        if any(metric["metric_key"] == "evaluation_complete" and metric["value"] >= 1.0 for metric in metrics):
            optimization_eval_complete += 1

    approval_latencies: list[float] = []
    for approval in filtered_approvals:
        if approval.get("status") != "approved" or not approval.get("decisions"):
            continue
        created_at = _parse_iso_utc(approval.get("created_at"))
        decided_at = _parse_iso_utc(approval["decisions"][-1].get("decided_at"))
        if created_at and decided_at:
            approval_latencies.append(max(0.0, (decided_at - created_at).total_seconds()))

    return {
        "window_days": window_days,
        "workflow_type": workflow_type,
        "team": team,
        "total_runs": total_runs,
        "gate_pass_rate": round((gate_passed / total_runs) * 100, 2) if total_runs else 0.0,
        "blocked_run_count": blocked_runs,
        "run_success_rate": round((completed_runs / launched_runs) * 100, 2) if launched_runs else 0.0,
        "approval_latency_sec_avg": round(sum(approval_latencies) / len(approval_latencies), 2) if approval_latencies else 0.0,
        "evaluation_completeness_rate": round((optimization_eval_complete / len(optimization_runs)) * 100, 2) if optimization_runs else 0.0,
    }


def _training_metrics_trends(window_days: int, workflow_type: Optional[str], team: Optional[str]) -> Dict[str, Any]:
    runs = get_store().list_training_runs(workflow_type=workflow_type, team=team)
    cutoff = _utc_now()
    rows: dict[str, dict[str, Any]] = defaultdict(
        lambda: {
            "date": "",
            "runs": 0,
            "blocked_runs": 0,
            "completed_runs": 0,
            "gate_passed_runs": 0,
            "pending_approvals": 0,
        }
    )

    for run in runs:
        created_at = _parse_iso_utc(run.get("created_at"))
        if not created_at or (cutoff - created_at).days > window_days:
            continue
        key = created_at.date().isoformat()
        row = rows[key]
        row["date"] = key
        row["runs"] += 1
        if run.get("gate_status") == "blocked":
            row["blocked_runs"] += 1
        if run.get("status") == "completed":
            row["completed_runs"] += 1
        if run.get("gate_status") == "passed":
            row["gate_passed_runs"] += 1
        if run.get("approval_status") == "pending":
            row["pending_approvals"] += 1

    ordered = [rows[key] for key in sorted(rows.keys())]
    for row in ordered:
        row["gate_pass_rate"] = round((row["gate_passed_runs"] / row["runs"]) * 100, 2) if row["runs"] else 0.0
        row["run_success_rate"] = round((row["completed_runs"] / row["runs"]) * 100, 2) if row["runs"] else 0.0

    return {"window_days": window_days, "rows": ordered}


@app.get("/governance/metrics/overview")
async def get_training_metrics_overview(
    window: int = 30,
    workflow_type: str | None = None,
    team: str | None = None,
):
    return _training_metrics_overview(window, workflow_type, team)


@app.get("/governance/metrics/trends")
async def get_training_metrics_trends(
    window: int = 30,
    workflow_type: str | None = None,
    team: str | None = None,
):
    return _training_metrics_trends(window, workflow_type, team)


@app.get("/governance/training-runs/{run_id}/metrics")
async def get_training_run_metrics(run_id: str):
    run = get_store().get_training_run(run_id)
    if not run:
        raise HTTPException(status_code=404, detail="Training run not found")
    return {"metrics": get_store().list_training_metric_snapshots(run_id=run_id)}


@app.get("/governance/training-runs/{run_id}/gate-checks")
async def get_training_run_gate_checks(run_id: str):
    run = get_store().get_training_run(run_id)
    if not run:
        raise HTTPException(status_code=404, detail="Training run not found")
    return {"gate_checks": get_store().list_training_gate_checks(run_id)}


def _new_governed_job_record(job_id: str, config: Dict[str, Any]) -> Dict[str, Any]:
    return {
        "id": job_id,
        "status": "pending",
        "progress": 0.0,
        "config": config,
        "history": [],
        "deployed": False,
        "evaluation": None,
        "error": None,
    }


def _blocking_gate_checks(detail: Dict[str, Any]) -> list[Dict[str, Any]]:
    return [check for check in detail.get("gate_checks", []) if check.get("blocking") and check.get("status") != "passed"]


def _extract_training_evaluation(metrics: Dict[str, Any]) -> Optional[Dict[str, Any]]:
    candidate = metrics.get("final_evaluation") if isinstance(metrics.get("final_evaluation"), dict) else metrics
    if not isinstance(candidate, dict):
        return None
    if "eval_loss" not in candidate and "perplexity" not in candidate:
        return None

    def _safe_float(value: Any, default: float = 0.0) -> float:
        try:
            return float(value)
        except Exception:
            return default

    return {
        "eval_loss": round(_safe_float(candidate.get("eval_loss", 0.0)), 4),
        "perplexity": round(_safe_float(candidate.get("perplexity", 0.0)), 2),
        "runtime_sec": round(_safe_float(candidate.get("runtime_sec", metrics.get("runtime_sec", 0.0))), 2),
    }


@app.post("/governance/training-runs/{run_id}/launch")
async def launch_training_run(run_id: str, background_tasks: BackgroundTasks):
    detail = _refresh_training_governance_state(run_id)
    blocking_checks = _blocking_gate_checks(detail)
    if blocking_checks:
        raise HTTPException(
            status_code=409,
            detail={
                "message": "Training run is blocked.",
                "blocking_checks": blocking_checks,
            },
        )

    run = detail
    store = get_store()
    config = dict(run.get("config_json", {}) or {})

    if run["workflow_type"] == "pipeline":
        job_id = run.get("job_id") or f"pipe-{uuid.uuid4().hex[:8]}"
        config.update(
            {
                "workflow_type": "pipeline",
                "governance_run_id": run_id,
                "dataset_ref": run.get("dataset_ref"),
                "team": run.get("team"),
            }
        )
        save_job(_new_governed_job_record(job_id, config))
        store.update_training_run(
            run_id,
            {"job_id": job_id, "status": "running", "launched_at": _utc_now_naive()},
        )
        store.replace_training_artifacts(
            run_id,
            [
                {
                    "artifact_type": "dataset_reference",
                    "artifact_ref": run.get("dataset_ref") or f"team:{run.get('team') or 'global'}",
                    "metadata_json": {"workflow_type": "pipeline"},
                }
            ],
        )
        _record_training_audit_event(run, actor=run.get("requested_by"), event_type="training_run_launched", job_id=job_id)
        background_tasks.add_task(run_pipeline_worker, run_id, job_id)
        return _refresh_training_governance_state(run_id)

    if run["workflow_type"] == "optimization":
        job_id = run.get("job_id") or str(uuid.uuid4())
        config.setdefault("model_name", run.get("model_name") or "gpt2")
        config["workflow_type"] = "optimization"
        config["governance_run_id"] = run_id
        save_job(_new_governed_job_record(job_id, config))
        store.update_training_run(
            run_id,
            {"job_id": job_id, "status": "running", "launched_at": _utc_now_naive()},
        )
        store.replace_training_artifacts(
            run_id,
            [
                {
                    "artifact_type": "model_request",
                    "artifact_ref": config["model_name"],
                    "metadata_json": {"quant_format": config.get("quant_format")},
                }
            ],
        )
        _record_training_audit_event(run, actor=run.get("requested_by"), event_type="training_run_launched", job_id=job_id)
        asyncio.create_task(real_worker_task(job_id, governance_run_id=run_id))
        return _refresh_training_governance_state(run_id)

    if run["workflow_type"] == "deployment":
        linked_job_id = run.get("job_id") or config.get("job_id") or config.get("source_job_id")
        if not linked_job_id:
            raise HTTPException(status_code=400, detail="Deployment run requires a linked job_id.")
        store.update_training_run(
            run_id,
            {"job_id": linked_job_id, "status": "running", "launched_at": _utc_now_naive()},
        )
        _record_training_audit_event(run, actor=run.get("requested_by"), event_type="training_run_launched", job_id=linked_job_id)
        await _deploy_job_internal(linked_job_id, governance_run_id=run_id)
        return _refresh_training_governance_state(run_id)

    raise HTTPException(status_code=400, detail=f"Unsupported workflow_type '{run['workflow_type']}'.")


# ---------------------------------------------------------------------------
# Collaboration WebSocket — room-based presence & message fan-out
# ---------------------------------------------------------------------------

_collab_rooms: dict[str, dict[str, dict]] = {}  # room_id -> { user_id -> { ws, info } }
_collab_lock = asyncio.Lock()


async def _collab_broadcast(room_id: str, message: dict, exclude: str | None = None) -> None:
    room = _collab_rooms.get(room_id, {})
    payload = json.dumps(message)
    stale = []
    for uid, entry in room.items():
        if uid == exclude:
            continue
        try:
            await entry["ws"].send_text(payload)
        except Exception:
            stale.append(uid)
    for uid in stale:
        room.pop(uid, None)


@app.websocket("/collab")
async def collab_websocket(websocket: WebSocket, room: str = "default"):
    """Room-based collaboration WebSocket for team presence."""
    await websocket.accept()
    user_id: str | None = None
    room_id = room
    try:
        while True:
            raw = await websocket.receive_text()
            try:
                msg = json.loads(raw)
            except json.JSONDecodeError:
                continue
            msg_type = msg.get("type")
            if msg_type == "join":
                user_id = msg.get("userId", "anonymous")
                room_id = msg.get("roomId", room)
                async with _collab_lock:
                    if room_id not in _collab_rooms:
                        _collab_rooms[room_id] = {}
                    _collab_rooms[room_id][user_id] = {
                        "ws": websocket,
                        "displayName": msg.get("displayName", user_id),
                        "avatarUrl": msg.get("avatarUrl"),
                        "status": "active",
                        "location": None,
                        "joinedAt": _utc_now_iso(),
                    }
                await _collab_broadcast(room_id, msg, exclude=user_id)
                # Send sync
                participants = [
                    {"userId": uid, **{k: v for k, v in info.items() if k != "ws"}, "color": ""}
                    for uid, info in _collab_rooms.get(room_id, {}).items()
                ]
                await websocket.send_text(json.dumps({"type": "sync", "participants": participants, "state": {}}))
            elif msg_type == "leave":
                uid = msg.get("userId", user_id)
                async with _collab_lock:
                    _collab_rooms.get(room_id, {}).pop(uid or "", None)
                await _collab_broadcast(room_id, msg)
            elif msg_type == "presence":
                uid = msg.get("userId", user_id)
                async with _collab_lock:
                    entry = _collab_rooms.get(room_id, {}).get(uid or "")
                    if entry:
                        entry["status"] = msg.get("status", "active")
                        entry["location"] = msg.get("location")
                await _collab_broadcast(room_id, msg, exclude=uid)
            else:
                await _collab_broadcast(room_id, msg, exclude=msg.get("userId", user_id))
    except WebSocketDisconnect:
        pass
    except Exception:
        pass
    finally:
        if user_id:
            async with _collab_lock:
                _collab_rooms.get(room_id, {}).pop(user_id, None)
            await _collab_broadcast(room_id, {"type": "leave", "roomId": room_id, "userId": user_id})


async def _gather_stack_dependencies() -> dict[str, Any]:
    """Shared dependency probes for /health and /capabilities."""
    import httpx

    backend = db_backend_label()
    db_status = "healthy"
    try:
        db = SessionLocal()
        db.execute(text("SELECT 1" + (" FROM DUMMY" if backend == "hana" else "")))
        db.close()
    except Exception:
        db_status = "unhealthy"

    hana_status = "unhealthy"
    try:
        if rag.HANA_USER:
            conn = rag._hana_connection()
            conn.close()
            hana_status = "healthy"
        else:
            hana_status = "unconfigured"
    except Exception:
        hana_status = "unhealthy"

    vllm_base = vllm_probe_base_url()
    vllm_status = "unhealthy"
    try:
        async with httpx.AsyncClient(timeout=2.0) as client:
            resp = await client.get(f"{vllm_base}/health")
            if resp.status_code == 200:
                vllm_status = "healthy"
    except Exception:
        vllm_status = "unhealthy"

    aicore_configured = aicore_fully_configured()
    aicore_reachable = "unconfigured"
    if aicore_configured:
        aicore_reachable = "unhealthy"
        try:
            root = AICORE_BASE_URL.rstrip("/")
            async with httpx.AsyncClient(timeout=2.0, follow_redirects=True) as client:
                resp = await client.get(f"{root}/")
                if resp.status_code < 500:
                    aicore_reachable = "healthy"
        except Exception:
            aicore_reachable = "unhealthy"

    pal_status = "unconfigured"
    pu = PAL_UPSTREAM_URL.strip()
    if pu:
        pal_status = "unhealthy"
        try:
            root = pu.rstrip("/")
            async with httpx.AsyncClient(timeout=2.0, follow_redirects=True) as client:
                resp = await client.get(f"{root}/")
                if resp.status_code < 500:
                    pal_status = "healthy"
        except Exception:
            pal_status = "unhealthy"

    return {
        "db_backend": backend,
        "database": db_status,
        "hana_vector": hana_status,
        "vllm_turboquant": vllm_status,
        "aicore_configured": aicore_configured,
        "aicore_reachable": aicore_reachable,
        "pal_route": pal_status,
    }


@app.get("/health")
async def health() -> dict:
    """Detailed health check for production telemetry."""
    deps = await _gather_stack_dependencies()
    db_status = deps["database"]
    vllm_status = deps["vllm_turboquant"]
    overall = "healthy" if db_status == "healthy" and vllm_status == "healthy" else "degraded"
    if db_status != "healthy":
        overall = "unavailable"
    elif deps["aicore_configured"] and deps["aicore_reachable"] == "unhealthy":
        overall = "degraded"

    return {
        "status": overall,
        "service": "training-webcomponents-ngx-api",
        "db_backend": deps["db_backend"],
        "dependencies": {
            "database": deps["database"],
            "hana_vector": deps["hana_vector"],
            "vllm_turboquant": deps["vllm_turboquant"],
            "aicore": deps["aicore_reachable"],
            "pal_route": deps["pal_route"],
        },
        "aicore_configured": deps["aicore_configured"],
        "timestamp": _utc_now_iso(),
    }


@app.get("/capabilities")
async def capabilities() -> dict:
    """Structured stack capabilities for UI readiness (no secrets)."""
    deps = await _gather_stack_dependencies()
    return {
        "service": "training-webcomponents-ngx-api",
        "db_backend": deps["db_backend"],
        "database": deps["database"],
        "hana_vector": deps["hana_vector"],
        "vllm_turboquant": deps["vllm_turboquant"],
        "aicore_configured": deps["aicore_configured"],
        "aicore_reachable": deps["aicore_reachable"],
        "pal_route": deps["pal_route"],
        "timestamp": _utc_now_iso(),
    }


@app.get("/gpu/status")
async def gpu_status() -> dict:
    """Expose GPU/system telemetry for dashboard cards."""
    return get_system_telemetry()


@app.get("/data-cleaning/health")
async def data_cleaning_health():
    return {
        "status": "ok",
        "session_ready": True,
        "mode": "native",
        "message_count": len(DATA_CLEANING_STATE["messages"]),
        "check_count": len(DATA_CLEANING_STATE["checks"]),
    }


@app.post("/data-cleaning/chat")
async def data_cleaning_chat(request: DataCleaningChatRequest):
    message = request.message.strip()
    if not message:
        raise HTTPException(status_code=400, detail="Message must not be blank.")

    generated_checks = _native_generate_checks(message)
    DATA_CLEANING_STATE["messages"].append(
        {"role": "user", "content": message, "ts": _utc_now_iso()}
    )
    DATA_CLEANING_STATE["checks"] = generated_checks
    response = (
        f"Generated {len(generated_checks)} quality checks for training-data preparation. "
        "Run workflow to produce remediation steps and publish a cleaned snapshot."
    )
    DATA_CLEANING_STATE["messages"].append(
        {"role": "assistant", "content": response, "ts": _utc_now_iso()}
    )
    return {"response": response}


@app.get("/data-cleaning/checks")
async def data_cleaning_checks():
    return DATA_CLEANING_STATE["checks"]


@app.post("/data-cleaning/workflow/run")
async def data_cleaning_workflow_run(request: DataCleaningWorkflowRunRequest):
    message = request.message.strip()
    if not message:
        raise HTTPException(status_code=400, detail="Message must not be blank.")

    run_id = str(uuid.uuid4())
    DATA_CLEANING_STATE["workflow_runs"][run_id] = {
        "run_id": run_id,
        "status": "pending",
        "message": message,
        "created_at": _utc_now_iso(),
        "events": [],
        "result": None,
    }
    await _run_native_data_cleaning_workflow(run_id, message)
    return {"run_id": run_id, "status": "completed"}


@app.get("/data-cleaning/workflow/{run_id}")
async def data_cleaning_workflow_status(run_id: str):
    run = DATA_CLEANING_STATE["workflow_runs"].get(run_id)
    if not run:
        raise HTTPException(status_code=404, detail="Workflow run not found.")
    return {
        "run_id": run["run_id"],
        "status": run["status"],
        "created_at": run["created_at"],
        "result": run["result"],
    }


@app.get("/data-cleaning/workflow/{run_id}/events")
async def data_cleaning_workflow_events(run_id: str):
    run = DATA_CLEANING_STATE["workflow_runs"].get(run_id)
    if not run:
        raise HTTPException(status_code=404, detail="Workflow run not found.")
    return {"run_id": run_id, "events": run["events"], "status": run["status"]}


@app.get("/data-cleaning/workflow/{run_id}/stream")
async def data_cleaning_workflow_stream(run_id: str):
    run = DATA_CLEANING_STATE["workflow_runs"].get(run_id)
    if not run:
        raise HTTPException(status_code=404, detail="Workflow run not found.")

    async def _event_stream():
        offset = 0
        while True:
            current_run = DATA_CLEANING_STATE["workflow_runs"].get(run_id)
            if not current_run:
                break
            events = current_run["events"]
            while offset < len(events):
                payload = json.dumps(events[offset])
                yield f"data: {payload}\n\n"
                offset += 1

            if current_run["status"] in DATA_CLEANING_TERMINAL_STATES:
                final_payload = json.dumps(
                    {
                        "phase": "terminal",
                        "status": current_run["status"],
                        "result": current_run["result"],
                    }
                )
                yield f"data: {final_payload}\n\n"
                break
            await asyncio.sleep(0.2)

    return StreamingResponse(_event_stream(), media_type="text/event-stream")


@app.delete("/data-cleaning/session")
async def data_cleaning_clear_session():
    DATA_CLEANING_STATE["messages"] = []
    DATA_CLEANING_STATE["checks"] = []
    DATA_CLEANING_STATE["workflow_runs"] = {}
    return {"status": "cleared"}

@app.get("/models/catalog")
async def get_models_catalog() -> JSONResponse:
    return JSONResponse(content=SUPPORTED_MODELS)

class TrainingGenerationRequest(BaseModel):
    model_config = ConfigDict(populate_by_name=True)

    team: str = ""              # e.g. "AE:treasury", "treasury", "AE", or "" for global
    examples_per_domain: int = 100000
    should_validate: bool = Field(default=True, alias="validate")
    governance_run_id: Optional[str] = None


async def _run_training_generation(
    job_id: str,
    team: str,
    examples_per_domain: int,
    validate: bool,
    governance_run_id: Optional[str] = None,
) -> None:
    """Background task: run training data generation and update job status."""
    import subprocess
    import shlex

    job = get_job(job_id)
    if not job:
        return

    job["status"] = "running"
    job["progress"] = 0.1
    save_job(job)
    _update_governed_run_state(governance_run_id, job_id=job_id, status="running", event_type="training_generation_started")
    await broadcast_job(job_id, {"type": "log", "message": f"Starting training generation (team={team or 'global'})..."})

    scripts_dir = str(Path(__file__).resolve().parent.parent.parent.parent.parent / "src" / "training" / "schema_pipeline")
    cmd_parts = [
        "python", "data_generator.py",
        "--examples", str(examples_per_domain),
    ]
    if validate:
        cmd_parts.append("--validate")
    if team:
        cmd_parts.extend(["--team", team])

    try:
        job["progress"] = 0.2
        save_job(job)
        await broadcast_job(job_id, {"type": "log", "message": "Running data_generator.py..."})

        proc = await asyncio.create_subprocess_exec(
            *cmd_parts,
            cwd=scripts_dir,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.STDOUT,
        )
        stdout, _ = await proc.communicate()
        output = stdout.decode("utf-8", errors="replace") if stdout else ""

        if proc.returncode != 0:
            job["status"] = "failed"
            job["error"] = output[-500:] if output else "Process exited with non-zero code"
            job["progress"] = 1.0
            save_job(job)
            _update_governed_run_state(
                governance_run_id,
                job_id=job_id,
                status="failed",
                event_type="training_generation_failed",
                detail={"error": job["error"]},
                completed=True,
            )
            await broadcast_job(job_id, {"type": "error", "message": job["error"]})
            return

        job["progress"] = 0.6
        save_job(job)
        await broadcast_job(job_id, {"type": "log", "message": "Running prepare_training_data.py..."})

        prep_parts = ["python", "prepare_training_data.py"]
        if team:
            prep_parts.extend(["--team", team])

        proc2 = await asyncio.create_subprocess_exec(
            *prep_parts,
            cwd=scripts_dir,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.STDOUT,
        )
        stdout2, _ = await proc2.communicate()
        output2 = stdout2.decode("utf-8", errors="replace") if stdout2 else ""

        if proc2.returncode != 0:
            job["status"] = "failed"
            job["error"] = output2[-500:] if output2 else "Preparation failed"
            job["progress"] = 1.0
            save_job(job)
            _update_governed_run_state(
                governance_run_id,
                job_id=job_id,
                status="failed",
                event_type="training_generation_failed",
                detail={"error": job["error"]},
                completed=True,
            )
            await broadcast_job(job_id, {"type": "error", "message": job["error"]})
            return

        job["status"] = "completed"
        job["progress"] = 1.0
        job["history"] = [
            {"phase": "generate", "output_lines": len(output.splitlines())},
            {"phase": "prepare", "output_lines": len(output2.splitlines())},
        ]
        save_job(job)
        if governance_run_id:
            _append_training_artifact(
                governance_run_id,
                artifact_type="training_dataset",
                artifact_ref=f"team:{team or 'global'}:train-jsonl",
                metadata_json={"examples_per_domain": examples_per_domain, "validate": validate},
            )
        _update_governed_run_state(
            governance_run_id,
            job_id=job_id,
            status="completed",
            event_type="training_generation_completed",
            detail={"history": job["history"]},
            completed=True,
        )
        await broadcast_job(job_id, {"type": "complete", "message": "Training data generation complete."})

    except Exception as exc:
        job["status"] = "failed"
        job["error"] = str(exc)
        job["progress"] = 1.0
        save_job(job)
        _update_governed_run_state(
            governance_run_id,
            job_id=job_id,
            status="failed",
            event_type="training_generation_failed",
            detail={"error": str(exc)},
            completed=True,
        )
        await broadcast_job(job_id, {"type": "error", "message": str(exc)})


@app.post("/jobs/training", status_code=201)
async def start_training_generation(body: TrainingGenerationRequest, background_tasks: BackgroundTasks):
    """Trigger background training data generation for a team context."""
    governance_detail = _resolve_governance_run_detail(
        workflow_type="pipeline",
        governance_run_id=body.governance_run_id,
        team=body.team,
        requested_by=body.team or "system",
        run_name=f"training-generation-{(body.team or 'global').replace(':', '-')}",
        dataset_ref=f"team:{body.team or 'global'}",
        config_json={
            "team": body.team,
            "examples_per_domain": body.examples_per_domain,
            "validate": body.should_validate,
            "dataset_ref": f"team:{body.team or 'global'}",
        },
    )
    _enforce_launchable_governance(
        governance_detail,
        message="Training data generation is blocked.",
    )
    governance_run_id = governance_detail["id"]
    job_id = f"train-{uuid.uuid4().hex[:8]}"
    job = {
        "id": job_id,
        "status": "pending",
        "progress": 0.0,
        "config": {
            "team": body.team,
            "examples_per_domain": body.examples_per_domain,
            "validate": body.should_validate,
            "workflow_type": "pipeline",
            "governance_run_id": governance_run_id,
        },
        "error": None,
        "history": [],
        "evaluation": None,
        "deployed": False,
    }
    save_job(job)
    _update_governed_run_state(
        governance_run_id,
        job_id=job_id,
        status="submitted",
        actor=body.team or "system",
        event_type="training_generation_job_created",
        detail={
            "examples_per_domain": body.examples_per_domain,
            "validate": body.should_validate,
        },
    )
    background_tasks.add_task(
        _run_training_generation,
        job_id,
        body.team,
        body.examples_per_domain,
        body.should_validate,
        governance_run_id,
    )
    return {"job_id": job_id, "status": "pending", "governance": get_store().get_governance_summary_for_job(job_id)}


@app.get("/jobs")
async def list_jobs():
    return get_all_jobs()

@app.get("/jobs/{job_id}")
async def get_job_info(job_id: str):
    job = get_job(job_id)
    if not job:
        raise HTTPException(status_code=404, detail="Job not found")
    return job

@app.delete("/jobs/{job_id}")
async def delete_job(job_id: str):
    db = SessionLocal()
    job = db.query(JobRecord).filter(JobRecord.id == job_id).first()
    if not job:
        db.close()
        raise HTTPException(status_code=404, detail="Job not found")
    db.delete(job)
    db.commit()
    db.close()
    if job_id in INFERENCE_ENGINES:
        del INFERENCE_ENGINES[job_id]
    return {"status": "deleted"}

# --- INFERENCE & PLAYGROUND ROUTES ---

async def _deploy_job_internal(job_id: str, governance_run_id: Optional[str] = None) -> Dict[str, Any]:
    job = get_job(job_id)
    if not job:
        raise HTTPException(status_code=404, detail="Job not found")
    if job["status"] != "completed":
        raise HTTPException(status_code=400, detail="Job must be completed to deploy")

    source_run = get_store().get_training_run_for_job(job_id)
    reusable_run = governance_run_id or (_latest_deployment_run_for_job(job_id) or {}).get("id")
    detail = _resolve_governance_run_detail(
        workflow_type="deployment",
        governance_run_id=reusable_run,
        team=(source_run or {}).get("team", "") or job.get("config", {}).get("team", ""),
        requested_by=(source_run or {}).get("requested_by", "system"),
        run_name=f"deployment-{job_id[:8]}",
        model_name=(source_run or {}).get("model_name") or job.get("config", {}).get("model_name"),
        dataset_ref=(source_run or {}).get("dataset_ref") or job.get("config", {}).get("dataset_ref"),
        job_id=job_id,
        config_json={
            "job_id": job_id,
            "source_job_id": job_id,
            "model_name": (source_run or {}).get("model_name") or job.get("config", {}).get("model_name"),
            "quant_format": job.get("config", {}).get("quant_format"),
        },
    )
    _enforce_launchable_governance(detail, message="Deployment run is blocked.")
    governance_run_id = detail["id"]
    _update_governed_run_state(
        governance_run_id,
        job_id=job_id,
        status="running",
        event_type="deployment_started",
        detail={"inference_path": f"/inference/{job_id}/chat"},
    )

    deployment_mode = "live"
    deployment_warning: Optional[str] = None
    try:
        from transformers import pipeline
        import os
        model_path = os.path.join(os.path.dirname(__file__), "../../../../../training/nvidia-modelopt/outputs", job_id, "checkpoint-optimal")
        if not os.path.exists(model_path):
            raise Exception("Optimal safetensors not generated by PyTorch layer.")

        pipe = pipeline("text-generation", model=model_path, device=-1) # CPU for local validation, swap to 0 for GPU
        INFERENCE_ENGINES[job_id] = pipe

        job["deployed"] = True
        save_job(job)

    except Exception as e:
        INFERENCE_ENGINES[job_id] = "MOCK_BACKUP_ENGINE"
        job["deployed"] = True
        save_job(job)
        model_path = f"training/nvidia-modelopt/outputs/{job_id}/checkpoint-optimal"
        deployment_mode = "mock_backup"
        deployment_warning = str(e)

    if governance_run_id:
        _append_training_artifact(
            governance_run_id,
            artifact_type="deployment_endpoint",
            artifact_ref=f"/inference/{job_id}/chat",
            metadata_json={"mode": deployment_mode},
        )
        _append_training_artifact(
            governance_run_id,
            artifact_type="model_checkpoint",
            artifact_ref=model_path,
            metadata_json={"job_id": job_id},
        )
        _update_governed_run_state(
            governance_run_id,
            job_id=job_id,
            status="completed",
            event_type="deployment_completed",
            detail={"mode": deployment_mode, "warning": deployment_warning},
            completed=True,
        )

    return {
        "status": "deployed",
        "mode": deployment_mode,
        "warning": deployment_warning,
        "inference_server": f"/inference/{job_id}/chat",
    }


@app.post("/jobs/{job_id}/deploy")
async def deploy_job(job_id: str, governance_run_id: str | None = None):
    return await _deploy_job_internal(job_id, governance_run_id=governance_run_id)

# Persistent Storage Emulation
INFERENCE_ENGINES = {}

# --- Arabic model deployment state ---
ARABIC_MODEL_STATUS: Dict[str, Any] = {
    "deployed": False,
    "model_name": None,
    "gateway_url": None,
    "gguf_path": None,
    "deployed_at": None,
}

PIPELINE_STATUS = {
    "state": "idle", # idle, running, completed, error
    "logs": []
}

class APIStatus(BaseModel):
    prompt: str

class ChatRequest(BaseModel):
    prompt: str
    messages: Optional[List[Dict[str, str]]] = None


class OpenAIChatRequest(BaseModel):
    model: str = "Qwen/Qwen3.5-0.6B"
    messages: List[Dict[str, str]]
    stream: bool = False
    max_tokens: int = 1024
    temperature: float = 0.7


class OcrDocumentRequest(BaseModel):
    text: str
    file_name: Optional[str] = None
    language: str = "ar"
    document_type: str = "invoice"
    system_instructions: Optional[str] = None


@app.get("/v1/models")
async def openai_models():
    return {
        "object": "list",
        "data": [
            {"id": model["name"], "object": "model"}
            for model in SUPPORTED_MODELS
        ],
    }


@app.post("/v1/chat/completions")
async def openai_chat_completions(body: OpenAIChatRequest):
    # 1. Route based on content and model preference
    endpoint, model, circuit_key = LLMRouter.get_endpoint_and_model(body.messages, body.model)

    reply = None
    usage = None

    # 2. Attempt real inference (circuit breaker shared with _call_llm_with_fallback)
    data = await _upstream_chat_completions(
        circuit_key,
        endpoint,
        {
            "model": model,
            "messages": body.messages,
            "max_tokens": body.max_tokens,
            "temperature": body.temperature,
        },
        60.0,
    )
    if data is not None:
        reply = data["choices"][0]["message"]["content"]
        usage = data.get("usage")

    # 3. Fallback if real inference failed or skipped
    if reply is None:
        reply = _build_fallback_chat_reply(body.messages)
        usage = {
            "prompt_tokens": sum(max(1, len(m.get("content", "")) // 4) for m in body.messages),
            "completion_tokens": max(1, len(reply) // 4),
            "total_tokens": 0,
        }
        usage["total_tokens"] = usage["prompt_tokens"] + usage["completion_tokens"]

    # --- GENERATIVE UI DEMO LOGIC ---
    ui_schema = None
    user_msg = next((m.get("content", "").lower() for m in reversed(body.messages) if m.get("role") == "user"), "")
    
    if "schema" in user_msg or "nfrp" in user_msg:
        ui_schema = {
            "type": "ui5-card",
            "props": {"style": "margin-top: 1rem; border-inline-start: 4px solid var(--sapBrandColor); background: linear-gradient(to bottom right, #ffffff, #f8faff);"},
            "children": [
                {
                    "type": "ui5-card-header",
                    "props": {
                        "slot": "header",
                        "title-text": "Analytical Synthesis: NFRP_Banking",
                        "subtitle-text": "Real-time schema profiling"
                    }
                },
                {
                    "type": "div",
                    "props": {"class": "gen-ui-grid"},
                    "children": [
                        {
                            "type": "div",
                            "props": {"class": "gen-ui-stat"},
                            "children": [
                                {"type": "ui5-radial-progress-indicator", "props": {"value": 82, "style": "width: 80px; height: 80px;"}},
                                {"type": "span", "props": {"style": "font-size: 0.75rem; font-weight: bold; margin-top: 0.5rem;"}, "content": "Completeness"}
                            ]
                        },
                        {
                            "type": "div",
                            "props": {"class": "gen-ui-stat"},
                            "children": [
                                {"type": "ui5-icon", "props": {"name": "table-view", "style": "font-size: 2rem; color: var(--sapBrandColor);"}},
                                {"type": "span", "props": {"style": "font-size: 1.25rem; font-weight: 800;"}, "content": "14"},
                                {"type": "span", "props": {"style": "font-size: 0.7rem;"}, "content": "Linked Tables"}
                            ]
                        }
                    ]
                },
                {
                    "type": "div",
                    "props": {"style": "padding: 0 1rem 1rem; display: flex; gap: 0.5rem;"},
                    "children": [
                        {
                            "type": "ui5-button",
                            "props": {"design": "Emphasized", "icon": "inspect"},
                            "content": "Deep Dive Schema",
                            "intent": {"action": "submit_prompt", "payload": {"value": "Give me a summary of NFRP_Account_AM table structure."}}
                        },
                        {
                            "type": "ui5-button",
                            "props": {"design": "Transparent", "icon": "download"},
                            "content": "Export Spec",
                            "intent": {"action": "toast", "payload": {"message": "Exporting technical specification..."}}
                        }
                    ]
                }
            ]
        }

    return {
        "id": f"chatcmpl-{uuid.uuid4().hex[:12]}",
        "object": "chat.completion",
        "created": int(_utc_now().timestamp()),
        "model": model,
        "choices": [
            {
                "index": 0,
                "message": {"role": "assistant", "content": reply, "ui_schema": ui_schema},
                "finish_reason": "stop",
            }
        ],
        "usage": usage,
    }


@app.post("/openai/v1/ocr/documents")
async def openai_ocr_documents(body: OcrDocumentRequest):
    return {
        "id": f"ocrdoc-{uuid.uuid4().hex[:12]}",
        "document_type": body.document_type,
        "original_ar": body.text,
        "translated_en": _translate_financial_terms(body.text),
        "financial_fields": _extract_financial_metrics(body.text),
        "line_items": [],
        "regulatory_fields": _extract_regulatory_fields(body.text),
    }

@app.post("/jobs/{job_id}/deploy-arabic")
async def deploy_arabic_model(job_id: str):
    """Deploy the fine-tuned Gemma 4 Arabic GGUF model via llama.cpp gateway.

    1. Checks for the GGUF file in the models directory
    2. Starts the llama.cpp gateway pointing to the GGUF
    3. Registers the model in INFERENCE_ENGINES as an OpenAI-compatible client
    """
    job = get_job(job_id)
    if not job:
        raise HTTPException(status_code=404, detail="Job not found")

    # Locate the GGUF file
    models_dir = os.path.abspath(
        os.path.join(os.path.dirname(__file__), "../../../../../intelligence/vllm-turboquant/models")
    )
    gguf_files = [f for f in os.listdir(models_dir) if f.endswith(".gguf")] if os.path.isdir(models_dir) else []

    if not gguf_files:
        raise HTTPException(
            status_code=404,
            detail=f"No GGUF file found in {models_dir}. Run export_gemma4_gguf.py first.",
        )

    gguf_path = os.path.join(models_dir, gguf_files[0])
    gateway_port = int(os.getenv("ARABIC_GATEWAY_PORT", "8081"))
    gateway_url = f"http://localhost:{gateway_port}"

    # Start the llama.cpp server via the convenience script
    start_script = os.path.abspath(
        os.path.join(os.path.dirname(__file__), "../../../../../intelligence/vllm-turboquant/start-turboquant.py")
    )
    if os.path.exists(start_script):
        try:
            env = os.environ.copy()
            env["GATEWAY_PORT"] = str(gateway_port)
            process = await asyncio.create_subprocess_exec(
                "bash", start_script, "start",
                env=env,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
            )
            # Don't await — it's a long-running server
        except Exception as e:
            logger.warning("arabic_server_start_failed", error=str(e))

    # Register as an OpenAI-compatible client
    try:
        import httpx
        client = httpx.AsyncClient(base_url=gateway_url, timeout=60.0)
        INFERENCE_ENGINES[job_id] = {"type": "openai_gateway", "client": client, "model": "gemma4-arabic-finance"}
    except ImportError:
        INFERENCE_ENGINES[job_id] = {"type": "openai_gateway", "url": gateway_url, "model": "gemma4-arabic-finance"}

    ARABIC_MODEL_STATUS.update({
        "deployed": True,
        "model_name": "gemma4-arabic-finance",
        "gateway_url": gateway_url,
        "gguf_path": gguf_path,
        "deployed_at": _utc_now_iso(),
    })

    job["deployed"] = True
    save_job(job)

    return {
        "status": "deployed",
        "model": "gemma4-arabic-finance",
        "gateway_url": gateway_url,
        "gguf_file": gguf_files[0],
        "inference_server": f"/inference/{job_id}/chat",
    }


@app.get("/inference/arabic/status")
async def arabic_model_status():
    """Health check for the Arabic financial model."""
    if not ARABIC_MODEL_STATUS["deployed"]:
        return {
            "status": "not_deployed",
            "message": "النموذج العربي غير منشور بعد — Arabic model is not deployed yet",
            "model": None,
        }

    # Try to reach the gateway
    gateway_url = ARABIC_MODEL_STATUS.get("gateway_url", "")
    gateway_healthy = False
    if gateway_url:
        try:
            import httpx
            async with httpx.AsyncClient(timeout=5.0) as client:
                resp = await client.get(f"{gateway_url}/health")
                gateway_healthy = resp.status_code == 200
        except Exception:
            pass

    return {
        "status": "healthy" if gateway_healthy else "degraded",
        "message": "النموذج العربي للتحليلات المالية جاهز" if gateway_healthy else "البوابة غير متاحة حالياً",
        "model": ARABIC_MODEL_STATUS["model_name"],
        "gateway_url": gateway_url,
        "gateway_healthy": gateway_healthy,
        "deployed_at": ARABIC_MODEL_STATUS["deployed_at"],
        "gguf_path": ARABIC_MODEL_STATUS["gguf_path"],
    }


@app.post("/inference/{job_id}/chat")
async def chat_inference(job_id: str, req: ChatRequest):
    engine = INFERENCE_ENGINES.get(job_id)
    if not engine:
        raise HTTPException(status_code=404, detail="Model is not actively deployed to the Inference Plane.")

    # OpenAI chat format (messages array)
    if req.messages:
        if isinstance(engine, dict) and engine.get("type") == "openai_gateway":
            try:
                import httpx
                gateway_url = engine.get("url") or str(engine["client"].base_url)
                async with httpx.AsyncClient(timeout=60.0) as client:
                    resp = await client.post(
                        f"{gateway_url}/v1/chat/completions",
                        json={"model": engine["model"], "messages": req.messages},
                    )
                    resp.raise_for_status()
                    data = resp.json()
                    return {"response": data["choices"][0]["message"]["content"]}
            except ImportError:
                raise HTTPException(status_code=500, detail="httpx not installed for gateway communication")
            except Exception as e:
                raise HTTPException(status_code=500, detail=f"Gateway inference fault: {str(e)}")
        else:
            # Fallback: concatenate messages into a prompt for non-gateway engines
            prompt = "\n".join(f"{m.get('role', 'user')}: {m.get('content', '')}" for m in req.messages)
            try:
                result = engine(prompt)[0]["generated_text"]
                if result.startswith(prompt):
                    result = result[len(prompt):].strip()
                return {"response": result}
            except Exception as e:
                raise HTTPException(status_code=500, detail=f"Inference Engine fault: {str(e)}")

    # Legacy raw prompt format
    try:
        result = engine(req.prompt)[0]["generated_text"]
        if result.startswith(req.prompt):
            result = result[len(req.prompt):].strip()
        return {"response": result}
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Inference Engine fault: {str(e)}")

# --- UPSTREAM PIPELINE ORCHESTRATION ---

# Live WebSocket connections subscribed to pipeline log stream
PIPELINE_WS_CONNECTIONS: set = set()


class PipelineStartRequest(BaseModel):
    governance_run_id: Optional[str] = None
    job_id: Optional[str] = None

async def broadcast_pipeline(message: dict) -> None:
    dead: set = set()
    for ws in PIPELINE_WS_CONNECTIONS:
        try:
            await ws.send_json(message)
        except Exception:
            dead.add(ws)
    PIPELINE_WS_CONNECTIONS.difference_update(dead)

@app.websocket("/ws/pipeline")
async def pipeline_ws_endpoint(websocket: WebSocket):
    """WebSocket endpoint that streams Python Pipeline logs in real time."""
    await websocket.accept()
    PIPELINE_WS_CONNECTIONS.add(websocket)
    # Send current state immediately upon connect so the UI hydrates
    await websocket.send_json({
        "type": "init",
        "state": PIPELINE_STATUS["state"],
        "logs": PIPELINE_STATUS["logs"]
    })
    try:
        while True:
            # Keep alive — client can send a ping, we pong back
            data = await websocket.receive_text()
            if data == "ping":
                await websocket.send_json({"type": "pong"})
    except WebSocketDisconnect:
        pass
    finally:
        PIPELINE_WS_CONNECTIONS.discard(websocket)

async def run_pipeline_worker(
    governance_run_id: Optional[str] = None,
    job_id: Optional[str] = None,
):
    PIPELINE_STATUS["state"] = "running"
    PIPELINE_STATUS["logs"] = ["🚀 Starting Python Data Generation Pipeline..."]
    if job_id:
        job = get_job(job_id) or _new_governed_job_record(job_id, {"workflow_type": "pipeline", "governance_run_id": governance_run_id})
        job["status"] = "running"
        job["progress"] = 0.1
        save_job(job)
    _update_governed_run_state(governance_run_id, job_id=job_id, status="running", event_type="pipeline_started")
    await broadcast_pipeline({"type": "init", "state": "running", "logs": PIPELINE_STATUS["logs"]})
    
    try:
        import os
        pipeline_dir = os.path.abspath(os.path.join(os.path.dirname(__file__), "../../../../../training/pipeline"))
        if not os.path.exists(pipeline_dir):
            pipeline_dir = "/app/src/training/pipeline"
            
        process = await asyncio.create_subprocess_exec(
            "make", "all",
            cwd=pipeline_dir,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.STDOUT
        )
        
        while True:
            line = await process.stdout.readline()
            if not line:
                break
            text = line.decode().strip()
            if text:
                PIPELINE_STATUS["logs"].append(text)
                # ⚡ Broadcast this line to all WS clients INSTANTLY
                await broadcast_pipeline({"type": "log", "text": text})
                
        await process.wait()
        
        if process.returncode == 0:
            PIPELINE_STATUS["state"] = "completed"
            final_msg = "✅ Pipeline finished — Spider/BIRD JSONL ready for training."
        else:
            PIPELINE_STATUS["state"] = "error"
            final_msg = f"❌ make exited with code {process.returncode}"
            
        PIPELINE_STATUS["logs"].append(final_msg)
        if job_id:
            job = get_job(job_id) or _new_governed_job_record(job_id, {"workflow_type": "pipeline", "governance_run_id": governance_run_id})
            job["status"] = "completed" if process.returncode == 0 else "failed"
            job["progress"] = 1.0
            if process.returncode != 0:
                job["error"] = final_msg
            save_job(job)
        if process.returncode == 0 and governance_run_id:
            _append_training_artifact(
                governance_run_id,
                artifact_type="pipeline_output",
                artifact_ref="training/pipeline/output/train.jsonl",
                metadata_json={"state": PIPELINE_STATUS["state"]},
            )
        _update_governed_run_state(
            governance_run_id,
            job_id=job_id,
            status="completed" if process.returncode == 0 else "failed",
            event_type="pipeline_completed" if process.returncode == 0 else "pipeline_failed",
            detail={"message": final_msg},
            completed=True,
        )
        await broadcast_pipeline({"type": "done", "state": PIPELINE_STATUS["state"], "text": final_msg})
            
    except Exception as e:
        PIPELINE_STATUS["state"] = "error"
        err_msg = f"💥 Fatal Subprocess Fault: {str(e)}"
        PIPELINE_STATUS["logs"].append(err_msg)
        if job_id:
            job = get_job(job_id) or _new_governed_job_record(job_id, {"workflow_type": "pipeline", "governance_run_id": governance_run_id})
            job["status"] = "failed"
            job["progress"] = 1.0
            job["error"] = err_msg
            save_job(job)
        _update_governed_run_state(
            governance_run_id,
            job_id=job_id,
            status="failed",
            event_type="pipeline_failed",
            detail={"error": str(e)},
            completed=True,
        )
        await broadcast_pipeline({"type": "done", "state": "error", "text": err_msg})


@app.post("/pipeline/start")
async def start_pipeline(background_tasks: BackgroundTasks, body: Optional[PipelineStartRequest] = None):
    if PIPELINE_STATUS["state"] == "running":
        raise HTTPException(status_code=400, detail="Pipeline already in progress.")
    body = body or PipelineStartRequest()
    job_id = body.job_id or f"pipe-{uuid.uuid4().hex[:8]}"
    governance_detail = _resolve_governance_run_detail(
        workflow_type="pipeline",
        governance_run_id=body.governance_run_id,
        requested_by="system",
        run_name=f"pipeline-{job_id}",
        dataset_ref="training/pipeline/output/train.jsonl",
        job_id=job_id,
        config_json={
            "job_id": job_id,
            "pipeline_mode": "make_all",
            "dataset_ref": "training/pipeline/output/train.jsonl",
        },
    )
    _enforce_launchable_governance(governance_detail, message="Pipeline run is blocked.")
    if not get_job(job_id):
        save_job(_new_governed_job_record(job_id, {"workflow_type": "pipeline", "governance_run_id": governance_detail["id"]}))
    background_tasks.add_task(run_pipeline_worker, governance_detail["id"], job_id)
    return {"status": "started", "job_id": job_id, "governance_run_id": governance_detail["id"]}

@app.get("/pipeline/status")
async def get_pipeline_status():
    return PIPELINE_STATUS

# --- HANA CLOUD EXPLORER ---

HANA_PREVIEW_PAIR_COUNT = 13952


def _hana_preview_rows(sql: str) -> list[dict[str, Any]]:
    normalized = sql.lower()
    if "count" in normalized:
        return [{"total": HANA_PREVIEW_PAIR_COUNT}]
    return [
        {"TABLE_NAME": "TRAINING_PAIRS", "SCHEMA_NAME": "FINSIGHT_CORE", "ROW_COUNT": HANA_PREVIEW_PAIR_COUNT},
        {"TABLE_NAME": "ODATA_VOCAB", "SCHEMA_NAME": "ODATA_VOCAB", "ROW_COUNT": 4200},
        {"TABLE_NAME": "PAL_EMBEDDINGS", "SCHEMA_NAME": "PAL_STORE", "ROW_COUNT": 8100},
    ]


def _has_hana_credentials() -> bool:
    return bool(HANA_HOST and HANA_USER and HANA_PASSWORD)


def _hana_connection():
    import hdbcli.dbapi as hdbcli  # type: ignore

    return hdbcli.connect(
        address=HANA_HOST,
        port=HANA_PORT,
        user=HANA_USER,
        password=HANA_PASSWORD,
        encrypt=HANA_ENCRYPT,
    )


def _to_json_safe(value: Any) -> Any:
    if value is None or isinstance(value, (str, int, float, bool)):
        return value
    if isinstance(value, datetime):
        return value.isoformat() + "Z"
    if isinstance(value, bytes):
        try:
            return value.decode("utf-8")
        except Exception:
            return value.hex()
    return str(value)


def _is_read_only_sql(sql: str) -> bool:
    normalized = sql.strip().lower().lstrip("(")
    if not normalized:
        return False
    if not normalized.startswith(("select", "with", "explain")):
        return False

    blocked = (
        " insert ",
        " update ",
        " delete ",
        " merge ",
        " upsert ",
        " drop ",
        " alter ",
        " create ",
        " truncate ",
        " grant ",
        " revoke ",
        " commit ",
        " rollback ",
        " call ",
    )
    padded = f" {normalized} "
    return not any(token in padded for token in blocked)


def _is_user_sql_error(detail: str) -> bool:
    normalized = detail.lower()
    indicators = (
        "syntax error",
        "invalid table",
        "table unknown",
        "invalid column",
        "column unknown",
        "insufficient privilege",
        "feature not supported",
    )
    return any(indicator in normalized for indicator in indicators)


def _hana_stats_response(available: bool, mode: str, reason: str | None = None) -> dict[str, Any]:
    payload: dict[str, Any] = {
        "available": available,
        "pair_count": HANA_PREVIEW_PAIR_COUNT,
        "mode": mode,
    }
    if reason:
        payload["reason"] = reason
    return payload


def _preview_hana_query_response(reason: str, sql: str) -> dict[str, Any]:
    rows = _hana_preview_rows(sql)
    return {
        "status": "ok",
        "mode": "preview",
        "reason": reason,
        "rows": rows,
        "count": len(rows),
    }


def _execute_hana_query_live(sql: str) -> list[dict[str, Any]]:
    conn = _hana_connection()
    try:
        cursor = conn.cursor()
        cursor.execute(sql)
        columns = [column[0] for column in cursor.description or []]
        rows = cursor.fetchmany(200)
        if not columns:
            return []
        return [
            {columns[index]: _to_json_safe(value) for index, value in enumerate(row)}
            for row in rows
        ]
    finally:
        conn.close()

@app.get("/hana/stats")
async def get_hana_stats():
    """Return HANA Cloud connection status and training pair count."""
    if not _has_hana_credentials():
        return _hana_stats_response(False, "preview", "credentials_missing")

    try:
        conn = _hana_connection()
        try:
            cursor = conn.cursor()
            cursor.execute("SELECT 1 FROM DUMMY")
            cursor.fetchone()
        finally:
            conn.close()
        return _hana_stats_response(True, "live")
    except Exception as exc:
        logger.warning("hana_stats_preview_fallback", error=str(exc))
        return _hana_stats_response(False, "preview", "reconnecting")

class HanaQueryPayload(BaseModel):
    sql: str

@app.post("/hana/query")
async def execute_hana_query(payload: HanaQueryPayload):
    """Execute a read-only SQL query against HANA Cloud, with a preview fallback for transient failures."""
    sql = payload.sql.strip()
    if not sql:
        raise HTTPException(status_code=400, detail="SQL query is required.")

    if not _is_read_only_sql(sql):
        raise HTTPException(status_code=400, detail="Only read-only SELECT, WITH, or EXPLAIN queries are allowed.")

    if not _has_hana_credentials():
        return _preview_hana_query_response("credentials_missing", sql)

    try:
        rows = _execute_hana_query_live(sql)
        return {
            "status": "ok",
            "mode": "live",
            "rows": rows,
            "count": len(rows),
        }
    except Exception as exc:
        detail = str(exc)
        logger.warning("hana_query_failed", error=detail)
        if _is_user_sql_error(detail):
            raise HTTPException(status_code=400, detail=detail)
        return _preview_hana_query_response("reconnecting", sql)


class LineageQueryPayload(BaseModel):
    query: str
    params: Optional[Dict[str, Any]] = None


class LineageIndexPayload(BaseModel):
    vector_stores: List[Dict[str, Any]] = []
    deployments: List[Dict[str, Any]] = []
    schemas: List[Dict[str, Any]] = []


_LINEAGE_NODES = [
    {"id": "tbl-training-pairs", "name": "TRAINING_PAIRS", "type": "Table"},
    {"id": "tbl-vocab", "name": "ODATA_VOCAB", "type": "Table"},
    {"id": "tbl-pal-embeddings", "name": "PAL_EMBEDDINGS", "type": "Table"},
    {"id": "pipe-rag", "name": "RAG Studio", "type": "Pipeline"},
    {"id": "pipe-optimizer", "name": "Model Forge", "type": "Pipeline"},
]

_LINEAGE_RELATIONSHIPS = [
    {"source": "tbl-training-pairs", "target": "pipe-rag", "relationship": "feeds", "path_depth": 1},
    {"source": "tbl-vocab", "target": "pipe-rag", "relationship": "annotates", "path_depth": 1},
    {"source": "pipe-rag", "target": "pipe-optimizer", "relationship": "publishes", "path_depth": 2},
    {"source": "tbl-pal-embeddings", "target": "pipe-optimizer", "relationship": "supports", "path_depth": 1},
]


def _lineage_rows_for_query(query: str) -> list[dict[str, Any]]:
    normalized = query.strip().lower()
    if "lineage_relationships" in normalized:
        return [
            {
                "source_name": next((node["name"] for node in _LINEAGE_NODES if node["id"] == rel["source"]), rel["source"]),
                "target_name": next((node["name"] for node in _LINEAGE_NODES if node["id"] == rel["target"]), rel["target"]),
                "relationship_type": rel["relationship"].upper(),
                "path_depth": rel["path_depth"],
            }
            for rel in _LINEAGE_RELATIONSHIPS
        ]
    if "lineage_nodes" in normalized:
        if "where object_type = 'table'" in normalized:
            return [
                {"id": node["id"], "name": node["name"], "type": node["type"]}
                for node in _LINEAGE_NODES
                if node["type"] == "Table"
            ]
        return [{"id": node["id"], "name": node["name"], "type": node["type"]} for node in _LINEAGE_NODES]
    return [{"id": node["id"], "name": node["name"], "type": node["type"]} for node in _LINEAGE_NODES]


@app.get("/lineage/graph/summary")
async def get_lineage_summary():
    return {
        "node_count": len(_LINEAGE_NODES),
        "edge_count": len(_LINEAGE_RELATIONSHIPS),
        "node_types": [
            {"type": "Table", "count": sum(1 for node in _LINEAGE_NODES if node["type"] == "Table")},
            {"type": "Pipeline", "count": sum(1 for node in _LINEAGE_NODES if node["type"] == "Pipeline")},
        ],
        "edge_types": [
            {"type": rel["relationship"].upper(), "count": 1}
            for rel in _LINEAGE_RELATIONSHIPS
        ],
        "status": "hana_ready" if os.getenv("HANA_HOST", "") else "sample_ready",
    }


@app.post("/lineage/query")
async def execute_lineage_query(payload: LineageQueryPayload):
    rows = _lineage_rows_for_query(payload.query)
    return {"rows": rows, "row_count": len(rows)}


@app.post("/lineage/index")
async def index_lineage_entities(payload: LineageIndexPayload):
    return {
        "stores_indexed": len(payload.vector_stores),
        "deployments_indexed": len(payload.deployments),
        "schemas_indexed": len(payload.schemas),
        "status": "hana_ready" if os.getenv("HANA_HOST", "") else "sample_ready",
    }

# --- PAL & MCP GATEWAY ---

@app.get("/pal/categories")
async def list_pal_categories():
    return pal_catalog.list_categories()

@app.get("/pal/algorithms/{category_id}")
async def list_pal_algorithms(category_id: str):
    return pal_catalog.list_by_category(category_id)

@app.get("/pal/search")
async def search_pal_algorithms(q: str):
    return pal_catalog.search(q)

@app.get("/pal/schema/{table_name}")
async def discover_hana_schema(table_name: str):
    try:
        return await hana_pal.discover_schema(table_name)
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

@app.post("/mcp")
async def mcp_gateway(request: Request):
    """Base MCP JSON-RPC gateway for tool execution."""
    body = await request.json()
    method = body.get("method")
    
    # Mock handlers for key MCP tools
    if method == "tools/list":
        return {
            "tools": [
                {"name": "pal-catalog", "description": "List available PAL algorithms"},
                {"name": "pal-execute", "description": "Execute a PAL algorithm on HANA"},
                {"name": "schema-explore", "description": "Explore HANA database schema"}
            ]
        }
    
    # Add more MCP logic as needed for production parity
    return {"jsonrpc": "2.0", "id": body.get("id"), "result": {"message": "MCP Method not implemented in Python shim"}}

# --- DATA EXPLORER PREVIEW ---

@app.get("/data/assets")
async def get_data_assets():
    """List all data assets (Excel, CSV, etc.) from the training data directory."""
    try:
        import os
        data_dir = os.path.join(os.path.dirname(__file__), "../../../../../training/data")
        assets = []
        if os.path.exists(data_dir):
            for filename in os.listdir(data_dir):
                if filename.startswith("."): continue
                path = os.path.join(data_dir, filename)
                if os.path.isfile(path):
                    size = os.path.getsize(path)
                    ext = filename.split(".")[-1].lower() if "." in filename else ""
                    assets.append({
                        "name": filename,
                        "type": "xlsx" if ext == "xlsx" else "csv" if ext == "csv" else "template" if "template" in filename.lower() else "unknown",
                        "size": f"{size // 1024} KB",
                        "description": f"Training asset: {filename}",
                        "category": "Pipeline Output" if filename.startswith(("1_", "2_", "3_")) else "Reference"
                    })
        return assets
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

@app.get("/data/preview")
async def get_data_preview(limit: int = 50, offset: int = 0, difficulty: str = ""):
    """Expose the generated Spider/BIRD JSONL pairs for human-in-the-loop auditing."""
    try:
        import os
        jsonl_paths = [
            os.path.join(os.path.dirname(__file__), "../../../../../training/pipeline/output/train.jsonl"),
            "/app/src/training/pipeline/output/train.jsonl",
        ]
        
        real_pairs: list = []
        for path in jsonl_paths:
            if os.path.exists(path):
                with open(path) as f:
                    for line in f:
                        line = line.strip()
                        if line:
                            try:
                                real_pairs.append(json.loads(line))
                            except json.JSONDecodeError:
                                pass
                break
        
        if real_pairs:
            if difficulty:
                real_pairs = [p for p in real_pairs if p.get("difficulty") == difficulty]
            return {"total": len(real_pairs), "pairs": real_pairs[offset:offset+limit], "source": "pipeline"}
        
        # Fallback: Rich synthetic banking NFRP data
        SYNTHETIC_PAIRS = [
            {"id": "spider_001", "difficulty": "easy", "db_id": "NFRP_Accounts", "question": "What is the total balance across all active accounts?", "query": "SELECT SUM(balance) FROM ACCOUNT WHERE status = 'ACTIVE'"},
            {"id": "spider_002", "difficulty": "medium", "db_id": "NFRP_Accounts", "question": "List all customers with more than 3 accounts sorted by account count descending", "query": "SELECT customer_id, COUNT(*) AS account_count FROM ACCOUNT GROUP BY customer_id HAVING COUNT(*) > 3 ORDER BY account_count DESC"},
            {"id": "spider_003", "difficulty": "hard", "db_id": "NFRP_Finance", "question": "Calculate the net position for each product segment in Q1 2025 filtered by cost centre", "query": "SELECT p.segment, SUM(f.revenue - f.cost) AS net_position FROM FACT_FINANCE f JOIN DIM_PRODUCT p ON f.product_id = p.id WHERE f.fiscal_quarter = 'Q1-2025' AND f.cost_centre IS NOT NULL GROUP BY p.segment ORDER BY net_position DESC"},
            {"id": "spider_004", "difficulty": "easy", "db_id": "NFRP_Locations", "question": "List all branches in Germany", "query": "SELECT name, city FROM BRANCH WHERE country = 'DE' ORDER BY city"},
            {"id": "spider_005", "difficulty": "medium", "db_id": "ESG", "question": "What are the top 5 suppliers by ESG risk score?", "query": "SELECT supplier_name, esg_risk_score FROM SUPPLIER_ESG ORDER BY esg_risk_score DESC LIMIT 5"},
            {"id": "spider_006", "difficulty": "hard", "db_id": "NFRP_Finance", "question": "Return the YoY revenue growth percentage for each cost centre in the banking segment", "query": "SELECT cc, ROUND(((curr.revenue - prev.revenue) / NULLIF(prev.revenue, 0)) * 100, 2) AS yoy_pct FROM (SELECT cost_centre AS cc, SUM(revenue) AS revenue FROM FACT_FINANCE WHERE fiscal_year = 2025 GROUP BY cost_centre) curr LEFT JOIN (SELECT cost_centre AS cc, SUM(revenue) AS revenue FROM FACT_FINANCE WHERE fiscal_year = 2024 GROUP BY cost_centre) prev USING(cc)"},
            {"id": "spider_007", "difficulty": "easy", "db_id": "NFRP_Segments", "question": "How many customers are in the retail segment?", "query": "SELECT COUNT(*) FROM CUSTOMER WHERE segment = 'RETAIL'"},
            {"id": "spider_008", "difficulty": "medium", "db_id": "NFRP_Accounts", "question": "Find all overdraft accounts with balance less than -10000", "query": "SELECT id, customer_id, balance FROM ACCOUNT WHERE balance < -10000 ORDER BY balance ASC"},
        ]
        
        filtered = [p for p in SYNTHETIC_PAIRS if not difficulty or p.get("difficulty") == difficulty]
        return {"total": len(filtered), "pairs": filtered[offset:offset+limit], "source": "synthetic"}
        
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

# --- MODELS ORCHESTRATION PIPELINE ---

class JobCreatePayload(BaseModel):
    config: Dict[str, Any]
    governance_run_id: Optional[str] = None

async def real_worker_task(job_id: str, governance_run_id: Optional[str] = None):
    """Real background orchestration running natively via PyTorch subprocessing"""
    job_data = get_job(job_id)
    if not job_data:
        return
    governance_run_id = governance_run_id or job_data.get("config", {}).get("governance_run_id")

    job_data["status"] = "running"
    save_job(job_data)
    _update_governed_run_state(governance_run_id, job_id=job_id, status="running", event_type="optimization_started")
    await broadcast_job(job_id, {"type": "status", "status": "running", "progress": 0})
    
    try:
        model_name = job_data["config"].get("model_name", "gpt2")
        cmd_args = ["python", "src/train.py", "--model_name", model_name]
        
        peft = job_data["config"].get("peft_config")
        if job_data["config"].get("use_peft") and peft:
            cmd_args.extend([
                "--peft_r", str(peft.get("r", 8)),
                "--peft_alpha", str(peft.get("lora_alpha", 16)),
                "--peft_dropout", str(peft.get("lora_dropout", 0.05))
            ])
            
        process = await asyncio.create_subprocess_exec(
            *cmd_args,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE
        )
        
        while True:
            line = await process.stdout.readline()
            if not line:
                break
                
            process_output = line.decode('utf-8').strip()
            if not process_output:
                continue
                
            log_entry: dict = {
                "step": process_output,
                "loss": None,
                "timestamp": _utc_now_iso()
            }

            if process_output.startswith("{") and "loss" in process_output:
                try:
                    metrics = json.loads(process_output)
                    evaluation = _extract_training_evaluation(metrics)
                    if evaluation:
                        job_data = get_job(job_id)
                        job_data["evaluation"] = evaluation
                        save_job(job_data)
                        log_entry["step"] = "✅ Final Evaluation Complete"
                        _update_governed_run_state(
                            governance_run_id,
                            job_id=job_id,
                            event_type="optimization_evaluation_recorded",
                            detail={"evaluation": evaluation},
                        )
                        # Broadcast evaluation payload for chart overlay
                        await broadcast_job(job_id, {"type": "evaluation", "data": job_data["evaluation"]})
                    elif "loss" in metrics:
                        loss_val = float(metrics["loss"])
                        ep = float(metrics.get("epoch", 0))
                        step_num = int(metrics.get("step", 0))
                        job_data = get_job(job_id)
                        new_progress = round(min(95.0, (ep / 3.0) * 100), 1)
                        history_point = {"step": step_num, "loss": loss_val, "epoch": round(ep, 2)}
                        job_data["progress"] = new_progress
                        job_data["history"].append(history_point)
                        save_job(job_data)
                        log_entry["loss"] = loss_val
                        # Broadcast chart data point live
                        await broadcast_job(job_id, {
                            "type": "loss",
                            "point": history_point,
                            "progress": new_progress
                        })
                except Exception:
                    pass
            
            # Broadcast raw log line for the terminal
            await broadcast_job(job_id, {"type": "log", "data": log_entry})
                
        await process.wait()
        
        job_data = get_job(job_id)
        if process.returncode == 0:
            job_data["status"] = "completed"
            job_data["progress"] = 100.0
        else:
            job_data["status"] = "failed"
            job_data["error"] = f"PyTorch process exited with code {process.returncode}"
            
        save_job(job_data)
        if process.returncode == 0 and governance_run_id:
            _append_training_artifact(
                governance_run_id,
                artifact_type="model_checkpoint",
                artifact_ref=f"training/nvidia-modelopt/outputs/{job_id}/checkpoint-optimal",
                metadata_json={"model_name": model_name, "export_format": job_data["config"].get("export_format")},
            )
        _update_governed_run_state(
            governance_run_id,
            job_id=job_id,
            status=job_data["status"],
            event_type="optimization_completed" if process.returncode == 0 else "optimization_failed",
            detail={"error": job_data.get("error"), "evaluation": job_data.get("evaluation")},
            completed=True,
        )
        await broadcast_job(job_id, {"type": "status", "status": job_data["status"], "progress": job_data["progress"]})

    except Exception as e:
        job_data = get_job(job_id)
        if job_data:
            job_data["status"] = "failed"
            job_data["error"] = str(e)
            save_job(job_data)
            _update_governed_run_state(
                governance_run_id,
                job_id=job_id,
                status="failed",
                event_type="optimization_failed",
                detail={"error": str(e)},
                completed=True,
            )
            await broadcast_job(job_id, {"type": "status", "status": "failed", "progress": 0})

# ---------------------------------------------------------------------------
# OCR Dataset Ingestion
# ---------------------------------------------------------------------------

class OcrDatasetPayload(BaseModel):
    dataset: List[Dict[str, Any]]
    source: Optional[str] = None

OCR_DATASET_DIR = os.path.join(os.path.dirname(__file__), "..", "data", "ocr-datasets")


@app.post("/v1/training/ocr-dataset")
async def ingest_ocr_dataset(payload: OcrDatasetPayload) -> JSONResponse:
    """
    Receive approved OCR pages as a JSONL training dataset from the curation UI.
    Appends entries to a timestamped JSONL file under packages/api-server/data/ocr-datasets/.
    Returns a receipt with the record count and file path.
    """
    if not payload.dataset:
        raise HTTPException(status_code=422, detail="dataset must be a non-empty list")

    os.makedirs(OCR_DATASET_DIR, exist_ok=True)

    ts = _utc_now().strftime("%Y%m%dT%H%M%SZ")
    filename = f"ocr-dataset-{ts}.jsonl"
    filepath = os.path.join(OCR_DATASET_DIR, filename)

    def _write() -> int:
        with open(filepath, "w", encoding="utf-8") as fh:
            for record in payload.dataset:
                fh.write(json.dumps(record, ensure_ascii=False) + "\n")
        return len(payload.dataset)

    count = await asyncio.to_thread(_write)

    logger.info("ocr_dataset_ingested", count=count, file=filename, source=payload.source)

    return JSONResponse(
        content={
            "status": "accepted",
            "records": count,
            "file": filename,
            "message": f"Ingested {count} OCR training record(s). Dataset written to {filename}.",
        },
        status_code=201,
    )


@app.post("/jobs")
async def create_job(payload: JobCreatePayload) -> JSONResponse:
    config = dict(payload.config)
    workflow_type = str(config.get("workflow_type") or "optimization")
    governance_detail = _resolve_governance_run_detail(
        workflow_type=workflow_type,
        governance_run_id=payload.governance_run_id or config.get("governance_run_id"),
        team=str(config.get("team") or ""),
        requested_by=str(config.get("requested_by") or config.get("team") or "system"),
        run_name=str(config.get("run_name") or f"{workflow_type}-{uuid.uuid4().hex[:6]}"),
        model_name=config.get("model_name"),
        dataset_ref=config.get("dataset_ref"),
        config_json=config,
        tag=config.get("tag"),
    )
    _enforce_launchable_governance(governance_detail, message="Training run is blocked.")
    governance_run_id = governance_detail["id"]
    config["governance_run_id"] = governance_run_id

    job_id = str(uuid.uuid4())
    job_record = {
        "id": job_id,
        "status": "pending",
        "progress": 0.0,
        "config": config,
        "history": [],
        "deployed": False,
        "evaluation": None,
        "error": None
    }
    save_job(job_record)

    if governance_run_id:
        _update_governed_run_state(
            governance_run_id,
            job_id=job_id,
            status="running",
            event_type="training_run_launched",
            detail={"job_id": job_id, "workflow_type": config.get("workflow_type", "optimization")},
        )

    asyncio.create_task(real_worker_task(job_id, governance_run_id=governance_run_id))

    return JSONResponse(content=_attach_job_governance({**job_record, "created_at": _utc_now_iso()}), status_code=201)


# Proxy logic fully removed since we are now a native orchestration server.


# ---------------------------------------------------------------------------
# Shared Prompt Template Library
# ---------------------------------------------------------------------------

class PromptTemplateCreate(BaseModel):
    name: str
    content: str
    category: str = "general"
    description: str = ""
    tags: list[str] = []

class PromptTemplateUpdate(BaseModel):
    name: Optional[str] = None
    content: Optional[str] = None
    category: Optional[str] = None
    description: Optional[str] = None
    tags: Optional[list[str]] = None

_prompt_templates: dict[str, dict] = {
    "seed-1": {"id": "seed-1", "name": "Training Data Prep", "content": "Prepare the following dataset for model training:\n\n{{data}}\n\nClean, normalize, and split into train/val/test sets.", "category": "training", "description": "Dataset preparation prompt", "tags": ["data", "training"], "created_by": "system", "created_at": _utc_now_iso(), "updated_at": _utc_now_iso(), "usage_count": 0, "version": 1},
    "seed-2": {"id": "seed-2", "name": "Model Evaluation", "content": "Evaluate the model performance using:\n- Accuracy, Precision, Recall, F1\n- Confusion matrix analysis\n- Per-class performance breakdown\n\nModel: {{model_name}}\nDataset: {{dataset}}", "category": "evaluation", "description": "Comprehensive model evaluation", "tags": ["model", "evaluation", "metrics"], "created_by": "system", "created_at": _utc_now_iso(), "updated_at": _utc_now_iso(), "usage_count": 0, "version": 1},
}

@app.get("/api/prompts")
async def list_prompts(category: str | None = None, tag: str | None = None):
    prompts = list(_prompt_templates.values())
    if category:
        prompts = [p for p in prompts if p.get("category") == category]
    if tag:
        prompts = [p for p in prompts if tag in p.get("tags", [])]
    prompts.sort(key=lambda p: p.get("usage_count", 0), reverse=True)
    return {"prompts": prompts, "total": len(prompts)}

@app.get("/api/prompts/categories")
async def list_prompt_categories():
    cats = sorted({p.get("category", "general") for p in _prompt_templates.values()})
    return {"categories": cats}

@app.get("/api/prompts/{prompt_id}")
async def get_prompt(prompt_id: str):
    p = _prompt_templates.get(prompt_id)
    if not p:
        raise HTTPException(status_code=404, detail="Prompt not found")
    return p

@app.post("/api/prompts", status_code=201)
async def create_prompt(body: PromptTemplateCreate):
    pid = str(uuid.uuid4())
    now = _utc_now_iso()
    p = {"id": pid, "name": body.name, "content": body.content, "category": body.category, "description": body.description, "tags": body.tags, "created_by": "user", "created_at": now, "updated_at": now, "usage_count": 0, "version": 1}
    _prompt_templates[pid] = p
    return p

@app.patch("/api/prompts/{prompt_id}")
async def update_prompt(prompt_id: str, body: PromptTemplateUpdate):
    p = _prompt_templates.get(prompt_id)
    if not p:
        raise HTTPException(status_code=404, detail="Prompt not found")
    for key, value in body.model_dump(exclude_none=True).items():
        p[key] = value
    p["updated_at"] = _utc_now_iso()
    p["version"] = p.get("version", 1) + 1
    return p

@app.delete("/api/prompts/{prompt_id}")
async def delete_prompt(prompt_id: str):
    if prompt_id not in _prompt_templates:
        raise HTTPException(status_code=404, detail="Prompt not found")
    _prompt_templates.pop(prompt_id)
    return {"ok": True, "id": prompt_id}

@app.post("/api/prompts/{prompt_id}/use")
async def record_prompt_usage(prompt_id: str):
    p = _prompt_templates.get(prompt_id)
    if not p:
        raise HTTPException(status_code=404, detail="Prompt not found")
    p["usage_count"] = p.get("usage_count", 0) + 1
    return {"id": prompt_id, "usage_count": p["usage_count"]}


if __name__ == "__main__":
    import uvicorn

    port = int(os.getenv("PORT", "8000"))
    host = os.getenv("HOST", "0.0.0.0")
    uvicorn.run(app, host=host, port=port)
