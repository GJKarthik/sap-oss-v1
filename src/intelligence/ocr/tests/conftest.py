"""Shared fixtures and configuration for OCR integration tests."""

import shutil
import tempfile
import os

import pytest


def _tesseract_available() -> bool:
    """Check if Tesseract OCR is installed and has Arabic language support."""
    if not shutil.which("tesseract"):
        return False
    try:
        import subprocess

        result = subprocess.run(
            ["tesseract", "--list-langs"],
            capture_output=True,
            text=True,
            timeout=10,
        )
        return "ara" in result.stdout
    except Exception:
        return False


def _pdf_dependencies_available() -> bool:
    """Check if pdf2image and poppler are available."""
    try:
        from pdf2image import convert_from_path

        return True
    except ImportError:
        return False


TESSERACT_AVAILABLE = _tesseract_available()
PDF_DEPS_AVAILABLE = _pdf_dependencies_available()

SKIP_REASON = (
    "Integration tests require Tesseract with Arabic language pack (ara) "
    "and pdf2image with poppler. Install Tesseract and run: "
    "brew install tesseract tesseract-lang poppler (macOS) or "
    "apt-get install tesseract-ocr tesseract-ocr-ara poppler-utils (Ubuntu)"
)


def pytest_configure(config):
    """Register custom markers."""
    config.addinivalue_line(
        "markers",
        "integration: mark test as integration test requiring Tesseract OCR",
    )


requires_tesseract = pytest.mark.skipif(
    not (TESSERACT_AVAILABLE and PDF_DEPS_AVAILABLE),
    reason=SKIP_REASON,
)


@pytest.fixture
def temp_dir():
    """Provide a temporary directory that is cleaned up after the test."""
    d = tempfile.mkdtemp()
    yield d
    import shutil as _shutil

    _shutil.rmtree(d, ignore_errors=True)
