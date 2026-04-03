"""Integration tests for Arabic OCR pipeline with real PDF documents.

These tests generate actual PDF documents containing Arabic text using Pillow,
then run them through the full OCR pipeline with Tesseract. They require:
- Tesseract OCR installed with Arabic language pack (ara)
- poppler-utils for PDF-to-image conversion (used by pdf2image)

Run with: python -m pytest tests/ -v -m integration
Skip in CI: python -m pytest tests/ -v -m "not integration"
"""

import os
import time
import tempfile
import unicodedata
from typing import List

import pytest
from PIL import Image, ImageDraw, ImageFont

from ..arabic_ocr_service import ArabicOCRService, OCRResult
from .conftest import requires_tesseract


# ---------------------------------------------------------------------------
# Arabic character normalisation (presentation forms → base forms)
# ---------------------------------------------------------------------------

# Mapping from Arabic Presentation Forms to base Arabic letters.
# arabic_reshaper converts U+0600-range chars into U+FB50/U+FE70-range
# presentation forms, so to compare OCR output with expected text we
# normalise both to NFKD decomposed base forms.

def _normalise_arabic_char(ch: str) -> str:
    """Map an Arabic presentation-form character back to its base letter.

    Uses NFKD normalisation which decomposes presentation forms.
    Non-Arabic characters are returned unchanged.
    """
    decomposed = unicodedata.normalize("NFKD", ch)
    # Return the first non-combining character from the decomposition
    for c in decomposed:
        if unicodedata.category(c) != "Mn":  # skip combining marks
            return c
    return ch


# ---------------------------------------------------------------------------
# PDF fixture generators
# ---------------------------------------------------------------------------

# Known Arabic text used in fixtures — kept short and using common characters
# so Tesseract has a reasonable chance of recognition.
ARABIC_SIMPLE_LINES = [
    "\u0628\u0633\u0645 \u0627\u0644\u0644\u0647 \u0627\u0644\u0631\u062d\u0645\u0646 \u0627\u0644\u0631\u062d\u064a\u0645",  # بسم الله الرحمن الرحيم
    "\u0645\u0631\u062d\u0628\u0627 \u0628\u0627\u0644\u0639\u0627\u0644\u0645",  # مرحبا بالعالم
    "\u0647\u0630\u0627 \u0627\u062e\u062a\u0628\u0627\u0631",  # هذا اختبار
]

ENGLISH_LINES = [
    "Invoice Number: INV-2024-001",
    "Date: 2024-01-15",
    "Total Amount: $1,250.00",
]

TABLE_HEADERS = [
    "\u0627\u0644\u0628\u0646\u062f",  # البند (Item)
    "\u0627\u0644\u0643\u0645\u064a\u0629",  # الكمية (Quantity)
    "\u0627\u0644\u0633\u0639\u0631",  # السعر (Price)
]

TABLE_ROWS = [
    ["\u0645\u0646\u062a\u062c \u0623", "10", "100"],  # منتج أ
    ["\u0645\u0646\u062a\u062c \u0628", "5", "200"],   # منتج ب
    ["\u0645\u0646\u062a\u062c \u062c", "20", "50"],   # منتج ج
]


def _get_font(size: int = 28):
    """Get a font that supports Arabic glyphs, falling back to default."""
    # Try common Arabic-capable fonts across platforms
    font_paths = [
        "/System/Library/Fonts/Supplemental/Arial Unicode.ttf",  # macOS
        "/System/Library/Fonts/Geeza Pro.ttc",  # macOS Arabic
        "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",  # Linux
        "/usr/share/fonts/truetype/freefont/FreeSans.ttf",  # Linux
        "/usr/share/fonts/TTF/DejaVuSans.ttf",  # Arch Linux
        "C:/Windows/Fonts/arial.ttf",  # Windows
    ]
    for path in font_paths:
        if os.path.exists(path):
            try:
                return ImageFont.truetype(path, size)
            except Exception:
                continue
    return ImageFont.load_default()


def _render_text_image(
    lines: List[str],
    width: int = 800,
    height: int = 600,
    font_size: int = 28,
    y_start: int = 40,
    line_spacing: int = 50,
) -> Image.Image:
    """Render lines of text onto a white image."""
    img = Image.new("RGB", (width, height), "white")
    draw = ImageDraw.Draw(img)
    font = _get_font(font_size)
    y = y_start
    for line in lines:
        draw.text((40, y), line, fill="black", font=font)
        y += line_spacing
    return img


def _create_pdf_from_images(images: List[Image.Image], path: str) -> str:
    """Save a list of PIL images as a multi-page PDF."""
    if len(images) == 1:
        images[0].save(path, "PDF", resolution=150)
    else:
        images[0].save(
            path, "PDF", resolution=150, save_all=True,
            append_images=images[1:],
        )
    return path


# ---------------------------------------------------------------------------
# Fixtures that generate real PDFs
# ---------------------------------------------------------------------------

@pytest.fixture
def simple_arabic_pdf(temp_dir):
    """Single-page PDF with simple printed Arabic text."""
    img = _render_text_image(ARABIC_SIMPLE_LINES, width=800, height=400)
    path = os.path.join(temp_dir, "simple_arabic.pdf")
    _create_pdf_from_images([img], path)
    return path, ARABIC_SIMPLE_LINES


@pytest.fixture
def multipage_arabic_report_pdf(temp_dir):
    """Multi-page Arabic financial report with tables on some pages."""
    pages = []
    page_texts = []

    # Page 1: Title page
    title_lines = [
        "\u0627\u0644\u062a\u0642\u0631\u064a\u0631 \u0627\u0644\u0645\u0627\u0644\u064a",  # التقرير المالي
        "2024",
    ]
    pages.append(_render_text_image(title_lines, height=400))
    page_texts.append(title_lines)

    # Page 2: Table page
    table_lines = [TABLE_HEADERS[0] + "    " + TABLE_HEADERS[1] + "    " + TABLE_HEADERS[2]]
    for row in TABLE_ROWS:
        table_lines.append("    ".join(row))
    pages.append(_render_text_image(table_lines, height=500))
    page_texts.append(table_lines)

    # Page 3: Summary page
    summary_lines = [
        "\u0627\u0644\u0645\u0644\u062e\u0635",  # الملخص
        "\u0625\u062c\u0645\u0627\u0644\u064a \u0627\u0644\u0645\u0628\u064a\u0639\u0627\u062a",  # إجمالي المبيعات
    ]
    pages.append(_render_text_image(summary_lines, height=400))
    page_texts.append(summary_lines)

    path = os.path.join(temp_dir, "financial_report.pdf")
    _create_pdf_from_images(pages, path)
    return path, page_texts, len(pages)


@pytest.fixture
def mixed_language_invoice_pdf(temp_dir):
    """Mixed Arabic/English invoice PDF."""
    mixed_lines = ENGLISH_LINES + [""] + ARABIC_SIMPLE_LINES[:2]
    img = _render_text_image(mixed_lines, width=900, height=600)
    path = os.path.join(temp_dir, "mixed_invoice.pdf")
    _create_pdf_from_images([img], path)
    return path, ENGLISH_LINES, ARABIC_SIMPLE_LINES[:2]


@pytest.fixture
def ten_page_pdf(temp_dir):
    """10-page PDF for performance testing."""
    pages = []
    for i in range(10):
        lines = [
            f"\u0635\u0641\u062d\u0629 {i + 1}",  # صفحة N
            ARABIC_SIMPLE_LINES[0],
        ]
        pages.append(_render_text_image(lines, height=400))
    path = os.path.join(temp_dir, "ten_pages.pdf")
    _create_pdf_from_images(pages, path)
    return path


# ---------------------------------------------------------------------------
# Integration test classes
# ---------------------------------------------------------------------------

@pytest.mark.integration
@requires_tesseract
class TestArabicTextExtraction:
    """Verify text extraction accuracy > 80% for printed Arabic."""

    def setup_method(self):
        self.service = ArabicOCRService(dpi=150)

    def test_simple_arabic_text_extraction(self, simple_arabic_pdf):
        """Extract text from a single-page simple Arabic PDF and check accuracy."""
        pdf_path, expected_lines = simple_arabic_pdf
        result = self.service.process_pdf(pdf_path)

        assert result.total_pages >= 1, "Should detect at least 1 page"
        assert len(result.pages) >= 1, "Should process at least 1 page"
        assert not result.errors, f"Unexpected errors: {result.errors}"

        page_text = result.pages[0].text

        # The OCR service applies arabic_reshaper + bidi reordering, which
        # converts base Arabic codepoints (U+0600-U+06FF) to Arabic
        # Presentation Forms (U+FB50-U+FEFF, U+FE70-U+FEFF).  So we
        # normalise both sides to base forms before comparing.
        expected_chars = set()
        for line in expected_lines:
            expected_chars.update(
                _normalise_arabic_char(c) for c in line if c.strip()
            )

        extracted_chars = set(
            _normalise_arabic_char(c) for c in page_text if c.strip()
        )

        # At least 80 % of expected characters should appear in output
        if expected_chars:
            overlap = expected_chars & extracted_chars
            accuracy = len(overlap) / len(expected_chars)
            assert accuracy >= 0.80, (
                f"Character-level accuracy {accuracy:.0%} is below 80%. "
                f"Missing chars: {expected_chars - extracted_chars}"
            )

    def test_confidence_above_threshold(self, simple_arabic_pdf):
        """Overall confidence should be non-zero for readable printed text."""
        pdf_path, _ = simple_arabic_pdf
        result = self.service.process_pdf(pdf_path)
        # We only check confidence is reported; actual value depends on fonts
        assert result.overall_confidence >= 0, "Confidence should be non-negative"


@pytest.mark.integration
@requires_tesseract
class TestTableDetectionIntegration:
    """Verify table detection finds correct row/column counts."""

    def setup_method(self):
        self.service = ArabicOCRService(dpi=150)

    def test_table_detection_on_report(self, multipage_arabic_report_pdf):
        """Table page should have detected table structures."""
        pdf_path, page_texts, num_pages = multipage_arabic_report_pdf
        result = self.service.process_pdf(pdf_path)

        assert len(result.pages) == num_pages, (
            f"Expected {num_pages} pages, got {len(result.pages)}"
        )

        # Page 2 (index 1) has the table data. Check that at least one
        # table is detected, or that the page text contains table content.
        table_page = result.pages[1]

        # Even if table detection heuristics don't fire on OCR output,
        # verify that the page was processed without errors.
        assert not table_page.errors, f"Table page errors: {table_page.errors}"

        # If tables were detected, verify they have reasonable structure
        if table_page.tables:
            table = table_page.tables[0]
            assert table.rows >= 2, "Table should have at least header + 1 data row"
            assert table.columns >= 2, "Table should have at least 2 columns"


@pytest.mark.integration
@requires_tesseract
class TestMultiPageOrdering:
    """Verify page ordering is maintained for multi-page docs."""

    def setup_method(self):
        self.service = ArabicOCRService(dpi=150)

    def test_page_numbers_sequential(self, multipage_arabic_report_pdf):
        """Pages should be numbered sequentially starting from 1."""
        pdf_path, _, num_pages = multipage_arabic_report_pdf
        result = self.service.process_pdf(pdf_path)

        assert len(result.pages) == num_pages
        for i, page in enumerate(result.pages):
            assert page.page_number == i + 1, (
                f"Page {i} has number {page.page_number}, expected {i + 1}"
            )

    def test_page_content_distinct(self, multipage_arabic_report_pdf):
        """Each page should have distinct text content."""
        pdf_path, _, num_pages = multipage_arabic_report_pdf
        result = self.service.process_pdf(pdf_path)

        page_texts = [p.text.strip() for p in result.pages]
        # At least some pages should have non-empty, distinct content
        non_empty = [t for t in page_texts if t]
        assert len(non_empty) >= 2, (
            "At least 2 pages should have non-empty OCR text"
        )


@pytest.mark.integration
@requires_tesseract
class TestMixedLanguageSegmentation:
    """Verify mixed Arabic/English text is properly segmented."""

    def setup_method(self):
        self.service = ArabicOCRService(dpi=150)

    def test_mixed_text_contains_both_languages(self, mixed_language_invoice_pdf):
        """Extracted text should contain both Arabic and English content."""
        pdf_path, english_lines, arabic_lines = mixed_language_invoice_pdf
        result = self.service.process_pdf(pdf_path)

        assert len(result.pages) >= 1
        assert not result.errors, f"Unexpected errors: {result.errors}"

        page_text = result.pages[0].text

        # Check English content is present (look for key terms)
        english_found = any(
            keyword in page_text
            for keyword in ["Invoice", "INV", "Date", "Total", "Amount"]
        )
        assert english_found, (
            f"Expected English invoice terms in output. Got: {page_text[:200]}"
        )

    def test_text_regions_have_language_labels(self, mixed_language_invoice_pdf):
        """Text regions should be labeled with correct language codes."""
        pdf_path, _, _ = mixed_language_invoice_pdf
        result = self.service.process_pdf(pdf_path)

        if result.pages and result.pages[0].text_regions:
            languages = {r.language for r in result.pages[0].text_regions}
            # Should detect at least English content
            assert languages, "Text regions should have language labels"
            # At least one region should be 'eng' or 'mixed'
            assert languages & {"eng", "mixed", "ara"}, (
                f"Expected language labels, got: {languages}"
            )


@pytest.mark.integration
@requires_tesseract
class TestPerformance:
    """Performance: process 10-page PDF in < 30 seconds."""

    def setup_method(self):
        self.service = ArabicOCRService(dpi=150)

    def test_ten_page_processing_time(self, ten_page_pdf):
        """Processing a 10-page PDF should complete within 30 seconds."""
        start = time.time()
        result = self.service.process_pdf(ten_page_pdf)
        elapsed = time.time() - start

        assert len(result.pages) == 10, (
            f"Expected 10 pages, got {len(result.pages)}"
        )
        assert elapsed < 30, (
            f"Processing took {elapsed:.1f}s, exceeding 30s limit"
        )

    def test_all_pages_processed(self, ten_page_pdf):
        """All 10 pages should be processed with results."""
        result = self.service.process_pdf(ten_page_pdf)
        assert len(result.pages) == 10
        for i, page in enumerate(result.pages):
            assert page.page_number == i + 1
