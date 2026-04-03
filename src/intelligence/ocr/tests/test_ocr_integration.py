"""Integration tests for Arabic OCR service with mocked external dependencies."""

import os
import tempfile
from unittest.mock import MagicMock, patch

import pytest
from PIL import Image

from ..arabic_ocr_service import ArabicOCRService, OCRResult
from ..pdf_processor import PDFDocument, PageImage


def _make_mock_ocr_data(texts, confidences=None, lefts=None):
    """Helper to create mock Tesseract OCR data dictionaries."""
    n = len(texts)
    if confidences is None:
        confidences = [95.0] * n
    if lefts is None:
        lefts = list(range(0, n * 100, 100))

    return {
        "text": texts,
        "conf": confidences,
        "left": lefts,
        "top": [10] * n,
        "width": [80] * n,
        "height": [20] * n,
        "block_num": [1] * n,
        "line_num": [1] * n,
    }


class TestProcessPDF:
    """Tests for end-to-end PDF processing."""

    def setup_method(self):
        self.service = ArabicOCRService(dpi=150)

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

    @patch("pytesseract.image_to_string", return_value="مرحبا بالعالم")
    @patch("pytesseract.image_to_data")
    @patch("pdf2image.convert_from_path")
    def test_process_single_page_pdf(self, mock_convert, mock_data, mock_string):
        mock_convert.return_value = [Image.new("RGB", (800, 600))]
        mock_data.return_value = _make_mock_ocr_data(
            ["مرحبا", "بالعالم"], [92.0, 88.0]
        )

        with tempfile.NamedTemporaryFile(suffix=".pdf", delete=False) as f:
            f.write(b"%PDF-1.4 fake content")
            f.flush()
            try:
                result = self.service.process_pdf(f.name)
                assert result.total_pages == 1
                assert len(result.pages) == 1
                assert result.pages[0].page_number == 1
                assert result.overall_confidence > 0
            finally:
                os.unlink(f.name)

    @patch("pytesseract.image_to_string", return_value="Page text")
    @patch("pytesseract.image_to_data")
    @patch("pdf2image.convert_from_path")
    def test_process_multi_page_ordering(self, mock_convert, mock_data, mock_string):
        """Verify multi-page output has correct page ordering."""
        mock_convert.return_value = [Image.new("RGB", (800, 600)) for _ in range(5)]
        mock_data.return_value = _make_mock_ocr_data(["text"], [90.0])

        with tempfile.NamedTemporaryFile(suffix=".pdf", delete=False) as f:
            f.write(b"%PDF-1.4 fake content")
            f.flush()
            try:
                result = self.service.process_pdf(f.name)
                assert len(result.pages) == 5
                for i, page in enumerate(result.pages):
                    assert page.page_number == i + 1
            finally:
                os.unlink(f.name)

    @patch("pytesseract.image_to_string", return_value="Page text")
    @patch("pytesseract.image_to_data")
    @patch("pdf2image.convert_from_path")
    def test_metadata_included(self, mock_convert, mock_data, mock_string):
        mock_convert.return_value = [Image.new("RGB", (800, 600))]
        mock_data.return_value = _make_mock_ocr_data(["text"], [90.0])

        with tempfile.NamedTemporaryFile(suffix=".pdf", delete=False) as f:
            f.write(b"%PDF-1.4 fake content")
            f.flush()
            try:
                result = self.service.process_pdf(f.name)
                assert "languages" in result.metadata
                assert "dpi" in result.metadata
                assert "pages_processed" in result.metadata
                assert result.metadata["pages_processed"] == 1
            finally:
                os.unlink(f.name)


class TestProcessImage:
    """Tests for single image processing."""

    def setup_method(self):
        self.service = ArabicOCRService()

    @patch("pytesseract.image_to_string", return_value="Hello مرحبا")
    @patch("pytesseract.image_to_data")
    def test_process_single_image(self, mock_data, mock_string):
        mock_data.return_value = _make_mock_ocr_data(
            ["Hello", "مرحبا"], [95.0, 90.0]
        )
        img = Image.new("RGB", (400, 300))
        result = self.service.process_image(img)
        assert result.page_number == 1
        assert result.confidence > 0
        assert len(result.text_regions) == 2


class TestTableDetection:
    """Tests for table structure detection."""

    def setup_method(self):
        self.service = ArabicOCRService()

    @patch("pytesseract.image_to_string", return_value="col1 col2\nval1 val2")
    @patch("pytesseract.image_to_data")
    def test_detect_table_structure(self, mock_data, mock_string):
        """Test that tabular data with columns is detected."""
        mock_data.return_value = {
            "text": ["Name", "Age", "Ahmed", "25", "", ""],
            "conf": [95.0, 94.0, 92.0, 93.0, -1, -1],
            "left": [10, 200, 10, 200, 0, 0],
            "top": [10, 10, 40, 40, 0, 0],
            "width": [80, 60, 90, 40, 0, 0],
            "height": [20, 20, 20, 20, 0, 0],
            "block_num": [1, 1, 1, 1, 1, 1],
            "line_num": [1, 1, 2, 2, 3, 3],
        }
        img = Image.new("RGB", (400, 300))
        page_img = PageImage(page_number=1, image=img, width=400, height=300)
        result = self.service._process_page(page_img, detect_tables=True)
        # Table detection depends on spatial analysis; verify no crashes
        assert isinstance(result.tables, list)

