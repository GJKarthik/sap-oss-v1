"""Dependency availability checker for the OCR module.

Reports which optional dependencies are installed and which features
they enable.  Use ``check_dependencies()`` to get a full status report.

Example::

    from intelligence.ocr.dependencies import check_dependencies
    status = check_dependencies()
    print(status)
"""

import importlib
import shutil
from dataclasses import dataclass, field
from typing import Dict, List


@dataclass
class DependencyStatus:
    """Status of a single dependency."""

    name: str
    available: bool
    version: str = ""
    features: List[str] = field(default_factory=list)
    note: str = ""


@dataclass
class DependencyReport:
    """Full dependency availability report."""

    dependencies: List[DependencyStatus] = field(default_factory=list)

    @property
    def all_available(self) -> bool:
        return all(d.available for d in self.dependencies)

    @property
    def missing(self) -> List[str]:
        return [d.name for d in self.dependencies if not d.available]

    def to_dict(self) -> Dict:
        return {
            "all_available": self.all_available,
            "missing": self.missing,
            "dependencies": [
                {
                    "name": d.name,
                    "available": d.available,
                    "version": d.version,
                    "features": d.features,
                    "note": d.note,
                }
                for d in self.dependencies
            ],
        }

    def __str__(self) -> str:
        lines = ["OCR Module Dependencies:"]
        for d in self.dependencies:
            icon = "✓" if d.available else "✗"
            ver = f" ({d.version})" if d.version else ""
            features = ", ".join(d.features) if d.features else ""
            note = f" — {d.note}" if d.note else ""
            lines.append(f"  {icon} {d.name}{ver}: {features}{note}")
        return "\n".join(lines)


def _check_module(name: str) -> tuple:
    """Try importing a module; return (available, version)."""
    try:
        mod = importlib.import_module(name)
        ver = getattr(mod, "__version__", getattr(mod, "VERSION", ""))
        return True, str(ver)
    except ImportError:
        return False, ""


def _check_binary(name: str) -> bool:
    """Check if a binary is on PATH."""
    return shutil.which(name) is not None


def _check_arabic_traineddata() -> bool:
    """Check if the Tesseract Arabic language pack (ara.traineddata) is installed."""
    import subprocess

    try:
        result = subprocess.run(
            ["tesseract", "--list-langs"],
            capture_output=True, text=True, timeout=10,
        )
        return "ara" in result.stdout.split()
    except (FileNotFoundError, subprocess.TimeoutExpired, OSError):
        return False


def check_dependencies() -> DependencyReport:
    """Check all dependencies and return a full report."""
    report = DependencyReport()

    # Required
    for name, features in [
        ("pytesseract", ["OCR text extraction"]),
        ("pdf2image", ["PDF to image conversion"]),
        ("PIL", ["Image processing (Pillow)"]),
        ("arabic_reshaper", ["Arabic text reshaping"]),
        ("bidi", ["Bidirectional text support (python-bidi)"]),
    ]:
        avail, ver = _check_module(name)
        report.dependencies.append(DependencyStatus(
            name=name, available=avail, version=ver, features=features,
            note="" if avail else "REQUIRED — core functionality will fail",
        ))

    # Optional
    avail_cv, ver_cv = _check_module("cv2")
    report.dependencies.append(DependencyStatus(
        name="cv2 (opencv)",
        available=avail_cv, version=ver_cv,
        features=["Line-based table detection", "Hough-line deskew"],
        note="" if avail_cv else "Optional — table detection falls back to heuristic",
    ))

    avail_np, ver_np = _check_module("numpy")
    report.dependencies.append(DependencyStatus(
        name="numpy",
        available=avail_np, version=ver_np,
        features=["Projection-profile deskew (fallback)"],
        note="" if avail_np else "Optional — deskew disabled without OpenCV or numpy",
    ))

    avail_rl, ver_rl = _check_module("reportlab")
    report.dependencies.append(DependencyStatus(
        name="reportlab",
        available=avail_rl, version=ver_rl,
        features=["Searchable PDF overlay export"],
        note="" if avail_rl else "Optional — to_searchable_pdf() will raise ImportError",
    ))

    avail_pypdf, ver_pypdf = _check_module("pypdf")
    if not avail_pypdf:
        avail_pypdf, ver_pypdf = _check_module("PyPDF2")
    report.dependencies.append(DependencyStatus(
        name="pypdf/PyPDF2",
        available=avail_pypdf,
        version=ver_pypdf,
        features=["Preserve original PDF pages in searchable PDF export"],
        note="" if avail_pypdf else (
            "Optional — searchable PDF export for PDF sources needs pypdf or PyPDF2"
        ),
    ))

    avail_fa, ver_fa = _check_module("fastapi")
    report.dependencies.append(DependencyStatus(
        name="fastapi",
        available=avail_fa, version=ver_fa,
        features=["REST API server"],
        note="" if avail_fa else "Optional — server.py requires fastapi + uvicorn",
    ))

    avail_multipart, ver_multipart = _check_module("multipart")
    report.dependencies.append(DependencyStatus(
        name="python-multipart",
        available=avail_multipart,
        version=ver_multipart,
        features=["Multipart file uploads for REST API"],
        note="" if avail_multipart else (
            "Optional — /ocr/pdf, /ocr/image, and /ocr/batch require python-multipart"
        ),
    ))

    avail_httpx, ver_httpx = _check_module("httpx")
    report.dependencies.append(DependencyStatus(
        name="httpx",
        available=avail_httpx,
        version=ver_httpx,
        features=["Webhook callback delivery"],
        note="" if avail_httpx else "Optional — callback_url delivery requires httpx",
    ))

    # System binaries
    tess_ok = _check_binary("tesseract")
    report.dependencies.append(DependencyStatus(
        name="tesseract (binary)",
        available=tess_ok,
        features=["OCR engine"],
        note="" if tess_ok else "REQUIRED — install via brew/apt",
    ))

    popp_ok = _check_binary("pdftoppm")
    report.dependencies.append(DependencyStatus(
        name="poppler (pdftoppm)",
        available=popp_ok,
        features=["PDF rendering for pdf2image"],
        note="" if popp_ok else "REQUIRED — install via brew/apt (poppler-utils)",
    ))

    # Arabic language pack
    ara_ok = _check_arabic_traineddata()
    report.dependencies.append(DependencyStatus(
        name="tesseract-ara (language pack)",
        available=ara_ok,
        features=["Arabic language OCR"],
        note="" if ara_ok else "Optional — Arabic OCR accuracy requires ara.traineddata",
    ))

    return report
