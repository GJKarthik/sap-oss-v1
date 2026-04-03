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
        assert data["status"] == "ok"
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


class TestCallbackValidation:
    def test_validate_callback_url_allowlist(self):
        old_hosts = os.environ.get("OCR_ALLOWED_CALLBACK_HOSTS")
        os.environ["OCR_ALLOWED_CALLBACK_HOSTS"] = "example.com"
        try:
            assert _validate_callback_url("https://example.com/hook").endswith("/hook")
            with pytest.raises(ValueError, match="allowlisted"):
                _validate_callback_url("https://evil.example/hook")
        finally:
            if old_hosts is None:
                os.environ.pop("OCR_ALLOWED_CALLBACK_HOSTS", None)
            else:
                os.environ["OCR_ALLOWED_CALLBACK_HOSTS"] = old_hosts
