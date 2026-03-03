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

from fastapi import FastAPI, HTTPException, BackgroundTasks
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, Field

# Configure logging
logging.basicConfig(level=logging.INFO, format="%(asctime)s - %(name)s - %(levelname)s - %(message)s")
logger = logging.getLogger("modelopt-service")

SERVICE_NAME = "model-optimizer"
SERVICE_PORT = int(os.getenv("PORT", "8001"))


@asynccontextmanager
async def lifespan(app: FastAPI):
    logger.info(f"Starting {SERVICE_NAME} microservice on port {SERVICE_PORT}")
    yield
    logger.info(f"Shutting down {SERVICE_NAME} microservice")


app = FastAPI(
    title="Model Optimizer Microservice",
    description="T4 GPU model quantization and optimization service",
    version="1.0.0",
    lifespan=lifespan,
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


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
    return {"status": "healthy", "service": SERVICE_NAME}


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


@app.post("/jobs", response_model=JobResponse)
async def create_job(job: JobCreate, background_tasks: BackgroundTasks):
    """Create a new optimization job."""
    job_id = str(uuid.uuid4())
    response = JobResponse(
        id=job_id,
        name=job.name or f"job-{job_id[:8]}",
        status=JobStatus.PENDING,
        config=job.config,
        created_at=datetime.utcnow(),
    )
    jobs_store[job_id] = response
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


@app.delete("/jobs/{job_id}")
async def cancel_job(job_id: str):
    """Cancel a job."""
    if job_id not in jobs_store:
        raise HTTPException(status_code=404, detail="Job not found")
    job = jobs_store[job_id]
    if job.status not in [JobStatus.PENDING, JobStatus.RUNNING]:
        raise HTTPException(status_code=400, detail="Job cannot be cancelled")
    job.status = JobStatus.CANCELLED
    return {"message": "Job cancelled", "job_id": job_id}


@app.get("/gpu/status")
async def gpu_status():
    """Get GPU status."""
    return {
        "gpu_name": "Tesla T4",
        "compute_capability": "7.5",
        "total_memory_gb": 16.0,
        "supported_formats": ["int8", "int4_awq", "w4a16"],
    }


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=SERVICE_PORT)