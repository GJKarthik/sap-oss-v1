"""Tests for PDF processor module."""

import os
import tempfile
from unittest.mock import MagicMock, patch

import pytest
from PIL import Image

from ..pdf_processor import PDFDocument, PDFProcessor, PageImage


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
                with pytest.raises(ValueError, match="does not appear to be a valid PDF"):
                    self.processor.validate_pdf(f.name)
            finally:
                os.unlink(f.name)

    def test_validate_valid_pdf_header(self):
        with tempfile.NamedTemporaryFile(suffix=".pdf", delete=False) as f:
            f.write(b"%PDF-1.4 fake content")
            f.flush()
            try:
                # Should not raise
                self.processor.validate_pdf(f.name)
            finally:
                os.unlink(f.name)


class TestPDFProcessorProcess:
    """Tests for PDF to image conversion."""

    def setup_method(self):
        self.processor = PDFProcessor(dpi=150)

    def test_process_single_page(self):
        """Test processing a single-page PDF."""
        mock_img = Image.new("RGB", (800, 600))

        with tempfile.NamedTemporaryFile(suffix=".pdf", delete=False) as f:
            f.write(b"%PDF-1.4 fake content")
            f.flush()
            try:
                with patch(
                    "pdf2image.convert_from_path", return_value=[mock_img]
                ):
                    doc = self.processor.process(f.name)

                assert isinstance(doc, PDFDocument)
                assert doc.total_pages == 1
                assert len(doc.pages) == 1
                assert doc.pages[0].page_number == 1
                assert doc.pages[0].width == 800
                assert doc.pages[0].height == 600
            finally:
                os.unlink(f.name)

    def test_process_multi_page(self):
        """Test processing a multi-page PDF."""
        mock_images = [Image.new("RGB", (800, 600)) for _ in range(5)]

        with tempfile.NamedTemporaryFile(suffix=".pdf", delete=False) as f:
            f.write(b"%PDF-1.4 fake content")
            f.flush()
            try:
                with patch(
                    "pdf2image.convert_from_path", return_value=mock_images
                ):
                    doc = self.processor.process(f.name)

                assert doc.total_pages == 5
                assert len(doc.pages) == 5
                for i, page in enumerate(doc.pages):
                    assert page.page_number == i + 1
            finally:
                os.unlink(f.name)

    def test_process_page_range(self):
        """Test processing a specific page range."""
        mock_images = [Image.new("RGB", (800, 600)) for _ in range(3)]

        with tempfile.NamedTemporaryFile(suffix=".pdf", delete=False) as f:
            f.write(b"%PDF-1.4 fake content")
            f.flush()
            try:
                with patch(
                    "pdf2image.convert_from_path", return_value=mock_images
                ) as mock_convert:
                    doc = self.processor.process(f.name, start_page=2, end_page=4)

                # Verify page numbering starts from start_page
                assert doc.pages[0].page_number == 2
                assert doc.pages[2].page_number == 4

                # Verify convert_from_path was called with page range
                call_kwargs = mock_convert.call_args[1]
                assert call_kwargs["first_page"] == 2
                assert call_kwargs["last_page"] == 4
            finally:
                os.unlink(f.name)

    def test_process_large_document(self):
        """Test processing a 50+ page document."""
        mock_images = [Image.new("RGB", (800, 600)) for _ in range(55)]

        with tempfile.NamedTemporaryFile(suffix=".pdf", delete=False) as f:
            f.write(b"%PDF-1.4 fake content")
            f.flush()
            try:
                with patch(
                    "pdf2image.convert_from_path", return_value=mock_images
                ):
                    doc = self.processor.process(f.name)

                assert doc.total_pages == 55
                assert len(doc.pages) == 55
                assert doc.pages[-1].page_number == 55
            finally:
                os.unlink(f.name)


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

