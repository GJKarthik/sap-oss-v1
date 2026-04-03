"""Tests for PDF processor module.

Uses real pdf2image and Pillow — no mocking of external libraries.
A real minimal PDF is generated for conversion tests.
"""

import os
import tempfile

import pytest
from PIL import Image

from ..pdf_processor import MAX_DPI, MIN_DPI, PDFDocument, PDFProcessor, PageImage


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _make_real_pdf(num_pages: int = 1) -> str:
    """Create a real (minimal but valid) PDF file with *num_pages* blank pages.

    Returns the temporary file path.  Caller must unlink when done.
    """
    # Build a tiny valid PDF by hand — each page is 612x792 (US Letter).
    objects: list[str] = []
    # Obj 1 – Catalog
    objects.append("1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj")
    # Obj 2 – Pages
    kids = " ".join(f"{3 + i} 0 R" for i in range(num_pages))
    objects.append(
        f"2 0 obj\n<< /Type /Pages /Kids [{kids}] /Count {num_pages} >>\nendobj"
    )
    # Obj 3..3+N-1 – individual Page objects
    for i in range(num_pages):
        obj_num = 3 + i
        objects.append(
            f"{obj_num} 0 obj\n"
            f"<< /Type /Page /Parent 2 0 R "
            f"/MediaBox [0 0 612 792] >>\nendobj"
        )
    body = "\n".join(objects)
    xref_offset = len(b"%PDF-1.4\n") + len(body.encode("latin-1")) + 1
    num_objects = 1 + len(objects)  # +1 for free entry
    xref_lines = [f"xref\n0 {num_objects}", "0000000000 65535 f "]
    offset = len(b"%PDF-1.4\n")
    for obj_str in objects:
        xref_lines.append(f"{offset:010d} 00000 n ")
        offset += len(obj_str.encode("latin-1")) + 1  # +1 for \n
    xref_section = "\n".join(xref_lines)
    trailer = (
        f"trailer\n<< /Size {num_objects} /Root 1 0 R >>\n"
        f"startxref\n{xref_offset}\n%%EOF"
    )
    pdf_bytes = f"%PDF-1.4\n{body}\n{xref_section}\n{trailer}".encode("latin-1")

    f = tempfile.NamedTemporaryFile(suffix=".pdf", delete=False)
    f.write(pdf_bytes)
    f.flush()
    f.close()
    return f.name


# ---------------------------------------------------------------------------
# Init / DPI validation
# ---------------------------------------------------------------------------

class TestPDFProcessorInit:
    """Tests for processor initialization and validation."""

    def test_default_config(self):
        processor = PDFProcessor()
        assert processor.dpi == 300
        assert processor.image_format == "PNG"

    def test_custom_config(self):
        processor = PDFProcessor(dpi=150, image_format="JPEG")
        assert processor.dpi == 150
        assert processor.image_format == "JPEG"

    def test_dpi_too_low(self):
        with pytest.raises(ValueError, match="dpi must be an integer"):
            PDFProcessor(dpi=10)

    def test_dpi_too_high(self):
        with pytest.raises(ValueError, match="dpi must be an integer"):
            PDFProcessor(dpi=2000)

    def test_dpi_zero(self):
        with pytest.raises(ValueError, match="dpi must be an integer"):
            PDFProcessor(dpi=0)

    def test_dpi_negative(self):
        with pytest.raises(ValueError, match="dpi must be an integer"):
            PDFProcessor(dpi=-100)

    def test_dpi_boundary_min(self):
        processor = PDFProcessor(dpi=MIN_DPI)
        assert processor.dpi == MIN_DPI

    def test_dpi_boundary_max(self):
        processor = PDFProcessor(dpi=MAX_DPI)
        assert processor.dpi == MAX_DPI


# ---------------------------------------------------------------------------
# File validation
# ---------------------------------------------------------------------------

class TestPDFProcessorValidation:
    """Tests for PDF file validation."""

    def setup_method(self):
        self.processor = PDFProcessor(dpi=150)

    def test_validate_nonexistent_file(self):
        with pytest.raises(FileNotFoundError, match="not found"):
            self.processor.validate_pdf("/nonexistent/file.pdf")

    def test_validate_non_pdf_extension(self):
        with tempfile.NamedTemporaryFile(suffix=".txt", delete=False) as f:
            f.write(b"not a pdf")
            f.flush()
            try:
                with pytest.raises(ValueError, match="does not have .pdf extension"):
                    self.processor.validate_pdf(f.name)
            finally:
                os.unlink(f.name)

    def test_validate_empty_file(self):
        with tempfile.NamedTemporaryFile(suffix=".pdf", delete=False) as f:
            f.flush()
            try:
                with pytest.raises(ValueError, match="empty"):
                    self.processor.validate_pdf(f.name)
            finally:
                os.unlink(f.name)

    def test_validate_invalid_header(self):
        with tempfile.NamedTemporaryFile(suffix=".pdf", delete=False) as f:
            f.write(b"NOT A PDF FILE CONTENT")
            f.flush()
            try:
                with pytest.raises(
                    ValueError, match="does not appear to be a valid PDF"
                ):
                    self.processor.validate_pdf(f.name)
            finally:
                os.unlink(f.name)

    def test_validate_valid_pdf_header(self):
        path = _make_real_pdf(1)
        try:
            self.processor.validate_pdf(path)  # should not raise
        finally:
            os.unlink(path)


# ---------------------------------------------------------------------------
# Page range validation
# ---------------------------------------------------------------------------

class TestPageRangeValidation:
    """Tests for page range argument validation."""

    def setup_method(self):
        self.processor = PDFProcessor(dpi=150)

    def test_valid_range(self):
        self.processor._validate_page_range(1, 10)

    def test_start_page_zero(self):
        with pytest.raises(ValueError, match="start_page must be >= 1"):
            self.processor._validate_page_range(0, 5)

    def test_start_page_negative(self):
        with pytest.raises(ValueError, match="start_page must be >= 1"):
            self.processor._validate_page_range(-1, 5)

    def test_end_page_zero(self):
        with pytest.raises(ValueError, match="end_page must be >= 1"):
            self.processor._validate_page_range(1, 0)

    def test_start_greater_than_end(self):
        with pytest.raises(ValueError, match="start_page.*must be <= end_page"):
            self.processor._validate_page_range(5, 2)

    def test_none_values_accepted(self):
        self.processor._validate_page_range(None, None)
        self.processor._validate_page_range(None, 5)
        self.processor._validate_page_range(3, None)


# ---------------------------------------------------------------------------
# Real PDF → image conversion
# ---------------------------------------------------------------------------

class TestPDFProcessorProcess:
    """Tests for PDF to image conversion using real pdf2image + poppler."""

    def setup_method(self):
        self.processor = PDFProcessor(dpi=72)  # low DPI for speed

    def test_process_single_page(self):
        path = _make_real_pdf(1)
        try:
            doc = self.processor.process(path)
            assert isinstance(doc, PDFDocument)
            assert len(doc.pages) == 1
            assert doc.pages_processed == 1
            assert doc.pages[0].page_number == 1
            assert doc.pages[0].width > 0
            assert doc.pages[0].height > 0
            assert isinstance(doc.pages[0].image, Image.Image)
        finally:
            os.unlink(path)

    def test_process_multi_page(self):
        path = _make_real_pdf(3)
        try:
            doc = self.processor.process(path)
            assert doc.pages_processed == 3
            assert len(doc.pages) == 3
            for i, page in enumerate(doc.pages):
                assert page.page_number == i + 1
        finally:
            os.unlink(path)

    def test_process_page_range(self):
        path = _make_real_pdf(5)
        try:
            doc = self.processor.process(path, start_page=2, end_page=4)
            assert doc.pages_processed == 3
            assert doc.pages[0].page_number == 2
            assert doc.pages[2].page_number == 4
        finally:
            os.unlink(path)

    def test_total_pages_reflects_real_document(self):
        path = _make_real_pdf(5)
        try:
            doc = self.processor.process(path, start_page=2, end_page=3)
            assert doc.total_pages == 5  # real page count
            assert doc.pages_processed == 2
        finally:
            os.unlink(path)

    def test_process_invalid_page_range(self):
        path = _make_real_pdf(1)
        try:
            with pytest.raises(ValueError, match="start_page.*must be <= end_page"):
                self.processor.process(path, start_page=5, end_page=2)
        finally:
            os.unlink(path)


# ---------------------------------------------------------------------------
# Context manager / resource cleanup
# ---------------------------------------------------------------------------

class TestPDFDocumentContextManager:
    """Tests for PDFDocument resource management."""

    def test_context_manager_closes_images(self):
        img = Image.new("RGB", (100, 200))
        page = PageImage(page_number=1, image=img, width=100, height=200)
        doc = PDFDocument(file_path="/test.pdf", total_pages=1, pages=[page])

        with doc:
            assert doc.pages[0].image is not None

    def test_close_releases_pages(self):
        imgs = [Image.new("RGB", (100, 200)) for _ in range(3)]
        pages = [
            PageImage(page_number=i + 1, image=img, width=100, height=200)
            for i, img in enumerate(imgs)
        ]
        doc = PDFDocument(file_path="/test.pdf", total_pages=3, pages=pages)
        doc.close()
        doc.close()  # double close must not raise

    def test_real_pdf_with_context_manager(self):
        path = _make_real_pdf(2)
        processor = PDFProcessor(dpi=72)
        try:
            with processor.process(path) as doc:
                assert len(doc.pages) == 2
        finally:
            os.unlink(path)


# ---------------------------------------------------------------------------
# Streaming generator
# ---------------------------------------------------------------------------

class TestProcessPagesGenerator:
    """Tests for the streaming page generator."""

    def setup_method(self):
        self.processor = PDFProcessor(dpi=72)

    def test_process_pages_yields_all(self):
        path = _make_real_pdf(3)
        try:
            pages = list(self.processor.process_pages(path))
            assert len(pages) == 3
            for i, page in enumerate(pages):
                assert page.page_number == i + 1
                assert isinstance(page.image, Image.Image)
        finally:
            os.unlink(path)

    def test_process_pages_with_range(self):
        path = _make_real_pdf(5)
        try:
            pages = list(self.processor.process_pages(path, start_page=2, end_page=4))
            assert len(pages) == 3
            assert pages[0].page_number == 2
        finally:
            os.unlink(path)


# ---------------------------------------------------------------------------
# PageImage dataclass
# ---------------------------------------------------------------------------

class TestPageImage:
    """Tests for PageImage dataclass."""

    def test_page_image_creation(self):
        img = Image.new("RGB", (100, 200))
        page = PageImage(page_number=1, image=img, width=100, height=200, dpi=300)
        assert page.page_number == 1
        assert page.width == 100
        assert page.height == 200
        assert page.dpi == 300

    def test_page_image_default_dpi(self):
        img = Image.new("RGB", (100, 200))
        page = PageImage(page_number=1, image=img, width=100, height=200)
        assert page.dpi == 300

    def test_page_image_close(self):
        img = Image.new("RGB", (100, 200))
        page = PageImage(page_number=1, image=img, width=100, height=200)
        page.close()
        page.close()  # double close must not raise




# ---------------------------------------------------------------------------
# Path sanitization
# ---------------------------------------------------------------------------

class TestPathSanitization:
    """Tests for path canonicalization and allowed_dirs whitelist."""

    def test_sanitize_resolves_symlinks(self):
        path = _make_real_pdf(1)
        try:
            processor = PDFProcessor(dpi=72)
            sanitized = processor.sanitize_path(path)
            assert os.path.isabs(sanitized)
            assert sanitized == os.path.realpath(path)
        finally:
            os.unlink(path)

    def test_sanitize_allowed_dirs_pass(self):
        path = _make_real_pdf(1)
        try:
            allowed = [os.path.dirname(path)]
            processor = PDFProcessor(dpi=72, allowed_dirs=allowed)
            sanitized = processor.sanitize_path(path)
            assert sanitized == os.path.realpath(path)
        finally:
            os.unlink(path)

    def test_sanitize_allowed_dirs_reject(self):
        path = _make_real_pdf(1)
        try:
            processor = PDFProcessor(dpi=72, allowed_dirs=["/nonexistent/dir"])
            with pytest.raises(ValueError, match="outside allowed directories"):
                processor.sanitize_path(path)
        finally:
            os.unlink(path)

    def test_sanitize_no_whitelist(self):
        """When allowed_dirs is None, all paths are accepted."""
        path = _make_real_pdf(1)
        try:
            processor = PDFProcessor(dpi=72, allowed_dirs=None)
            sanitized = processor.sanitize_path(path)
            assert sanitized == os.path.realpath(path)
        finally:
            os.unlink(path)


# ---------------------------------------------------------------------------
# Password-protected PDF detection
# ---------------------------------------------------------------------------

class TestEncryptedPDF:
    """Tests for encrypted/password-protected PDF handling."""

    def test_unencrypted_pdf_passes(self):
        path = _make_real_pdf(1)
        try:
            processor = PDFProcessor(dpi=72)
            processor.validate_pdf(path)  # should not raise
        finally:
            os.unlink(path)

    def test_encrypted_pdf_rejected_without_password(self):
        """A PDF with /Encrypt marker is rejected when no password is set."""
        path = _make_encrypted_pdf()
        try:
            processor = PDFProcessor(dpi=72)
            with pytest.raises(ValueError, match="password-protected"):
                processor.validate_pdf(path)
        finally:
            os.unlink(path)

    def test_encrypted_pdf_accepted_with_password(self):
        """A PDF with /Encrypt marker is accepted when a password is set."""
        path = _make_encrypted_pdf()
        try:
            processor = PDFProcessor(dpi=72, password="secret")
            # validate_pdf should not raise
            processor.validate_pdf(path)
        finally:
            os.unlink(path)

    def test_password_passed_to_convert(self):
        """Password kwarg is included in the convert call."""
        processor = PDFProcessor(dpi=72, password="mypass")
        kwargs = processor._build_convert_kwargs()
        assert kwargs["userpw"] == "mypass"

    def test_no_password_no_userpw_key(self):
        processor = PDFProcessor(dpi=72)
        kwargs = processor._build_convert_kwargs()
        assert "userpw" not in kwargs


def _make_encrypted_pdf() -> str:
    """Create a minimal PDF file that contains an /Encrypt marker.

    This is NOT a truly encrypted PDF — it just has the marker in the
    trailer to trigger the detection heuristic.
    """
    content = (
        b"%PDF-1.4\n"
        b"1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n"
        b"2 0 obj\n<< /Type /Pages /Kids [] /Count 0 >>\nendobj\n"
        b"trailer\n<< /Root 1 0 R /Encrypt << /V 1 >> >>\n"
        b"%%EOF"
    )
    f = tempfile.NamedTemporaryFile(suffix=".pdf", delete=False)
    f.write(content)
    f.flush()
    f.close()
    return f.name
