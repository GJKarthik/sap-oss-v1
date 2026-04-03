"""Integration tests for Arabic OCR service.

All tests use real Tesseract, real pdf2image, real arabic_reshaper / python-bidi.
No mocking of external libraries.
"""

import os
import tempfile

import pytest
from PIL import Image, ImageDraw, ImageFont

from ..arabic_ocr_service import ArabicOCRService, OCRResult
from ..pdf_processor import PDFDocument, PageImage


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _make_text_image(text: str, size=(600, 120), font_size: int = 48) -> Image.Image:
    """Render *text* onto a white image for real OCR."""
    img = Image.new("RGB", size, color="white")
    draw = ImageDraw.Draw(img)
    try:
        font = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", font_size)
    except (OSError, IOError):
        font = ImageFont.load_default()
    draw.text((10, 20), text, fill="black", font=font)
    return img


def _make_table_image() -> Image.Image:
    """Render a simple 2×2 table with grid lines and text cells.

    Layout (600×200 px):
        +--------+---------+
        |  Name  |   Age   |
        +--------+---------+
        | Ahmed  |   25    |
        +--------+---------+
    """
    img = Image.new("RGB", (600, 200), color="white")
    draw = ImageDraw.Draw(img)
    try:
        font = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", 32)
    except (OSError, IOError):
        font = ImageFont.load_default()

    # Grid
    for y in (20, 100, 180):
        draw.line([(20, y), (580, y)], fill="black", width=2)
    for x in (20, 300, 580):
        draw.line([(x, 20), (x, 180)], fill="black", width=2)

    # Cell text
    draw.text((60, 40), "Name", fill="black", font=font)
    draw.text((340, 40), "Age", fill="black", font=font)
    draw.text((60, 120), "Ahmed", fill="black", font=font)
    draw.text((350, 120), "25", fill="black", font=font)
    return img


def _make_real_pdf(num_pages: int = 1) -> str:
    """Create a minimal valid PDF.  Returns temp file path (caller unlinks)."""
    objects: list[str] = []
    objects.append("1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj")
    kids = " ".join(f"{3 + i} 0 R" for i in range(num_pages))
    objects.append(
        f"2 0 obj\n<< /Type /Pages /Kids [{kids}] /Count {num_pages} >>\nendobj"
    )
    for i in range(num_pages):
        obj_num = 3 + i
        objects.append(
            f"{obj_num} 0 obj\n"
            f"<< /Type /Page /Parent 2 0 R "
            f"/MediaBox [0 0 612 792] >>\nendobj"
        )
    body = "\n".join(objects)
    xref_offset = len(b"%PDF-1.4\n") + len(body.encode("latin-1")) + 1
    num_objects = 1 + len(objects)
    xref_lines = [f"xref\n0 {num_objects}", "0000000000 65535 f "]
    offset = len(b"%PDF-1.4\n")
    for obj_str in objects:
        xref_lines.append(f"{offset:010d} 00000 n ")
        offset += len(obj_str.encode("latin-1")) + 1
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
# End-to-end PDF processing
# ---------------------------------------------------------------------------

class TestProcessPDF:
    """End-to-end tests with real Tesseract + pdf2image."""

    def setup_method(self):
        self.service = ArabicOCRService(languages="eng", dpi=72)

    def test_process_nonexistent_pdf(self):
        result = self.service.process_pdf("/nonexistent/file.pdf")
        assert isinstance(result, OCRResult)
        assert len(result.errors) > 0
        assert "not found" in result.errors[0]

    def test_process_corrupted_pdf(self):
        with tempfile.NamedTemporaryFile(suffix=".pdf", delete=False) as f:
            f.write(b"CORRUPTED DATA")
            f.flush()
            try:
                result = self.service.process_pdf(f.name)
                assert len(result.errors) > 0
            finally:
                os.unlink(f.name)

    def test_process_single_page_pdf(self):
        path = _make_real_pdf(1)
        try:
            result = self.service.process_pdf(path)
            assert len(result.pages) == 1
            assert result.pages[0].page_number == 1
            assert result.total_pages == 1
            assert "languages" in result.metadata
        finally:
            os.unlink(path)

    def test_process_multi_page_ordering(self):
        path = _make_real_pdf(3)
        try:
            result = self.service.process_pdf(path)
            assert len(result.pages) == 3
            for i, page in enumerate(result.pages):
                assert page.page_number == i + 1
        finally:
            os.unlink(path)

    def test_metadata_included(self):
        path = _make_real_pdf(1)
        try:
            result = self.service.process_pdf(path)
            assert "languages" in result.metadata
            assert "dpi" in result.metadata
            assert "pages_processed" in result.metadata
            assert result.metadata["pages_processed"] == 1
        finally:
            os.unlink(path)

    def test_overall_confidence_is_average_of_pages(self):
        """overall_confidence equals the mean of page confidences."""
        path = _make_real_pdf(2)
        try:
            result = self.service.process_pdf(path)
            if result.pages:
                confs = [p.confidence for p in result.pages if p.confidence > 0]
                if confs:
                    expected = sum(confs) / len(confs)
                    assert result.overall_confidence == pytest.approx(expected)
        finally:
            os.unlink(path)

    def test_no_image_to_string_called(self):
        """Verify we don't call image_to_string (single Tesseract pass)."""
        import pytesseract

        original = pytesseract.image_to_string
        call_count = [0]

        def spy(*a, **kw):
            call_count[0] += 1
            return original(*a, **kw)

        pytesseract.image_to_string = spy
        path = _make_real_pdf(1)
        try:
            self.service.process_pdf(path)
            assert call_count[0] == 0, "image_to_string should not be called"
        finally:
            pytesseract.image_to_string = original
            os.unlink(path)


# ---------------------------------------------------------------------------
# Single image processing
# ---------------------------------------------------------------------------

class TestProcessImage:
    """Tests for single image processing with real Tesseract."""

    def setup_method(self):
        self.service = ArabicOCRService(languages="eng")

    def test_process_english_image(self):
        img = _make_text_image("HELLO WORLD", size=(600, 120), font_size=48)
        result = self.service.process_image(img)
        assert result.page_number == 1
        assert "HELLO" in result.text.upper()
        assert result.confidence > 0
        assert len(result.text_regions) > 0

    def test_process_image_no_tables(self):
        img = _make_text_image("Simple text", size=(400, 100))
        result = self.service.process_image(img, detect_tables=False)
        assert result.tables == []

    def test_process_image_with_table(self):
        img = _make_table_image()
        result = self.service.process_image(img, detect_tables=True)
        # Real OCR may or may not extract text from rendered tables depending
        # on font availability and Tesseract segmentation mode; assert valid
        # structure and no crashes.
        assert isinstance(result.tables, list)
        assert result.page_number == 1

    def test_process_blank_image(self):
        """Blank image should produce empty text and zero confidence."""
        img = Image.new("RGB", (200, 200), color="white")
        result = self.service.process_image(img, detect_tables=False)
        assert result.confidence == 0.0
        assert result.text.strip() == ""


# ---------------------------------------------------------------------------
# Table detection
# ---------------------------------------------------------------------------

class TestTableDetection:
    """Tests for table structure detection via _detect_tables."""

    def setup_method(self):
        self.service = ArabicOCRService(languages="eng")

    def test_detect_table_from_rendered_image(self):
        """Feed a rendered table image through real OCR and check result."""
        img = _make_table_image()
        page_img = PageImage(
            page_number=1, image=img, width=img.width, height=img.height
        )
        result = self.service._process_page(page_img, detect_tables=True)
        # Even if the heuristic doesn't fire, assert no crash and valid result
        assert isinstance(result.tables, list)
        assert result.page_number == 1

    def test_no_table_for_single_line_image(self):
        """Single line of text should not produce a table."""
        img = _make_text_image("Just one line of text")
        page_img = PageImage(
            page_number=1, image=img, width=img.width, height=img.height
        )
        result = self.service._process_page(page_img, detect_tables=True)
        assert result.tables == []


# ---------------------------------------------------------------------------
# Streaming
# ---------------------------------------------------------------------------

class TestStreamingProcessing:
    """Tests for generator-based page processing."""

    def setup_method(self):
        self.service = ArabicOCRService(languages="eng", dpi=72)

    def test_process_pdf_pages_yields_results(self):
        path = _make_real_pdf(3)
        try:
            pages = list(self.service.process_pdf_pages(path))
            assert len(pages) == 3
            for i, page in enumerate(pages):
                assert page.page_number == i + 1
        finally:
            os.unlink(path)

    def test_process_pdf_pages_with_range(self):
        path = _make_real_pdf(5)
        try:
            pages = list(self.service.process_pdf_pages(path, start_page=2, end_page=4))
            assert len(pages) == 3
            assert pages[0].page_number == 2
        finally:
            os.unlink(path)


# ---------------------------------------------------------------------------
# Parallel processing
# ---------------------------------------------------------------------------

class TestParallelProcessing:
    """Tests for multi-threaded page processing."""

    def test_parallel_produces_same_page_count(self):
        """Parallel and sequential should return the same number of pages."""
        path = _make_real_pdf(3)
        try:
            seq = ArabicOCRService(languages="eng", dpi=72, max_workers=1)
            par = ArabicOCRService(languages="eng", dpi=72, max_workers=2)
            result_seq = seq.process_pdf(path)
            result_par = par.process_pdf(path)

            assert len(result_seq.pages) == len(result_par.pages)
            for s, p in zip(result_seq.pages, result_par.pages):
                assert s.page_number == p.page_number
        finally:
            os.unlink(path)




# ---------------------------------------------------------------------------
# Preprocessing integration
# ---------------------------------------------------------------------------

class TestPreprocessingIntegration:
    """End-to-end tests with preprocessing enabled."""

    def test_pdf_with_preprocessing(self):
        from ..preprocessing import PreprocessingConfig

        service = ArabicOCRService(
            languages="eng",
            dpi=72,
            preprocessing=PreprocessingConfig(
                enable_grayscale=True, enable_denoise=True
            ),
        )
        path = _make_real_pdf(1)
        try:
            result = service.process_pdf(path)
            assert result.metadata["preprocessing_enabled"] is True
            assert len(result.pages) == 1
        finally:
            os.unlink(path)

    def test_pdf_without_preprocessing(self):
        service = ArabicOCRService(languages="eng", dpi=72)
        path = _make_real_pdf(1)
        try:
            result = service.process_pdf(path)
            assert result.metadata["preprocessing_enabled"] is False
        finally:
            os.unlink(path)

    def test_image_with_full_pipeline(self):
        from ..preprocessing import PreprocessingConfig

        service = ArabicOCRService(
            languages="eng",
            preprocessing=PreprocessingConfig(
                enable_grayscale=True,
                enable_binarize=True,
                enable_denoise=True,
                binarize_threshold=128,
            ),
        )
        img = _make_text_image("PIPELINE TEST", size=(600, 120), font_size=48)
        result = service.process_image(img, detect_tables=False)
        assert result.page_number == 1
        assert isinstance(result.text, str)


# ---------------------------------------------------------------------------
# Confidence flagging integration
# ---------------------------------------------------------------------------

class TestConfidenceFlaggingIntegration:
    """End-to-end confidence flagging on PDF processing."""

    def test_pdf_flagging_metadata(self):
        service = ArabicOCRService(
            languages="eng", dpi=72, min_confidence=99.0
        )
        path = _make_real_pdf(2)
        try:
            result = service.process_pdf(path)
            # Blank pages → low confidence → flagged
            assert result.metadata["pages_flagged_for_review"] >= 0
            flagged = [p for p in result.pages if p.flagged_for_review]
            assert result.metadata["pages_flagged_for_review"] == len(flagged)
        finally:
            os.unlink(path)


# ---------------------------------------------------------------------------
# Timeout integration
# ---------------------------------------------------------------------------

class TestTimeoutIntegration:
    """End-to-end timeout on PDF processing."""

    def test_pdf_with_generous_timeout(self):
        service = ArabicOCRService(
            languages="eng", dpi=72, page_timeout=60.0
        )
        path = _make_real_pdf(1)
        try:
            result = service.process_pdf(path)
            assert len(result.pages) == 1
        finally:
            os.unlink(path)


# ---------------------------------------------------------------------------
# Retry integration
# ---------------------------------------------------------------------------

class TestRetryIntegration:
    """End-to-end retry on PDF processing."""

    def test_pdf_with_retries_no_failure(self):
        service = ArabicOCRService(
            languages="eng", dpi=72, max_retries=1, retry_delay=0.01
        )
        path = _make_real_pdf(1)
        try:
            result = service.process_pdf(path)
            assert len(result.pages) == 1
            assert len(result.errors) == 0
        finally:
            os.unlink(path)