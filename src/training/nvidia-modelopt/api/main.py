#!/usr/bin/env python3
"""
Model Optimizer Microservice
FastAPI service for T4 GPU model quantization and optimization
"""

from contextlib import asynccontextmanager
from enum import Enum
from typing import Optional, List
from datetime import datetime
import uuid
import logging
import os

import asyncio
from fastapi import FastAPI, HTTPException, BackgroundTasks, Depends, Request
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, Field

from .openai_compat import router as openai_router
from .inference import detect_gpu, get_supported_formats
from .job_executor import get_executor
from .auth import verify_auth, check_rate_limit
from .metrics import router as metrics_router, request_count, request_latency, request_errors
from .logging_config import setup_logging, get_logger
from pathlib import Path

# Read version from root VERSION file
_version_file = Path(__file__).resolve().parent.parent.parent / "VERSION"
__version__ = _version_file.read_text().strip() if _version_file.exists() else "0.0.0-dev"

# Configure structured logging (JSON in prod, coloured text in dev)
setup_logging()
logger = get_logger("modelopt-service")

SERVICE_NAME = "model-optimizer"
SERVICE_PORT = int(os.getenv("PORT", "8001"))

# CORS: explicit origins required when allow_credentials=True (per spec)
_allowed_origins = os.getenv(
    "ALLOWED_ORIGINS",
    "http://localhost:4200,http://localhost:4201",
)
ALLOWED_ORIGINS: List[str] = [o.strip() for o in _allowed_origins.split(",") if o.strip()]


@asynccontextmanager
async def lifespan(app: FastAPI):
    logger.info(f"Starting {SERVICE_NAME} microservice on port {SERVICE_PORT}")
    yield
    logger.info(f"Shutting down {SERVICE_NAME} microservice")


app = FastAPI(
    title="Model Optimizer Microservice",
    description="T4 GPU model quantization and optimization service",
    version=__version__,
    lifespan=lifespan,
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=ALLOWED_ORIGINS,
    allow_credentials=True,
    allow_methods=["GET", "POST", "PUT", "DELETE", "OPTIONS"],
    allow_headers=["Authorization", "Content-Type", "Accept", "X-Request-ID"],
)


# Request ID + metrics middleware
@app.middleware("http")
async def add_request_id_and_metrics(request: Request, call_next):
    import time as _time

    request_id = request.headers.get("X-Request-ID", str(uuid.uuid4()))
    request.state.request_id = request_id
    request_count.inc()

    start = _time.perf_counter()
    response = await call_next(request)
    elapsed = _time.perf_counter() - start

    request_latency.observe(elapsed)
    if response.status_code >= 500:
        request_errors.inc()

    response.headers["X-Request-ID"] = request_id
    return response


# Include routers
app.include_router(openai_router)
app.include_router(metrics_router)


# === Enums ===
class QuantFormat(str, Enum):
    INT8 = "int8"
    INT4_AWQ = "int4_awq"
    W4A16 = "w4a16"


class JobStatus(str, Enum):
    PENDING = "pending"
    RUNNING = "running"
    COMPLETED = "completed"
    FAILED = "failed"
    CANCELLED = "cancelled"


class ExportFormat(str, Enum):
    HF = "hf"
    TENSORRT_LLM = "tensorrt_llm"
    VLLM = "vllm"


# === Models ===
class ModelInfo(BaseModel):
    name: str
    size_gb: float
    parameters: str
    recommended_quant: QuantFormat
    t4_compatible: bool


class QuantizationConfig(BaseModel):
    model_name: str = Field(..., description="HuggingFace model name")
    quant_format: QuantFormat = Field(default=QuantFormat.INT8)
    calib_samples: int = Field(default=512, ge=32, le=2048)
    calib_seq_len: int = Field(default=2048, ge=256, le=4096)
    export_format: ExportFormat = Field(default=ExportFormat.HF)
    enable_pruning: bool = Field(default=False)
    pruning_sparsity: float = Field(default=0.2, ge=0.0, le=0.5)


class JobCreate(BaseModel):
    config: QuantizationConfig
    name: Optional[str] = None


class JobResponse(BaseModel):
    id: str
    name: str
    status: JobStatus
    config: QuantizationConfig
    created_at: datetime
    started_at: Optional[datetime] = None
    completed_at: Optional[datetime] = None
    progress: float = 0.0
    output_path: Optional[str] = None
    error: Optional[str] = None


# === In-Memory Store ===
jobs_store: dict[str, JobResponse] = {}

MODEL_CATALOG = [
    ModelInfo(name="Qwen/Qwen3.5-0.6B", size_gb=1.2, parameters="0.6B", recommended_quant=QuantFormat.INT8, t4_compatible=True),
    ModelInfo(name="Qwen/Qwen3.5-1.8B", size_gb=3.6, parameters="1.8B", recommended_quant=QuantFormat.INT8, t4_compatible=True),
    ModelInfo(name="Qwen/Qwen3.5-4B", size_gb=8.0, parameters="4B", recommended_quant=QuantFormat.INT8, t4_compatible=True),
    ModelInfo(name="Qwen/Qwen3.5-9B", size_gb=18.0, parameters="9B", recommended_quant=QuantFormat.INT4_AWQ, t4_compatible=True),
]


# === Endpoints ===
@app.get("/")
async def root():
    return {"service": SERVICE_NAME, "version": "1.0.0", "status": "healthy"}


@app.get("/health")
async def health():
    return {"status": "healthy", "service": SERVICE_NAME, "version": __version__}


@app.get("/version")
async def version():
    return {"version": __version__, "service": SERVICE_NAME}


@app.get("/models/catalog", response_model=List[ModelInfo])
async def list_models():
    """List available models for optimization."""
    return MODEL_CATALOG


@app.get("/models/quant-formats")
async def list_quant_formats():
    """List quantization formats supported on T4 GPU."""
    return {
        "formats": [
            {"id": "int8", "name": "INT8 SmoothQuant", "compression": "2x", "t4_supported": True},
            {"id": "int4_awq", "name": "INT4 AWQ", "compression": "4x", "t4_supported": True},
            {"id": "w4a16", "name": "W4A16", "compression": "4x", "t4_supported": True},
            {"id": "fp8", "name": "FP8", "compression": "2x", "t4_supported": False},
        ],
        "gpu": "Tesla T4",
    }


async def update_job_status(
    job_id: str,
    status: str,
    progress: float,
    started_at: datetime = None,
    completed_at: datetime = None,
    output_path: str = None,
    error: str = None
):
    """Callback to update job status from executor"""
    if job_id in jobs_store:
        job = jobs_store[job_id]
        job.status = JobStatus(status)
        job.progress = progress
        if started_at:
            job.started_at = started_at
        if completed_at:
            job.completed_at = completed_at
        if output_path:
            job.output_path = output_path
        if error:
            job.error = error


@app.post("/jobs", response_model=JobResponse, dependencies=[Depends(verify_auth), Depends(check_rate_limit)])
async def create_job(job: JobCreate, background_tasks: BackgroundTasks):
    """Create a new optimization job and execute it."""
    job_id = str(uuid.uuid4())
    response = JobResponse(
        id=job_id,
        name=job.name or f"job-{job_id[:8]}",
        status=JobStatus.PENDING,
        config=job.config,
        created_at=datetime.utcnow(),
    )
    jobs_store[job_id] = response
    
    # Start job execution in background
    executor = get_executor()
    config_dict = {
        "model_name": job.config.model_name,
        "quant_format": job.config.quant_format.value,
        "calib_samples": job.config.calib_samples,
        "export_format": job.config.export_format.value,
        "enable_pruning": job.config.enable_pruning,
        "pruning_sparsity": job.config.pruning_sparsity,
    }
    background_tasks.add_task(executor.execute_job, job_id, config_dict, update_job_status)
    
    return response


@app.get("/jobs", response_model=List[JobResponse])
async def list_jobs(status: Optional[JobStatus] = None, limit: int = 100):
    """List optimization jobs."""
    jobs = list(jobs_store.values())
    if status:
        jobs = [j for j in jobs if j.status == status]
    return sorted(jobs, key=lambda x: x.created_at, reverse=True)[:limit]


@app.get("/jobs/{job_id}", response_model=JobResponse)
async def get_job(job_id: str):
    """Get job details."""
    if job_id not in jobs_store:
        raise HTTPException(status_code=404, detail="Job not found")
    return jobs_store[job_id]


@app.delete("/jobs/{job_id}", dependencies=[Depends(verify_auth), Depends(check_rate_limit)])
async def cancel_job(job_id: str):
    """Cancel a job."""
    if job_id not in jobs_store:
        raise HTTPException(status_code=404, detail="Job not found")
    job = jobs_store[job_id]
    if job.status not in [JobStatus.PENDING, JobStatus.RUNNING]:
        raise HTTPException(status_code=400, detail="Job cannot be cancelled")
    
    # Cancel running job
    if job.status == JobStatus.RUNNING:
        executor = get_executor()
        await executor.cancel_job(job_id)
    
    job.status = JobStatus.CANCELLED
    job.completed_at = datetime.utcnow()
    return {"message": "Job cancelled", "job_id": job_id}


@app.get("/gpu/status")
async def gpu_status():
    """Get real GPU status using nvidia-smi."""
    gpu = detect_gpu()
    
    if gpu:
        return {
            "gpu_name": gpu.name,
            "compute_capability": gpu.compute_capability,
            "total_memory_gb": round(gpu.memory_total_gb, 2),
            "used_memory_gb": round(gpu.memory_used_gb, 2),
            "free_memory_gb": round(gpu.memory_free_gb, 2),
            "utilization_percent": gpu.utilization_percent,
            "temperature_c": gpu.temperature_c,
            "driver_version": gpu.driver_version,
            "cuda_version": gpu.cuda_version,
            "supported_formats": get_supported_formats(gpu),
        }
    else:
        # Fallback when no GPU detected
        return {
            "gpu_name": "No GPU detected",
            "compute_capability": "N/A",
            "total_memory_gb": 0,
            "used_memory_gb": 0,
            "free_memory_gb": 0,
            "utilization_percent": 0,
            "temperature_c": 0,
            "driver_version": "N/A",
            "cuda_version": "N/A",
            "supported_formats": ["int8", "int4_awq", "w4a16"],  # CPU fallback
        }


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=SERVICE_PORT)
