"""FastAPI REST service for the Arabic OCR module.

Endpoints:
    POST /ocr/pdf           — Upload a PDF and get OCR results
    POST /ocr/image         — Upload an image and get OCR results
    GET  /ocr/health        — Health check (dependency report)
    GET  /api/ocr/health    — Legacy minimal health (backward compatible)
    POST /api/ocr/process   — Legacy PDF upload (same as ``/ocr/pdf``)

Environment variables:
    OCR_LANGUAGES       Tesseract languages (default: ara+eng)
    OCR_DPI             PDF conversion DPI (default: 300)
    OCR_MAX_WORKERS     Parallel page workers (default: 2)
    OCR_MAX_CONCURRENT  Max concurrent OCR requests (default: 4)
    OCR_CORS_ORIGINS    Comma-separated allowed origins for CORS. If unset,
                        CORS middleware is not added. Use ``*`` for any origin
                        (credentials disabled). Specific origins enable credentials.

Start with:
    uvicorn intelligence.ocr.server:app --reload

The ``intelligence.ocr.api`` module re-exports this same ``app`` for one
entry point.
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

MAX_UPLOAD_BYTES = 50 * 1024 * 1024

try:
    from fastapi import FastAPI, File, HTTPException, Query, UploadFile
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


def _configure_cors(application: FastAPI) -> None:
    """Add CORS when ``OCR_CORS_ORIGINS`` is set.

    ``allow_origins=[\"*\"]`` is only used with ``allow_credentials=False``
    (browser-compatible).
    """
    raw = os.getenv("OCR_CORS_ORIGINS", "").strip()
    if not raw:
        return
    parts = [o.strip() for o in raw.split(",") if o.strip()]
    if not parts:
        return
    if parts == ["*"]:
        application.add_middleware(
            CORSMiddleware,
            allow_origins=["*"],
            allow_credentials=False,
            allow_methods=["*"],
            allow_headers=["*"],
        )
    else:
        application.add_middleware(
            CORSMiddleware,
            allow_origins=parts,
            allow_credentials=True,
            allow_methods=["*"],
            allow_headers=["*"],
        )


_configure_cors(app)


def _content_is_pdf_magic(content: bytes) -> bool:
    return len(content) >= 4 and content.startswith(b"%PDF")


def _accepts_as_pdf(filename: Optional[str], content: bytes) -> bool:
    if filename and filename.lower().endswith(".pdf"):
        return True
    return _content_is_pdf_magic(content)

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


async def _process_uploaded_pdf(
    file: UploadFile,
    start_page: Optional[int],
    end_page: Optional[int],
    detect_tables: bool,
    callback_url: Optional[str],
) -> JSONResponse:
    content = await file.read()
    if len(content) > MAX_UPLOAD_BYTES:
        raise HTTPException(
            status_code=413,
            detail=f"File exceeds maximum size of {MAX_UPLOAD_BYTES // (1024 * 1024)} MB",
        )
    if not _accepts_as_pdf(file.filename, content):
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
    except HTTPException:
        raise
    except Exception as e:
        logger.error("OCR processing failed: %s", e)
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass


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
    return await _process_uploaded_pdf(
        file, start_page, end_page, detect_tables, callback_url
    )


@app.get("/api/ocr/health")
async def legacy_api_health() -> dict:
    """Minimal health JSON for legacy ``/api/ocr/*`` clients."""
    return {"status": "ok", "service": "arabic-ocr-api"}


@app.post("/api/ocr/process")
async def legacy_api_process(
    file: UploadFile = File(...),
    start_page: Optional[int] = Query(None, ge=1),
    end_page: Optional[int] = Query(None, ge=1),
    detect_tables: bool = Query(True),
) -> JSONResponse:
    """Legacy PDF upload path (same behaviour as ``POST /ocr/pdf``)."""
    return await _process_uploaded_pdf(
        file, start_page, end_page, detect_tables, callback_url=None
    )


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

    content = await file.read()
    if len(content) > MAX_UPLOAD_BYTES:
        raise HTTPException(
            status_code=413,
            detail=f"File exceeds maximum size of {MAX_UPLOAD_BYTES // (1024 * 1024)} MB",
        )
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
        content = await file.read()
        if len(content) > MAX_UPLOAD_BYTES:
            all_results.append({
                "file": file.filename,
                "error": f"File exceeds maximum size of "
                f"{MAX_UPLOAD_BYTES // (1024 * 1024)} MB",
            })
            continue
        if not _accepts_as_pdf(file.filename, content):
            all_results.append({"error": f"Not a PDF: {file.filename}"})
            continue

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
