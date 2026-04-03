"""Lightweight FastAPI wrapper for the Arabic OCR service.

.. deprecated::
    This module is deprecated.  Use ``server.py`` instead, which provides
    all the same endpoints (including backwards-compatible ``/api/ocr/process``)
    with tighter security defaults (no wildcard CORS, 50 MB upload cap,
    callback URL allowlisting).

    Start the canonical server with:
        uvicorn intelligence.ocr.server:app --reload

Endpoints:
    POST /api/ocr/process  — Upload a PDF and get structured OCR JSON
    GET  /api/ocr/health   — Health check

Start with:
    uvicorn intelligence.ocr.api:app --reload --port 8100
"""

import asyncio
import logging
import os
import tempfile
import warnings
from typing import Optional

warnings.warn(
    "intelligence.ocr.api is deprecated — use intelligence.ocr.server instead. "
    "The server module provides all endpoints including /api/ocr/process for "
    "backwards compatibility, with tighter security defaults.",
    DeprecationWarning,
    stacklevel=2,
)

logger = logging.getLogger(__name__)

try:
    from fastapi import FastAPI, File, HTTPException, Query, UploadFile
    from fastapi.middleware.cors import CORSMiddleware
    from fastapi.responses import JSONResponse
except ImportError:
    raise ImportError(
        "FastAPI is required for the OCR API.  "
        "Install with: pip install fastapi uvicorn python-multipart"
    )

from .arabic_ocr_service import ArabicOCRService, OCRResult
from .pdf_processor import PDFProcessor

app = FastAPI(
    title="Arabic OCR API (DEPRECATED — use server.py)",
    description="PDF upload and OCR processing for Arabic documents. "
                "This module is deprecated; use intelligence.ocr.server instead.",
    version="1.0.0",
)

# CORS — tightened from wildcard to configurable origins
_raw_origins = os.getenv("OCR_ALLOWED_ORIGINS", "")
_allowed_origins = [o.strip() for o in _raw_origins.split(",") if o.strip()]

app.add_middleware(
    CORSMiddleware,
    allow_origins=_allowed_origins,
    allow_credentials=True,
    allow_methods=["GET", "POST"],
    allow_headers=["*"],
)

_service: Optional[ArabicOCRService] = None
_semaphore: Optional[asyncio.Semaphore] = None


def _get_service() -> ArabicOCRService:
    """Lazy-initialise the OCR service singleton."""
    global _service
    if _service is None:
        _service = ArabicOCRService(
            languages=os.getenv("OCR_LANGUAGES", "ara+eng"),
            dpi=int(os.getenv("OCR_DPI", "300")),
            max_workers=int(os.getenv("OCR_MAX_WORKERS", "2")),
        )
    return _service


def _get_semaphore() -> asyncio.Semaphore:
    """Lazy-initialise the concurrency semaphore."""
    global _semaphore
    if _semaphore is None:
        _semaphore = asyncio.Semaphore(
            int(os.getenv("OCR_MAX_CONCURRENT", "4"))
        )
    return _semaphore


@app.get("/api/ocr/health")
async def health() -> dict:
    """Health check endpoint."""
    return {"status": "ok", "service": "arabic-ocr-api"}


@app.post("/api/ocr/process")
async def process_pdf(
    file: UploadFile = File(...),
    start_page: Optional[int] = Query(None, ge=1),
    end_page: Optional[int] = Query(None, ge=1),
    detect_tables: bool = Query(True),
) -> JSONResponse:
    """Process an uploaded PDF file with OCR.

    Returns structured JSON with per-page text, tables, confidence scores,
    and metadata.
    """
    if not file.filename or not file.filename.lower().endswith(".pdf"):
        raise HTTPException(status_code=400, detail="File must be a PDF")

    # Check file size (50 MB limit)
    content = await file.read()
    max_size = 50 * 1024 * 1024
    if len(content) > max_size:
        raise HTTPException(
            status_code=413,
            detail=f"File exceeds maximum size of 50 MB",
        )

    sem = _get_semaphore()
    if sem.locked():
        raise HTTPException(
            status_code=429,
            detail="Too many concurrent OCR requests. Try again later.",
        )

    with tempfile.NamedTemporaryFile(suffix=".pdf", delete=False) as tmp:
        tmp.write(content)
        tmp.flush()
        tmp_path = tmp.name

    try:
        async with sem:
            service = _get_service()
            result = await service.process_pdf_async(
                tmp_path, start_page, end_page, detect_tables
            )
        return JSONResponse(content=result.to_dict())
    except Exception as e:
        logger.error("OCR processing failed: %s", e)
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
