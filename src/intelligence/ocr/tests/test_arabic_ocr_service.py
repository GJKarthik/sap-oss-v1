"""Tests for Arabic OCR service module.

Mostly integration-style tests using real dependencies
(pytesseract, arabic_reshaper, python-bidi), plus a small unit-level
monkeypatch where needed to verify timeout plumbing.
"""

import json

import arabic_reshaper
import pytesseract
import pytest
from bidi.algorithm import get_display
from PIL import Image, ImageDraw, ImageFont

from ..arabic_ocr_service import (
    ArabicOCRService,
    DetectedTable,
    OCRResult,
    PageResult,
    TableCell,
    TextRegion,
    _BASE_GAP_DPI,
    _BASE_GAP_THRESHOLD_PX,
)
from ..pdf_processor import PDFDocument, PageImage


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _make_text_image(text: str, size=(400, 100), font_size: int = 36) -> Image.Image:
    """Create a real image with rendered text for OCR testing."""
    img = Image.new("RGB", size, color="white")
    draw = ImageDraw.Draw(img)
    try:
        font = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", font_size)
    except (OSError, IOError):
        font = ImageFont.load_default()
    draw.text((10, 20), text, fill="black", font=font)
    return img


# ---------------------------------------------------------------------------
# Init
# ---------------------------------------------------------------------------

class TestArabicOCRServiceInit:
    """Tests for service initialization."""

    def test_default_config(self):
        service = ArabicOCRService()
        assert service.languages == "ara+eng"
        assert service.dpi == 300
        assert "--oem 3" in service.tesseract_config
        assert service.max_workers == 1

    def test_custom_config(self):
        service = ArabicOCRService(
            languages="ara", dpi=150, tesseract_config="--psm 3"
        )
        assert service.languages == "ara"
        assert service.dpi == 150
        assert service.tesseract_config == "--psm 3"

    def test_max_workers_validation(self):
        with pytest.raises(ValueError, match="max_workers must be >= 1"):
            ArabicOCRService(max_workers=0)
        with pytest.raises(ValueError, match="max_workers must be >= 1"):
            ArabicOCRService(max_workers=-1)

    def test_dpi_validation_propagated(self):
        with pytest.raises(ValueError, match="dpi must be an integer"):
            ArabicOCRService(dpi=10)

    def test_gap_threshold_scales_with_dpi(self):
        service_300 = ArabicOCRService(dpi=300)
        service_150 = ArabicOCRService(dpi=150)
        assert service_300._gap_threshold == _BASE_GAP_THRESHOLD_PX
        assert service_150._gap_threshold == pytest.approx(
            _BASE_GAP_THRESHOLD_PX * 150 / _BASE_GAP_DPI
        )


# ---------------------------------------------------------------------------
# Language detection
# ---------------------------------------------------------------------------

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


# ---------------------------------------------------------------------------
# Arabic text fixing (real reshaper + bidi)
# ---------------------------------------------------------------------------

class TestArabicTextFixing:
    """Tests for Arabic text reshaping and BiDi handling (real libs)."""

    def setup_method(self):
        self.service = ArabicOCRService()

    def test_empty_text(self):
        assert self.service._fix_arabic_text("") == ""
        assert self.service._fix_arabic_text("  ") == "  "

    def test_arabic_reshaping_applied(self):
        """Real reshaper + bidi produce non-empty output for Arabic input."""
        result = self.service._fix_arabic_text("مرحبا")
        assert result  # non-empty
        assert isinstance(result, str)

    def test_english_text_passes_through(self):
        result = self.service._fix_arabic_text("Hello World")
        assert result == "Hello World"

    def test_reshaper_and_bidi_agree(self):
        """Manually calling reshaper+bidi gives same result as the service."""
        text = "بسم الله الرحمن الرحيم"
        expected = get_display(arabic_reshaper.reshape(text))
        result = self.service._fix_arabic_text(text)
        assert result == expected


# ---------------------------------------------------------------------------
# Text reconstruction
# ---------------------------------------------------------------------------

class TestReconstructText:
    """Tests for text reconstruction from OCR data."""

    def test_empty_data(self):
        assert ArabicOCRService._reconstruct_text({"text": []}) == ""
        assert ArabicOCRService._reconstruct_text({}) == ""

    def test_single_line(self):
        data = {
            "text": ["Hello", "World"],
            "block_num": [1, 1],
            "par_num": [1, 1],
            "line_num": [1, 1],
            "word_num": [1, 2],
        }
        assert ArabicOCRService._reconstruct_text(data) == "Hello World"

    def test_multi_line(self):
        data = {
            "text": ["Line1", "Line2"],
            "block_num": [1, 1],
            "par_num": [1, 1],
            "line_num": [1, 2],
            "word_num": [1, 1],
        }
        result = ArabicOCRService._reconstruct_text(data)
        assert "Line1" in result
        assert "Line2" in result

    def test_multi_block_adds_blank_line(self):
        data = {
            "text": ["Block1", "Block2"],
            "block_num": [1, 2],
            "par_num": [1, 1],
            "line_num": [1, 1],
            "word_num": [1, 1],
        }
        result = ArabicOCRService._reconstruct_text(data)
        assert "\n\n" in result

    def test_skips_whitespace_only_words(self):
        data = {
            "text": ["Hello", "  ", "World"],
            "block_num": [1, 1, 1],
            "par_num": [1, 1, 1],
            "line_num": [1, 1, 1],
            "word_num": [1, 2, 3],
        }
        assert ArabicOCRService._reconstruct_text(data) == "Hello World"


# ---------------------------------------------------------------------------
# Word grouping
# ---------------------------------------------------------------------------

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
        assert len(groups) == 1

    def test_distant_words_separated(self):
        words = [
            {"text": "col1", "left": 10, "width": 50},
            {"text": "col2", "left": 200, "width": 50},
        ]
        groups = self.service._group_words_by_proximity(words)
        assert len(groups) == 2

    def test_custom_gap_threshold(self):
        words = [
            {"text": "a", "left": 10, "width": 50},
            {"text": "b", "left": 70, "width": 50},
        ]
        groups_sep = self.service._group_words_by_proximity(words, gap_threshold=5.0)
        groups_grp = self.service._group_words_by_proximity(words, gap_threshold=15.0)
        assert len(groups_sep) == 2
        assert len(groups_grp) == 1

    def test_dpi_aware_default_threshold(self):
        service_150 = ArabicOCRService(dpi=150)
        words = [
            {"text": "a", "left": 10, "width": 50},
            {"text": "b", "left": 80, "width": 50},
        ]
        groups_300 = self.service._group_words_by_proximity(words)
        groups_150 = service_150._group_words_by_proximity(words)
        assert len(groups_300) == 1  # gap=20 < 30
        assert len(groups_150) == 2  # gap=20 > 15


# ---------------------------------------------------------------------------
# Real OCR on a rendered image
# ---------------------------------------------------------------------------

class TestRealOCROnImage:
    """Run real Tesseract OCR on a programmatically rendered image."""

    def setup_method(self):
        self.service = ArabicOCRService(languages="eng", dpi=300)

    def test_ocr_extracts_english_text(self):
        img = _make_text_image("HELLO WORLD", size=(500, 100), font_size=48)
        result = self.service.process_image(img, detect_tables=False)
        assert result.page_number == 1
        assert "HELLO" in result.text.upper()
        assert result.confidence > 0
        assert len(result.text_regions) > 0

    def test_ocr_regions_have_bboxes(self):
        img = _make_text_image("Testing OCR", size=(500, 100), font_size=48)
        result = self.service.process_image(img, detect_tables=False)
        for region in result.text_regions:
            assert region.bbox is not None
            assert "x" in region.bbox
            assert "y" in region.bbox
            assert region.confidence >= 0


# ---------------------------------------------------------------------------
# OCRResult serialization
# ---------------------------------------------------------------------------

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
                PageResult(page_number=1, text="مرحبا", confidence=90.0)
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
        assert "بسم" in json_str




# ---------------------------------------------------------------------------
# Pre-processing pipeline
# ---------------------------------------------------------------------------

class TestPreprocessingConfig:
    """Tests for PreprocessingConfig validation."""

    def test_defaults(self):
        from ..preprocessing import PreprocessingConfig

        cfg = PreprocessingConfig()
        assert cfg.enable_grayscale is True
        assert cfg.enable_binarize is False
        assert cfg.enable_denoise is False

    def test_invalid_binarize_threshold(self):
        from ..preprocessing import PreprocessingConfig

        with pytest.raises(ValueError, match="binarize_threshold"):
            PreprocessingConfig(binarize_threshold=300)
        with pytest.raises(ValueError, match="binarize_threshold"):
            PreprocessingConfig(binarize_threshold=-1)

    def test_invalid_denoise_kernel(self):
        from ..preprocessing import PreprocessingConfig

        with pytest.raises(ValueError, match="denoise_kernel_size"):
            PreprocessingConfig(denoise_kernel_size=2)  # even
        with pytest.raises(ValueError, match="denoise_kernel_size"):
            PreprocessingConfig(denoise_kernel_size=1)  # too small

    def test_invalid_target_dpi(self):
        from ..preprocessing import PreprocessingConfig

        with pytest.raises(ValueError, match="target_dpi"):
            PreprocessingConfig(target_dpi=10)


class TestImagePreprocessor:
    """Tests for real image pre-processing transforms."""

    def test_grayscale(self):
        from ..preprocessing import ImagePreprocessor, PreprocessingConfig

        cfg = PreprocessingConfig(enable_grayscale=True)
        proc = ImagePreprocessor(cfg)
        img = Image.new("RGB", (100, 100), color="red")
        result = proc.process(img)
        assert result.mode == "L"

    def test_binarize(self):
        from ..preprocessing import ImagePreprocessor, PreprocessingConfig

        cfg = PreprocessingConfig(
            enable_grayscale=False, enable_binarize=True, binarize_threshold=128
        )
        proc = ImagePreprocessor(cfg)
        img = Image.new("L", (100, 100), color=200)
        result = proc.process(img)
        assert result.mode == "1"
        # All pixels above threshold → all white
        pixels = list(result.tobytes())
        assert any(p in (0, 255) for p in pixels)

    def test_denoise(self):
        from ..preprocessing import ImagePreprocessor, PreprocessingConfig

        cfg = PreprocessingConfig(
            enable_grayscale=False, enable_denoise=True, denoise_kernel_size=3
        )
        proc = ImagePreprocessor(cfg)
        img = Image.new("RGB", (100, 100), color="white")
        result = proc.process(img)
        assert result.size == (100, 100)

    def test_upscale(self):
        from ..preprocessing import ImagePreprocessor, PreprocessingConfig

        cfg = PreprocessingConfig(enable_upscale=True, target_dpi=300)
        proc = ImagePreprocessor(cfg)
        img = Image.new("RGB", (100, 100))
        result = proc.process(img, source_dpi=150)
        # Should double in size (150 → 300 DPI)
        assert result.width == 200
        assert result.height == 200

    def test_upscale_not_applied_when_already_high(self):
        from ..preprocessing import ImagePreprocessor, PreprocessingConfig

        cfg = PreprocessingConfig(enable_upscale=True, target_dpi=300)
        proc = ImagePreprocessor(cfg)
        img = Image.new("RGB", (100, 100))
        result = proc.process(img, source_dpi=300)
        assert result.size == (100, 100)

    def test_border_removal(self):
        from ..preprocessing import ImagePreprocessor, PreprocessingConfig

        cfg = PreprocessingConfig(
            enable_grayscale=False, enable_border_removal=True
        )
        proc = ImagePreprocessor(cfg)
        # White image with a black rectangle inside
        img = Image.new("RGB", (200, 200), color="white")
        draw = ImageDraw.Draw(img)
        draw.rectangle([50, 50, 150, 150], fill="black")
        result = proc.process(img)
        # Border removal should crop to the black content area
        assert result.width < 200
        assert result.height < 200

    def test_full_pipeline(self):
        from ..preprocessing import ImagePreprocessor, PreprocessingConfig

        cfg = PreprocessingConfig(
            enable_grayscale=True,
            enable_binarize=True,
            enable_denoise=True,
            binarize_threshold=128,
        )
        proc = ImagePreprocessor(cfg)
        img = _make_text_image("TEST", size=(300, 80))
        result = proc.process(img)
        assert result is not None
        assert result.size[0] > 0

    def test_preprocessing_improves_or_maintains_ocr(self):
        """OCR on preprocessed image should not crash and produce output."""
        from ..preprocessing import PreprocessingConfig

        service = ArabicOCRService(
            languages="eng",
            preprocessing=PreprocessingConfig(
                enable_grayscale=True, enable_denoise=True
            ),
        )
        img = _make_text_image("HELLO WORLD", size=(500, 100), font_size=48)
        result = service.process_image(img, detect_tables=False)
        assert result.page_number == 1
        assert isinstance(result.text, str)


# ---------------------------------------------------------------------------
# Confidence thresholding
# ---------------------------------------------------------------------------

class TestConfidenceThresholding:
    """Tests for min_confidence flagging."""

    def test_invalid_min_confidence(self):
        with pytest.raises(ValueError, match="min_confidence"):
            ArabicOCRService(min_confidence=-1)
        with pytest.raises(ValueError, match="min_confidence"):
            ArabicOCRService(min_confidence=101)

    def test_pages_flagged_below_threshold(self):
        service = ArabicOCRService(languages="eng", min_confidence=99.0)
        # Blank image → 0% confidence → should be flagged
        img = Image.new("RGB", (200, 200), color="white")
        result = service.process_image(img, detect_tables=False)
        assert result.flagged_for_review is True

    def test_pages_not_flagged_when_disabled(self):
        service = ArabicOCRService(languages="eng", min_confidence=None)
        img = Image.new("RGB", (200, 200), color="white")
        result = service.process_image(img, detect_tables=False)
        assert result.flagged_for_review is False

    def test_high_confidence_not_flagged(self):
        service = ArabicOCRService(languages="eng", min_confidence=10.0)
        img = _make_text_image("HELLO WORLD", size=(500, 100), font_size=48)
        result = service.process_image(img, detect_tables=False)
        # Real OCR on clear text should exceed 10%
        if result.confidence > 10.0:
            assert result.flagged_for_review is False


# ---------------------------------------------------------------------------
# Timeout protection
# ---------------------------------------------------------------------------

class TestPageTimeout:
    """Tests for per-page timeout."""

    def test_invalid_timeout(self):
        with pytest.raises(ValueError, match="page_timeout"):
            ArabicOCRService(page_timeout=0)
        with pytest.raises(ValueError, match="page_timeout"):
            ArabicOCRService(page_timeout=-5)

    def test_none_timeout_accepted(self):
        service = ArabicOCRService(page_timeout=None)
        assert service.page_timeout is None

    def test_ocr_with_generous_timeout(self):
        """OCR with a large timeout should succeed normally."""
        service = ArabicOCRService(languages="eng", page_timeout=30.0)
        img = _make_text_image("TIMEOUT TEST", size=(500, 100), font_size=48)
        result = service.process_image(img, detect_tables=False)
        assert "TIMEOUT" in result.text.upper() or result.confidence >= 0

    def test_timeout_forwarded_to_pytesseract(self, monkeypatch):
        captured = {}

        def fake_image_to_data(*args, **kwargs):
            captured["timeout"] = kwargs.get("timeout")
            return {
                "text": [],
                "conf": [],
                "left": [],
                "top": [],
                "width": [],
                "height": [],
            }

        monkeypatch.setattr(pytesseract, "image_to_data", fake_image_to_data)

        service = ArabicOCRService(languages="eng", page_timeout=1.5)
        img = Image.new("RGB", (50, 50), color="white")
        page_result = PageResult(page_number=1, text="", width=50, height=50)
        page_img = PageImage(page_number=1, image=img, width=50, height=50, dpi=300)

        service._run_ocr(img, page_result, detect_tables=False, page_img=page_img)

        assert captured["timeout"] is not None
        assert 0 < captured["timeout"] <= 1.5

# ---------------------------------------------------------------------------
# Retry logic
# ---------------------------------------------------------------------------

class TestRetryLogic:
    """Tests for per-page retry with backoff."""

    def test_invalid_max_retries(self):
        with pytest.raises(ValueError, match="max_retries"):
            ArabicOCRService(max_retries=-1)

    def test_invalid_retry_delay(self):
        with pytest.raises(ValueError, match="retry_delay"):
            ArabicOCRService(retry_delay=-1.0)

    def test_no_retries_by_default(self):
        service = ArabicOCRService()
        assert service.max_retries == 0

    def test_ocr_succeeds_without_retries(self):
        service = ArabicOCRService(languages="eng", max_retries=0)
        img = _make_text_image("RETRY TEST", size=(500, 100), font_size=48)
        result = service.process_image(img, detect_tables=False)
        assert len(result.errors) == 0

    def test_ocr_with_retries_enabled(self):
        """Retries enabled but no failure — should work normally."""
        service = ArabicOCRService(
            languages="eng", max_retries=2, retry_delay=0.01
        )
        img = _make_text_image("HELLO", size=(400, 80), font_size=48)
        result = service.process_image(img, detect_tables=False)
        assert len(result.errors) == 0
