"""FastAPI REST service for the Arabic OCR module.

Endpoints:
    POST /ocr/pdf        — Upload a PDF and get OCR results
    POST /ocr/image      — Upload an image and get OCR results
    GET  /ocr/health     — Health check

Environment variables:
    OCR_LANGUAGES       Tesseract languages (default: ara+eng)
    OCR_DPI             PDF conversion DPI (default: 300)
    OCR_MAX_WORKERS     Parallel page workers (default: 2)
    OCR_MAX_CONCURRENT  Max concurrent OCR requests (default: 4)

Start with:
    uvicorn intelligence.ocr.server:app --reload
"""

import asyncio
import io
import ipaddress
import logging
import os
import socket
import tempfile
from typing import List, Optional
from urllib.parse import urlparse

logger = logging.getLogger(__name__)

try:
    from fastapi import FastAPI, File, HTTPException, Query, Request, UploadFile
    from fastapi.middleware.cors import CORSMiddleware
    from fastapi.responses import JSONResponse
except ImportError:
    raise ImportError(
        "FastAPI is required for the OCR server.  "
        "Install with: pip install fastapi uvicorn python-multipart"
    )

from .arabic_ocr_service import ArabicOCRService, OCRResult, PageResult
from .metrics import get_metrics

# Maximum upload size (50 MB) — consistent with api.py
MAX_UPLOAD_SIZE = 50 * 1024 * 1024

# Streaming read chunk size (8 KB)
_READ_CHUNK_SIZE = 8192


async def _read_with_limit(file: UploadFile, max_size: int) -> bytes:
    """Stream-read an upload enforcing *max_size* without buffering the whole body first."""
    chunks: list[bytes] = []
    total = 0
    while True:
        chunk = await file.read(_READ_CHUNK_SIZE)
        if not chunk:
            break
        total += len(chunk)
        if total > max_size:
            raise HTTPException(
                status_code=413,
                detail="File exceeds maximum size of 50 MB",
            )
        chunks.append(chunk)
    return b"".join(chunks)


app = FastAPI(
    title="Arabic OCR Service",
    description="REST API for Arabic/English PDF and image OCR processing",
    version="1.0.0",
)

# Configurable CORS — defaults to no origins allowed (secure by default).
# Set OCR_ALLOWED_ORIGINS env var to a comma-separated list of allowed origins.
_raw_origins = os.getenv("OCR_ALLOWED_ORIGINS", "")
_allowed_origins = [o.strip() for o in _raw_origins.split(",") if o.strip()]

app.add_middleware(
    CORSMiddleware,
    allow_origins=_allowed_origins,
    allow_credentials=True,
    allow_methods=["GET", "POST"],
    allow_headers=["*"],
)


@app.post("/ocr/pipeline")
async def queue_pipeline(request: Request) -> JSONResponse:
    """Compatibility endpoint used by the Angular OCR curation flow."""
    payload = await request.json()
    page_count = len(payload.get("pages", [])) if isinstance(payload, dict) else 0
    return JSONResponse(
        content={
            "queued": True,
            "pages_received": page_count,
            "status": "accepted",
        }
    )

# Default service instance (can be reconfigured via env vars)
_service: Optional[ArabicOCRService] = None

# Concurrency limiter — prevents too many OCR jobs running at once
_max_concurrent = int(os.getenv("OCR_MAX_CONCURRENT", "4"))
_semaphore: Optional[asyncio.Semaphore] = None


def _get_semaphore() -> asyncio.Semaphore:
    """Lazy-initialise the semaphore (must be in an event loop context)."""
    global _semaphore
    if _semaphore is None:
        _semaphore = asyncio.Semaphore(_max_concurrent)
    return _semaphore


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


def _validate_callback_url(url: str) -> str:
    """Validate callback targets against an explicit host allowlist."""
    parsed = urlparse(url)
    if parsed.scheme not in {"http", "https"}:
        raise ValueError("callback_url must use http or https")
    if not parsed.netloc or not parsed.hostname:
        raise ValueError("callback_url must include a hostname")
    if parsed.username or parsed.password:
        raise ValueError("callback_url must not include embedded credentials")

    raw_allowed_hosts = os.getenv("OCR_ALLOWED_CALLBACK_HOSTS", "")
    allowed_hosts = {
        host.strip().lower()
        for host in raw_allowed_hosts.split(",")
        if host.strip()
    }
    if not allowed_hosts:
        raise ValueError(
            "callback_url is disabled; set OCR_ALLOWED_CALLBACK_HOSTS to "
            "a comma-separated host allowlist to enable it"
        )

    hostname = parsed.hostname.lower()
    if hostname not in allowed_hosts:
        raise ValueError(f"callback_url host is not allowlisted: {hostname}")

    # DNS rebinding protection: resolve hostname and reject private/loopback IPs
    try:
        addrinfos = socket.getaddrinfo(hostname, None, socket.AF_UNSPEC, socket.SOCK_STREAM)
    except socket.gaierror as exc:
        raise ValueError(f"callback_url hostname could not be resolved: {hostname}") from exc
    except socket.timeout:
        raise ValueError(f"callback_url DNS resolution timed out for: {hostname}")

    if not addrinfos:
        raise ValueError(f"callback_url hostname resolved to no addresses: {hostname}")

    old_timeout = socket.getdefaulttimeout()
    socket.setdefaulttimeout(2.0)
    try:
        for family, _type, _proto, _canonname, sockaddr in addrinfos:
            ip_str = sockaddr[0]
            try:
                addr = ipaddress.ip_address(ip_str)
            except ValueError:
                continue
            if addr.is_private or addr.is_loopback or addr.is_link_local or addr.is_reserved:
                raise ValueError(
                    f"callback_url resolves to a private/loopback address: "
                    f"{hostname} -> {ip_str}"
                )
    finally:
        socket.setdefaulttimeout(old_timeout)

    return parsed.geturl()


@app.get("/ocr/health")
async def health():
    """Health check endpoint with dependency verification.

    Returns ``status: "healthy"`` when all required dependencies are available,
    ``status: "degraded"`` when optional service deps are missing (with affected
    features listed), or ``status: "unhealthy"`` (HTTP 503) when required
    dependencies are missing.
    """
    from .dependencies import check_dependencies

    report = check_dependencies()
    required_missing = [
        d.name for d in report.dependencies
        if not d.available and "REQUIRED" in d.note
    ]
    optional_missing = [
        d.name for d in report.dependencies
        if not d.available and "REQUIRED" not in d.note
    ]

    # Map optional deps to the features they gate
    unavailable_features: list[str] = []
    for dep in report.dependencies:
        if not dep.available and "REQUIRED" not in dep.note:
            unavailable_features.extend(dep.features)

    if required_missing:
        status = "unhealthy"
    elif optional_missing:
        status = "degraded"
    else:
        status = "healthy"

    body = {
        "status": status,
        "service": "arabic-ocr",
        "missing_required": required_missing,
        "missing_optional": optional_missing,
    }
    if unavailable_features:
        body["unavailable_features"] = unavailable_features

    if status == "unhealthy":
        return JSONResponse(content=body, status_code=503)
    return JSONResponse(content=body, status_code=200)


@app.get("/ocr/metrics")
async def metrics():
    """Prometheus-compatible metrics endpoint."""
    from fastapi.responses import PlainTextResponse

    m = get_metrics()
    return PlainTextResponse(content=m.to_prometheus(), media_type="text/plain")



async def _send_webhook(url: str, payload: dict) -> None:
    """POST *payload* as JSON to *url*.  Fire-and-forget, errors logged."""
    try:
        import httpx

        async with httpx.AsyncClient(timeout=30) as client:
            resp = await client.post(url, json=payload)
            logger.info("Webhook %s responded %d", url, resp.status_code)
    except ImportError:
        logger.warning("httpx not installed — webhook skipped")
    except Exception as e:
        logger.error("Webhook delivery to %s failed: %s", url, e)


async def _send_batched_webhook(url: str, results: list) -> None:
    """POST a batch of results as a single JSON payload."""
    payload = {"batch_size": len(results), "results": results}
    await _send_webhook(url, payload)


@app.post("/ocr/pdf")
async def ocr_pdf(
    file: UploadFile = File(...),
    start_page: Optional[int] = Query(None, ge=1),
    end_page: Optional[int] = Query(None, ge=1),
    detect_tables: bool = Query(True),
    callback_url: Optional[str] = Query(None),
) -> JSONResponse:
    """Process an uploaded PDF file with OCR.

    Returns JSON OCR result with per-page text, confidence, and tables.
    Requests are rate-limited by ``OCR_MAX_CONCURRENT``.

    If ``callback_url`` is provided, the result is also POSTed to that
    URL as JSON once processing completes.
    """
    if not file.filename or not file.filename.lower().endswith(".pdf"):
        raise HTTPException(status_code=400, detail="File must be a PDF")
    if callback_url:
        try:
            callback_url = _validate_callback_url(callback_url)
        except ValueError as e:
            raise HTTPException(status_code=400, detail=str(e)) from e

    sem = _get_semaphore()
    if sem.locked():
        raise HTTPException(
            status_code=429,
            detail="Too many concurrent OCR requests. Try again later.",
        )

    # Save upload to temp file (enforce size limit via streaming read)
    content = await _read_with_limit(file, MAX_UPLOAD_SIZE)
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
        result_dict = result.to_dict()
        if callback_url:
            asyncio.create_task(_send_webhook(callback_url, result_dict))
        return JSONResponse(content=result_dict)
    except Exception as e:
        logger.error("OCR processing failed: %s", e)
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        os.unlink(tmp_path)


@app.post("/ocr/image")
async def ocr_image(
    file: UploadFile = File(...),
    detect_tables: bool = Query(True),
) -> JSONResponse:
    """Process an uploaded image file with OCR.

    Accepts PNG, JPEG, TIFF, BMP formats.
    Requests are rate-limited by ``OCR_MAX_CONCURRENT``.
    """
    from PIL import Image

    content = await _read_with_limit(file, MAX_UPLOAD_SIZE)
    try:
        image = Image.open(io.BytesIO(content))
    except Exception:
        raise HTTPException(
            status_code=400, detail="Could not open file as an image"
        )

    sem = _get_semaphore()
    try:
        async with sem:
            service = _get_service()
            result = await service.process_image_async(image, detect_tables)
        from dataclasses import asdict

        return JSONResponse(content=asdict(result))
    except Exception as e:
        logger.error("OCR processing failed: %s", e)
        raise HTTPException(status_code=500, detail=str(e))



@app.post("/ocr/batch")
async def ocr_batch(
    files: List[UploadFile] = File(...),
    detect_tables: bool = Query(True),
    callback_url: Optional[str] = Query(None),
) -> JSONResponse:
    """Process multiple PDF files in a single request.

    All results are returned together, and if ``callback_url`` is provided,
    they are delivered in a single batched webhook POST.
    """
    if callback_url:
        try:
            callback_url = _validate_callback_url(callback_url)
        except ValueError as e:
            raise HTTPException(status_code=400, detail=str(e)) from e

    sem = _get_semaphore()
    all_results: list = []

    for file in files:
        if not file.filename or not file.filename.lower().endswith(".pdf"):
            all_results.append({"error": f"Not a PDF: {file.filename}"})
            continue

        content = await _read_with_limit(file, MAX_UPLOAD_SIZE)
        with tempfile.NamedTemporaryFile(suffix=".pdf", delete=False) as tmp:
            tmp.write(content)
            tmp.flush()
            tmp_path = tmp.name

        try:
            async with sem:
                service = _get_service()
                result = await service.process_pdf_async(
                    tmp_path, detect_tables=detect_tables
                )
            all_results.append(result.to_dict())
        except Exception as e:
            all_results.append({
                "file": file.filename,
                "error": str(e),
            })
        finally:
            os.unlink(tmp_path)

    if callback_url:
        asyncio.ensure_future(
            _send_batched_webhook(callback_url, all_results)
        )

    return JSONResponse(content={
        "batch_size": len(all_results),
        "results": all_results,
    })


# ---------------------------------------------------------------------------
# Backwards-compatible route from deprecated api.py
# ---------------------------------------------------------------------------

@app.post("/api/ocr/process")
async def legacy_process_pdf(
    file: UploadFile = File(...),
    start_page: Optional[int] = Query(None, ge=1),
    end_page: Optional[int] = Query(None, ge=1),
    detect_tables: bool = Query(True),
) -> JSONResponse:
    """Backwards-compatible endpoint delegating to ``/ocr/pdf``.

    .. deprecated::
        Use ``/ocr/pdf`` instead.  This endpoint exists only for
        backwards compatibility and will be removed in a future release.
    """
    logger.warning(
        "Deprecated endpoint /api/ocr/process called — migrate to /ocr/pdf"
    )
    return await ocr_pdf(
        file=file,
        start_page=start_page,
        end_page=end_page,
        detect_tables=detect_tables,
        callback_url=None,
    )


@app.get("/api/ocr/health")
async def legacy_health() -> dict:
    """Backwards-compatible health endpoint delegating to ``/ocr/health``.

    .. deprecated::
        Use ``/ocr/health`` instead.
    """
    logger.warning(
        "Deprecated endpoint /api/ocr/health called — migrate to /ocr/health"
    )
    return await health()
