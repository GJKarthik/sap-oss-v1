"""Tests for the FastAPI REST server endpoints.

Uses FastAPI TestClient for real HTTP-level testing.
Skipped if FastAPI is not installed.
"""

import io
import json
import os
import tempfile

import pytest
from PIL import Image, ImageDraw, ImageFont

try:
    from fastapi.testclient import TestClient
    from ..server import _validate_callback_url, app

    HAS_FASTAPI = True
except ImportError:
    HAS_FASTAPI = False

pytestmark = pytest.mark.skipif(not HAS_FASTAPI, reason="FastAPI not installed")


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _make_text_image(text: str, size=(500, 100), font_size=48) -> Image.Image:
    img = Image.new("RGB", size, color="white")
    draw = ImageDraw.Draw(img)
    try:
        font = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", font_size)
    except (OSError, IOError):
        font = ImageFont.load_default()
    draw.text((10, 20), text, fill="black", font=font)
    return img


def _make_real_pdf(n=1) -> str:
    objects = []
    objects.append("1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj")
    kids = " ".join(f"{3+i} 0 R" for i in range(n))
    objects.append(f"2 0 obj\n<< /Type /Pages /Kids [{kids}] /Count {n} >>\nendobj")
    for i in range(n):
        objects.append(
            f"{3+i} 0 obj\n<< /Type /Page /Parent 2 0 R "
            f"/MediaBox [0 0 612 792] >>\nendobj"
        )
    body = "\n".join(objects)
    xref_offset = len(b"%PDF-1.4\n") + len(body.encode("latin-1")) + 1
    num_obj = 1 + len(objects)
    xref = [f"xref\n0 {num_obj}", "0000000000 65535 f "]
    off = len(b"%PDF-1.4\n")
    for o in objects:
        xref.append(f"{off:010d} 00000 n ")
        off += len(o.encode("latin-1")) + 1
    trailer = (
        f"trailer\n<< /Size {num_obj} /Root 1 0 R >>\n"
        f"startxref\n{xref_offset}\n%%EOF"
    )
    pdf = f"%PDF-1.4\n{body}\n" + "\n".join(xref) + f"\n{trailer}"
    f = tempfile.NamedTemporaryFile(suffix=".pdf", delete=False)
    f.write(pdf.encode("latin-1"))
    f.flush()
    f.close()
    return f.name


@pytest.fixture
def client():
    """Create a fresh TestClient for each test."""
    return TestClient(app)


# ---------------------------------------------------------------------------
# Health check
# ---------------------------------------------------------------------------

class TestHealthEndpoint:
    def test_health(self, client):
        resp = client.get("/ocr/health")
        assert resp.status_code == 200
        data = resp.json()
        assert data["status"] in ("healthy", "degraded")
        assert data["service"] == "arabic-ocr"


# ---------------------------------------------------------------------------
# PDF upload
# ---------------------------------------------------------------------------

class TestPDFEndpoint:
    def test_upload_pdf(self, client):
        path = _make_real_pdf(1)
        try:
            with open(path, "rb") as f:
                resp = client.post(
                    "/ocr/pdf",
                    files={"file": ("test.pdf", f, "application/pdf")},
                )
            assert resp.status_code == 200
            data = resp.json()
            assert "pages" in data
            assert len(data["pages"]) == 1
        finally:
            os.unlink(path)

    def test_upload_non_pdf_rejected(self, client):
        content = b"not a pdf"
        resp = client.post(
            "/ocr/pdf",
            files={"file": ("test.txt", io.BytesIO(content), "text/plain")},
        )
        assert resp.status_code == 400

    def test_upload_pdf_with_params(self, client):
        path = _make_real_pdf(2)
        try:
            with open(path, "rb") as f:
                resp = client.post(
                    "/ocr/pdf?start_page=1&end_page=1&detect_tables=false",
                    files={"file": ("test.pdf", f, "application/pdf")},
                )
            assert resp.status_code == 200
            data = resp.json()
            assert len(data["pages"]) == 1
        finally:
            os.unlink(path)

    def test_callback_url_rejected_without_allowlist(self, client):
        old_hosts = os.environ.pop("OCR_ALLOWED_CALLBACK_HOSTS", None)
        path = _make_real_pdf(1)
        try:
            with open(path, "rb") as f:
                resp = client.post(
                    "/ocr/pdf?callback_url=https://example.com/hook",
                    files={"file": ("test.pdf", f, "application/pdf")},
                )
            assert resp.status_code == 400
            assert "OCR_ALLOWED_CALLBACK_HOSTS" in resp.json()["detail"]
        finally:
            if old_hosts is not None:
                os.environ["OCR_ALLOWED_CALLBACK_HOSTS"] = old_hosts
            os.unlink(path)


# ---------------------------------------------------------------------------
# Image upload
# ---------------------------------------------------------------------------

class TestImageEndpoint:
    def test_upload_image(self, client):
        img = _make_text_image("SERVER TEST", size=(400, 80), font_size=36)
        buf = io.BytesIO()
        img.save(buf, format="PNG")
        buf.seek(0)
        resp = client.post(
            "/ocr/image",
            files={"file": ("test.png", buf, "image/png")},
        )
        assert resp.status_code == 200
        data = resp.json()
        assert data["page_number"] == 1
        assert "text" in data

    def test_upload_invalid_image(self, client):
        resp = client.post(
            "/ocr/image",
            files={"file": ("bad.png", io.BytesIO(b"not an image"), "image/png")},
        )
        assert resp.status_code == 400


# ---------------------------------------------------------------------------
# Legacy backwards-compatible endpoints
# ---------------------------------------------------------------------------

class TestLegacyEndpoints:
    def test_legacy_process_pdf(self, client):
        """The deprecated /api/ocr/process should still work."""
        path = _make_real_pdf(1)
        try:
            with open(path, "rb") as f:
                resp = client.post(
                    "/api/ocr/process",
                    files={"file": ("test.pdf", f, "application/pdf")},
                )
            assert resp.status_code == 200
            data = resp.json()
            assert "pages" in data
        finally:
            os.unlink(path)

    def test_legacy_health(self, client):
        """The deprecated /api/ocr/health should still work."""
        resp = client.get("/api/ocr/health")
        assert resp.status_code == 200
        data = resp.json()
        assert data["status"] in ("healthy", "degraded", "unhealthy")
        assert data["service"] == "arabic-ocr"


# ---------------------------------------------------------------------------
# CORS configuration
# ---------------------------------------------------------------------------

class TestCORSConfiguration:
    def test_no_wildcard_cors(self, client):
        """CORS should not allow wildcard origins by default."""
        resp = client.options(
            "/ocr/health",
            headers={"Origin": "http://evil.example", "Access-Control-Request-Method": "GET"},
        )
        # Without OCR_ALLOWED_ORIGINS set, no origin should be allowed
        assert resp.headers.get("access-control-allow-origin") != "*"


# ---------------------------------------------------------------------------
# Health check dependency coverage
# ---------------------------------------------------------------------------

class TestHealthDependencyCoverage:
    def test_health_checks_httpx(self, client):
        """Health endpoint should report httpx status."""
        resp = client.get("/ocr/health")
        data = resp.json()
        # The health endpoint uses check_dependencies(), which now includes httpx
        from ..dependencies import check_dependencies
        report = check_dependencies()
        dep_names = [d.name for d in report.dependencies]
        assert "httpx" in dep_names

    def test_health_checks_python_multipart(self, client):
        """Health endpoint should report python-multipart status."""
        from ..dependencies import check_dependencies
        report = check_dependencies()
        dep_names = [d.name for d in report.dependencies]
        assert "python-multipart" in dep_names

    def test_health_checks_arabic_lang_pack(self, client):
        """Health endpoint should report Arabic language pack status."""
        from ..dependencies import check_dependencies
        report = check_dependencies()
        dep_names = [d.name for d in report.dependencies]
        assert "tesseract-ara (language pack)" in dep_names


class TestCallbackValidation:
    def test_validate_callback_url_allowlist(self):
        import socket
        import unittest.mock as mock

        # Mock DNS resolution so this test doesn't depend on real network access
        fake_addrinfo = [
            (socket.AF_INET, socket.SOCK_STREAM, 6, "", ("93.184.216.34", 0)),
        ]

        old_hosts = os.environ.get("OCR_ALLOWED_CALLBACK_HOSTS")
        os.environ["OCR_ALLOWED_CALLBACK_HOSTS"] = "example.com"
        try:
            with mock.patch("socket.getaddrinfo", return_value=fake_addrinfo):
                assert _validate_callback_url("https://example.com/hook").endswith("/hook")
            with pytest.raises(ValueError, match="allowlisted"):
                _validate_callback_url("https://evil.example/hook")
        finally:
            if old_hosts is None:
                os.environ.pop("OCR_ALLOWED_CALLBACK_HOSTS", None)
            else:
                os.environ["OCR_ALLOWED_CALLBACK_HOSTS"] = old_hosts



# ---------------------------------------------------------------------------
# Metrics deadlock
# ---------------------------------------------------------------------------

class TestMetricsDeadlock:
    """Verify that to_prometheus() and to_dict() don't deadlock."""

    def test_to_prometheus_no_deadlock(self):
        from ..metrics import OCRMetrics
        m = OCRMetrics()
        m.record_page(0.95, 1.2)
        m.record_document()
        result = m.to_prometheus()
        assert "ocr_pages_processed_total 1" in result
        assert "ocr_confidence_avg 0.95" in result

    def test_to_dict_no_deadlock(self):
        from ..metrics import OCRMetrics
        m = OCRMetrics()
        m.record_page(0.90, 0.5)
        m.record_page(0.80, 1.0)
        d = m.to_dict()
        assert d["pages_processed"] == 2
        assert d["avg_confidence"] == 0.85

    def test_to_prometheus_and_to_dict_threaded(self):
        """Call to_prometheus and to_dict from multiple threads to stress-test."""
        import threading
        from ..metrics import OCRMetrics

        m = OCRMetrics()
        for i in range(10):
            m.record_page(0.9, 0.1 * i)

        errors = []

        def call_prometheus():
            try:
                m.to_prometheus()
            except Exception as e:
                errors.append(e)

        def call_to_dict():
            try:
                m.to_dict()
            except Exception as e:
                errors.append(e)

        threads = []
        for _ in range(5):
            threads.append(threading.Thread(target=call_prometheus))
            threads.append(threading.Thread(target=call_to_dict))
        for t in threads:
            t.start()
        for t in threads:
            t.join(timeout=5)

        assert not errors
        # All threads must have completed (not hung)
        for t in threads:
            assert not t.is_alive(), "Thread is still alive — possible deadlock"


# ---------------------------------------------------------------------------
# SSRF — batch endpoint callback validation
# ---------------------------------------------------------------------------

class TestBatchCallbackSSRF:
    def test_batch_rejects_callback_without_allowlist(self, client):
        """Batch endpoint must validate callback_url."""
        old_hosts = os.environ.pop("OCR_ALLOWED_CALLBACK_HOSTS", None)
        path = _make_real_pdf(1)
        try:
            with open(path, "rb") as f:
                resp = client.post(
                    "/ocr/batch?callback_url=http://127.0.0.1:1234",
                    files=[("files", ("test.pdf", f, "application/pdf"))],
                )
            assert resp.status_code == 400
        finally:
            if old_hosts is not None:
                os.environ["OCR_ALLOWED_CALLBACK_HOSTS"] = old_hosts
            os.unlink(path)

    def test_batch_rejects_metadata_endpoint(self, client):
        """Batch endpoint must reject cloud metadata SSRF targets."""
        old_hosts = os.environ.pop("OCR_ALLOWED_CALLBACK_HOSTS", None)
        path = _make_real_pdf(1)
        try:
            with open(path, "rb") as f:
                resp = client.post(
                    "/ocr/batch?callback_url=http://169.254.169.254/latest/meta-data",
                    files=[("files", ("test.pdf", f, "application/pdf"))],
                )
            assert resp.status_code == 400
        finally:
            if old_hosts is not None:
                os.environ["OCR_ALLOWED_CALLBACK_HOSTS"] = old_hosts
            os.unlink(path)


# ---------------------------------------------------------------------------
# Upload size enforcement
# ---------------------------------------------------------------------------

class TestUploadSizeLimit:
    def test_pdf_oversized_rejected(self, client):
        """PDF upload > 50 MB must return 413."""
        from ..server import MAX_UPLOAD_SIZE
        # Create content just over the limit
        oversized = b"%PDF-1.4 " + b"X" * (MAX_UPLOAD_SIZE + 1)
        resp = client.post(
            "/ocr/pdf",
            files={"file": ("big.pdf", io.BytesIO(oversized), "application/pdf")},
        )
        assert resp.status_code == 413

    def test_image_oversized_rejected(self, client):
        """Image upload > 50 MB must return 413."""
        from ..server import MAX_UPLOAD_SIZE
        oversized = b"\x89PNG" + b"X" * (MAX_UPLOAD_SIZE + 1)
        resp = client.post(
            "/ocr/image",
            files={"file": ("big.png", io.BytesIO(oversized), "image/png")},
        )
        assert resp.status_code == 413

    def test_batch_oversized_rejected(self, client):
        """Batch upload with oversized file must return 413."""
        from ..server import MAX_UPLOAD_SIZE
        oversized = b"%PDF-1.4 " + b"X" * (MAX_UPLOAD_SIZE + 1)
        resp = client.post(
            "/ocr/batch",
            files=[("files", ("big.pdf", io.BytesIO(oversized), "application/pdf"))],
        )
        assert resp.status_code == 413



# ---------------------------------------------------------------------------
# DNS rebinding SSRF protection
# ---------------------------------------------------------------------------

class TestDNSRebindingProtection:
    def test_callback_rejects_loopback_resolution(self):
        """callback_url that resolves to 127.0.0.1 must be rejected."""
        old_hosts = os.environ.get("OCR_ALLOWED_CALLBACK_HOSTS")
        # Allowlist 'localhost' explicitly — DNS resolution should still block it
        os.environ["OCR_ALLOWED_CALLBACK_HOSTS"] = "localhost"
        try:
            with pytest.raises(ValueError, match="private/loopback"):
                _validate_callback_url("https://localhost/hook")
        finally:
            if old_hosts is None:
                os.environ.pop("OCR_ALLOWED_CALLBACK_HOSTS", None)
            else:
                os.environ["OCR_ALLOWED_CALLBACK_HOSTS"] = old_hosts

    def test_callback_rejects_unresolvable_host(self):
        """callback_url with an unresolvable hostname must be rejected."""
        old_hosts = os.environ.get("OCR_ALLOWED_CALLBACK_HOSTS")
        os.environ["OCR_ALLOWED_CALLBACK_HOSTS"] = "this-host-does-not-exist-12345.invalid"
        try:
            with pytest.raises(ValueError, match="could not be resolved"):
                _validate_callback_url("https://this-host-does-not-exist-12345.invalid/hook")
        finally:
            if old_hosts is None:
                os.environ.pop("OCR_ALLOWED_CALLBACK_HOSTS", None)
            else:
                os.environ["OCR_ALLOWED_CALLBACK_HOSTS"] = old_hosts


# ---------------------------------------------------------------------------
# Streaming upload read
# ---------------------------------------------------------------------------

class TestStreamingUploadRead:
    @pytest.mark.asyncio
    async def test_read_with_limit_rejects_oversized(self):
        """_read_with_limit should reject data exceeding max_size during streaming."""
        from ..server import _read_with_limit
        from fastapi import UploadFile, HTTPException

        content = b"X" * 1024  # 1 KB
        upload = UploadFile(file=io.BytesIO(content), filename="test.bin")
        with pytest.raises(HTTPException) as exc_info:
            await _read_with_limit(upload, 512)  # limit to 512 bytes
        assert exc_info.value.status_code == 413

    @pytest.mark.asyncio
    async def test_read_with_limit_accepts_within_limit(self):
        """_read_with_limit should return data within the size limit."""
        from ..server import _read_with_limit
        from fastapi import UploadFile

        content = b"X" * 256
        upload = UploadFile(file=io.BytesIO(content), filename="test.bin")
        result = await _read_with_limit(upload, 512)
        assert result == content


# ---------------------------------------------------------------------------
# Health endpoint degraded status
# ---------------------------------------------------------------------------

class TestHealthDegradedStatus:
    def test_health_returns_degraded_when_optional_missing(self, client):
        """Health should return degraded with unavailable_features when optional deps missing."""
        import unittest.mock as mock
        from ..dependencies import DependencyReport, DependencyStatus
        from .. import dependencies as deps_mod

        fake_report = DependencyReport(dependencies=[
            DependencyStatus(name="pytesseract", available=True, features=["OCR"], note=""),
            DependencyStatus(name="httpx", available=False, features=["Webhook delivery"],
                             note="Optional — webhook callbacks will be skipped"),
        ])

        with mock.patch.object(deps_mod, "check_dependencies", return_value=fake_report):
            resp = client.get("/ocr/health")
        data = resp.json()
        assert resp.status_code == 200
        assert data["status"] == "degraded"
        assert "Webhook delivery" in data.get("unavailable_features", [])

    def test_health_returns_unhealthy_503_when_required_missing(self, client):
        """Health should return 503 unhealthy when required deps are missing."""
        import unittest.mock as mock
        from ..dependencies import DependencyReport, DependencyStatus
        from .. import dependencies as deps_mod

        fake_report = DependencyReport(dependencies=[
            DependencyStatus(name="pytesseract", available=False, features=["OCR"],
                             note="REQUIRED — core functionality will fail"),
        ])

        with mock.patch.object(deps_mod, "check_dependencies", return_value=fake_report):
            resp = client.get("/ocr/health")
        data = resp.json()
        assert resp.status_code == 503
        assert data["status"] == "unhealthy"
        assert "pytesseract" in data["missing_required"]


# ---------------------------------------------------------------------------
# Metrics plain Lock (no re-entrancy)
# ---------------------------------------------------------------------------

class TestMetricsPlainLock:
    def test_uses_plain_lock(self):
        """Metrics should use threading.Lock, not RLock."""
        import threading
        from ..metrics import OCRMetrics

        m = OCRMetrics()
        assert type(m._lock) is threading.Lock

    def test_to_prometheus_completes_instantly(self):
        """to_prometheus must not re-enter avg_confidence (would deadlock with Lock)."""
        from ..metrics import OCRMetrics

        m = OCRMetrics()
        m.record_page(0.95, 1.0)
        # If this deadlocks, the test will time out
        result = m.to_prometheus()
        assert "ocr_confidence_avg 0.95" in result

    def test_to_dict_completes_instantly(self):
        """to_dict must not re-enter avg_confidence (would deadlock with Lock)."""
        from ..metrics import OCRMetrics

        m = OCRMetrics()
        m.record_page(0.90, 0.5)
        d = m.to_dict()
        assert d["avg_confidence"] == 0.9
