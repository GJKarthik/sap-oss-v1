"""Tests for Arabic OCR service module."""

import json
from unittest.mock import MagicMock, patch, PropertyMock

import pytest
from PIL import Image

from ..arabic_ocr_service import (
    ArabicOCRService,
    DetectedTable,
    OCRResult,
    PageResult,
    TableCell,
    TextRegion,
)
from ..pdf_processor import PDFDocument, PageImage


class TestArabicOCRServiceInit:
    """Tests for service initialization."""

    def test_default_config(self):
        service = ArabicOCRService()
        assert service.languages == "ara+eng"
        assert service.dpi == 300
        assert "--oem 3" in service.tesseract_config

    def test_custom_config(self):
        service = ArabicOCRService(
            languages="ara", dpi=150, tesseract_config="--psm 3"
        )
        assert service.languages == "ara"
        assert service.dpi == 150
        assert service.tesseract_config == "--psm 3"


class TestLanguageDetection:
    """Tests for Arabic/English language detection."""

    def setup_method(self):
        self.service = ArabicOCRService()

    def test_detect_arabic(self):
        assert self.service._detect_language("مرحبا بالعالم") == "ara"

    def test_detect_english(self):
        assert self.service._detect_language("Hello World") == "eng"

    def test_detect_mixed(self):
        assert self.service._detect_language("Hello مرحبا") == "mixed"

    def test_detect_empty(self):
        assert self.service._detect_language("") == "unknown"

    def test_detect_numbers_only(self):
        assert self.service._detect_language("12345") == "unknown"


class TestArabicTextFixing:
    """Tests for Arabic text reshaping and BiDi handling."""

    def setup_method(self):
        self.service = ArabicOCRService()

    def test_empty_text(self):
        assert self.service._fix_arabic_text("") == ""
        assert self.service._fix_arabic_text("  ") == "  "

    @patch("arabic_reshaper.reshape", return_value="reshaped_text")
    @patch("bidi.algorithm.get_display", return_value="bidi_text")
    def test_arabic_reshaping_applied(self, mock_bidi, mock_reshape):
        result = self.service._fix_arabic_text("مرحبا")
        mock_reshape.assert_called_once_with("مرحبا")
        mock_bidi.assert_called_once_with("reshaped_text")
        assert result == "bidi_text"

    def test_fallback_when_reshaper_unavailable(self):
        with patch.dict("sys.modules", {"arabic_reshaper": None}):
            # When import fails, should return original text
            service = ArabicOCRService()
            # Force ImportError path
            with patch(
                "builtins.__import__",
                side_effect=lambda name, *a, **kw: (
                    (_ for _ in ()).throw(ImportError())
                    if name == "arabic_reshaper"
                    else __import__(name, *a, **kw)
                ),
            ):
                result = service._fix_arabic_text("test text")
                assert result == "test text"


class TestWordGrouping:
    """Tests for word proximity grouping (table column detection)."""

    def setup_method(self):
        self.service = ArabicOCRService()

    def test_empty_words(self):
        assert self.service._group_words_by_proximity([]) == []

    def test_single_word(self):
        words = [{"text": "hello", "left": 10, "width": 50}]
        groups = self.service._group_words_by_proximity(words)
        assert len(groups) == 1

    def test_close_words_grouped(self):
        words = [
            {"text": "hello", "left": 10, "width": 50},
            {"text": "world", "left": 65, "width": 50},
        ]
        groups = self.service._group_words_by_proximity(words)
        assert len(groups) == 1  # Gap is 5, below threshold

    def test_distant_words_separated(self):
        words = [
            {"text": "col1", "left": 10, "width": 50},
            {"text": "col2", "left": 200, "width": 50},
        ]
        groups = self.service._group_words_by_proximity(words)
        assert len(groups) == 2


class TestOCRResult:
    """Tests for OCR result serialization."""

    def test_to_dict(self):
        result = OCRResult(
            file_path="/test.pdf",
            total_pages=1,
            overall_confidence=95.5,
        )
        d = result.to_dict()
        assert d["file_path"] == "/test.pdf"
        assert d["total_pages"] == 1
        assert d["overall_confidence"] == 95.5

    def test_to_json(self):
        result = OCRResult(
            file_path="/test.pdf",
            total_pages=1,
            pages=[
                PageResult(
                    page_number=1,
                    text="مرحبا",
                    confidence=90.0,
                )
            ],
            overall_confidence=90.0,
        )
        json_str = result.to_json()
        parsed = json.loads(json_str)
        assert parsed["file_path"] == "/test.pdf"
        assert parsed["pages"][0]["text"] == "مرحبا"
        assert parsed["pages"][0]["confidence"] == 90.0

    def test_to_json_preserves_arabic(self):
        result = OCRResult(file_path="/test.pdf", total_pages=1)
        result.pages.append(
            PageResult(page_number=1, text="بسم الله الرحمن الرحيم")
        )
        json_str = result.to_json()
        # ensure_ascii=False should preserve Arabic characters
        assert "بسم" in json_str

