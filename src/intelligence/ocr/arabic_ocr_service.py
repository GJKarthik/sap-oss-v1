"""Arabic OCR service for multi-page PDF document processing.

Provides OCR text extraction optimized for Arabic (and mixed Arabic/English)
documents with table detection, confidence scoring, and structured JSON output.
"""

import json
import logging
import re
from dataclasses import asdict, dataclass, field
from typing import Any, Dict, List, Optional

from PIL import Image

from .pdf_processor import PDFDocument, PDFProcessor, PageImage

logger = logging.getLogger(__name__)


@dataclass
class TableCell:
    """A single cell in a detected table."""

    row: int
    column: int
    text: str
    confidence: float


@dataclass
class DetectedTable:
    """A table detected on a page."""

    table_index: int
    rows: int
    columns: int
    cells: List[TableCell] = field(default_factory=list)
    confidence: float = 0.0


@dataclass
class TextRegion:
    """A region of extracted text with metadata."""

    text: str
    confidence: float
    bbox: Optional[Dict[str, int]] = None  # x, y, width, height
    language: str = "ara"


@dataclass
class PageResult:
    """OCR result for a single page."""

    page_number: int
    text: str
    text_regions: List[TextRegion] = field(default_factory=list)
    tables: List[DetectedTable] = field(default_factory=list)
    confidence: float = 0.0
    width: int = 0
    height: int = 0
    errors: List[str] = field(default_factory=list)


@dataclass
class OCRResult:
    """Complete OCR result for a document."""

    file_path: str
    total_pages: int
    pages: List[PageResult] = field(default_factory=list)
    metadata: Dict[str, Any] = field(default_factory=dict)
    overall_confidence: float = 0.0
    errors: List[str] = field(default_factory=list)

    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary suitable for JSON serialization."""
        return asdict(self)

    def to_json(self, indent: int = 2) -> str:
        """Serialize to JSON string."""
        return json.dumps(self.to_dict(), indent=indent, ensure_ascii=False)


class ArabicOCRService:
    """OCR service optimized for Arabic PDF document processing.

    Features:
    - Multi-page PDF processing
    - Arabic text extraction with proper RTL ordering
    - Mixed Arabic/English document support
    - Table structure detection
    - Per-page and per-region confidence scoring
    - Structured JSON output
    """

    # Tesseract language codes
    ARABIC_LANG = "ara"
    ENGLISH_LANG = "eng"
    MIXED_LANG = "ara+eng"

    def __init__(
        self,
        languages: Optional[str] = None,
        dpi: int = 300,
        tesseract_config: Optional[str] = None,
    ):
        """Initialize the Arabic OCR service.

        Args:
            languages: Tesseract language string (default: "ara+eng" for mixed).
            dpi: Resolution for PDF conversion.
            tesseract_config: Additional tesseract configuration flags.
        """
        self.languages = languages or self.MIXED_LANG
        self.dpi = dpi
        self.tesseract_config = tesseract_config or "--oem 3 --psm 6"
        self.pdf_processor = PDFProcessor(dpi=dpi)

    def process_pdf(
        self,
        file_path: str,
        start_page: Optional[int] = None,
        end_page: Optional[int] = None,
        detect_tables: bool = True,
    ) -> OCRResult:
        """Process a PDF file and extract text with OCR.

        Args:
            file_path: Path to the PDF file.
            start_page: First page to process (1-based). None = first.
            end_page: Last page to process (1-based). None = last.
            detect_tables: Whether to attempt table detection.

        Returns:
            OCRResult with page-by-page text, tables, and metadata.
        """
        result = OCRResult(file_path=file_path, total_pages=0)

        try:
            pdf_doc = self.pdf_processor.process(file_path, start_page, end_page)
        except (FileNotFoundError, ValueError, RuntimeError) as e:
            result.errors.append(str(e))
            return result

        result.total_pages = pdf_doc.total_pages
        result.errors.extend(pdf_doc.errors)

        for page_img in pdf_doc.pages:
            page_result = self._process_page(page_img, detect_tables)
            result.pages.append(page_result)

        # Calculate overall confidence
        if result.pages:
            confidences = [p.confidence for p in result.pages if p.confidence > 0]
            result.overall_confidence = (
                sum(confidences) / len(confidences) if confidences else 0.0
            )

        result.metadata = {
            "languages": self.languages,
            "dpi": self.dpi,
            "tesseract_config": self.tesseract_config,
            "pages_processed": len(result.pages),
            "pages_with_errors": len([p for p in result.pages if p.errors]),
        }

        logger.info(
            f"OCR complete: {len(result.pages)} pages, "
            f"confidence={result.overall_confidence:.2f}"
        )
        return result

    def process_image(
        self, image: Image.Image, detect_tables: bool = True
    ) -> PageResult:
        """Process a single image for OCR.

        Args:
            image: PIL Image to process.
            detect_tables: Whether to attempt table detection.

        Returns:
            PageResult with extracted text and metadata.
        """
        page_img = PageImage(
            page_number=1,
            image=image,
            width=image.width,
            height=image.height,
            dpi=self.dpi,
        )
        return self._process_page(page_img, detect_tables)

    def _process_page(
        self, page_img: PageImage, detect_tables: bool
    ) -> PageResult:
        """Process a single page image through OCR.

        Args:
            page_img: PageImage to process.
            detect_tables: Whether to detect tables.

        Returns:
            PageResult with extracted text.
        """
        page_result = PageResult(
            page_number=page_img.page_number,
            text="",
            width=page_img.width,
            height=page_img.height,
        )

        try:
            import pytesseract

            # Get detailed OCR data for confidence scoring
            ocr_data = pytesseract.image_to_data(
                page_img.image,
                lang=self.languages,
                config=self.tesseract_config,
                output_type=pytesseract.Output.DICT,
            )

            # Extract text regions with confidence
            page_result.text_regions = self._extract_regions(ocr_data)

            # Get full page text
            raw_text = pytesseract.image_to_string(
                page_img.image,
                lang=self.languages,
                config=self.tesseract_config,
            )
            page_result.text = self._fix_arabic_text(raw_text)

            # Calculate page confidence from regions
            region_confidences = [
                r.confidence
                for r in page_result.text_regions
                if r.confidence > 0
            ]
            page_result.confidence = (
                sum(region_confidences) / len(region_confidences)
                if region_confidences
                else 0.0
            )

            # Table detection
            if detect_tables:
                page_result.tables = self._detect_tables(ocr_data, page_img)

        except ImportError:
            page_result.errors.append(
                "pytesseract is not installed. Install with: pip install pytesseract"
            )
        except Exception as e:
            page_result.errors.append(f"OCR error on page {page_img.page_number}: {e}")
            logger.error(f"OCR error on page {page_img.page_number}: {e}")

        return page_result

    def _extract_regions(self, ocr_data: Dict) -> List[TextRegion]:
        """Extract text regions with bounding boxes from OCR data.

        Args:
            ocr_data: Tesseract OCR data dictionary.

        Returns:
            List of TextRegion objects.
        """
        regions = []
        n_boxes = len(ocr_data.get("text", []))

        for i in range(n_boxes):
            text = ocr_data["text"][i].strip()
            if not text:
                continue

            conf = float(ocr_data["conf"][i])
            if conf < 0:
                continue

            fixed_text = self._fix_arabic_text(text)
            lang = self._detect_language(fixed_text)

            region = TextRegion(
                text=fixed_text,
                confidence=conf,
                bbox={
                    "x": int(ocr_data["left"][i]),
                    "y": int(ocr_data["top"][i]),
                    "width": int(ocr_data["width"][i]),
                    "height": int(ocr_data["height"][i]),
                },
                language=lang,
            )
            regions.append(region)

        return regions

    def _fix_arabic_text(self, text: str) -> str:
        """Apply Arabic text reshaping and BiDi reordering.

        Ensures Arabic text is displayed in correct right-to-left order.

        Args:
            text: Raw OCR text.

        Returns:
            Properly ordered Arabic text.
        """
        if not text or not text.strip():
            return text

        try:
            import arabic_reshaper
            from bidi.algorithm import get_display

            reshaped = arabic_reshaper.reshape(text)
            bidi_text = get_display(reshaped)
            return bidi_text
        except ImportError:
            logger.warning(
                "arabic-reshaper or python-bidi not installed. "
                "Arabic text may not display correctly."
            )
            return text

    def _detect_language(self, text: str) -> str:
        """Simple language detection for Arabic vs English text.

        Args:
            text: Text to analyze.

        Returns:
            Language code: 'ara', 'eng', or 'mixed'.
        """
        if not text:
            return "unknown"

        arabic_pattern = re.compile(r"[\u0600-\u06FF\u0750-\u077F\u08A0-\u08FF]")
        latin_pattern = re.compile(r"[a-zA-Z]")

        has_arabic = bool(arabic_pattern.search(text))
        has_latin = bool(latin_pattern.search(text))

        if has_arabic and has_latin:
            return "mixed"
        elif has_arabic:
            return "ara"
        elif has_latin:
            return "eng"
        return "unknown"

    def _detect_tables(
        self, ocr_data: Dict, page_img: PageImage
    ) -> List[DetectedTable]:
        """Detect table structures from OCR data using spatial analysis.

        Uses block/paragraph grouping from Tesseract to identify tabular regions
        based on alignment patterns of text blocks.

        Args:
            ocr_data: Tesseract OCR data dictionary.
            page_img: The page image for dimensions.

        Returns:
            List of DetectedTable objects.
        """
        tables = []

        # Group words by block_num to find potential table rows
        blocks: Dict[int, List[Dict]] = {}
        n_boxes = len(ocr_data.get("text", []))

        for i in range(n_boxes):
            text = ocr_data["text"][i].strip()
            if not text:
                continue

            block_num = ocr_data["block_num"][i]
            if block_num not in blocks:
                blocks[block_num] = []

            blocks[block_num].append(
                {
                    "text": text,
                    "left": ocr_data["left"][i],
                    "top": ocr_data["top"][i],
                    "width": ocr_data["width"][i],
                    "height": ocr_data["height"][i],
                    "conf": ocr_data["conf"][i],
                    "line_num": ocr_data["line_num"][i],
                }
            )

        # Identify blocks that look tabular (multiple lines with consistent columns)
        for block_num, words in blocks.items():
            lines: Dict[int, List[Dict]] = {}
            for w in words:
                line = w["line_num"]
                if line not in lines:
                    lines[line] = []
                lines[line].append(w)

            # A table needs at least 2 rows with consistent column-like spacing
            if len(lines) < 2:
                continue

            # Check if lines have consistent number of "columns" (word groups)
            col_counts = []
            for line_words in lines.values():
                # Group words that are close horizontally
                sorted_words = sorted(line_words, key=lambda w: w["left"])
                groups = self._group_words_by_proximity(sorted_words)
                col_counts.append(len(groups))

            # If most lines have the same column count >= 2, it's likely a table
            if not col_counts:
                continue

            most_common_cols = max(set(col_counts), key=col_counts.count)
            matching = sum(1 for c in col_counts if c == most_common_cols)

            if most_common_cols >= 2 and matching >= len(col_counts) * 0.5:
                table = DetectedTable(
                    table_index=len(tables),
                    rows=len(lines),
                    columns=most_common_cols,
                )

                # Build cells
                for line_num, line_words in sorted(lines.items()):
                    sorted_words = sorted(line_words, key=lambda w: w["left"])
                    groups = self._group_words_by_proximity(sorted_words)
                    for col_idx, group in enumerate(groups):
                        cell_text = " ".join(w["text"] for w in group)
                        cell_text = self._fix_arabic_text(cell_text)
                        confs = [w["conf"] for w in group if w["conf"] >= 0]
                        avg_conf = sum(confs) / len(confs) if confs else 0.0
                        table.cells.append(
                            TableCell(
                                row=line_num,
                                column=col_idx,
                                text=cell_text,
                                confidence=avg_conf,
                            )
                        )

                # Table confidence = avg of cell confidences
                cell_confs = [c.confidence for c in table.cells if c.confidence > 0]
                table.confidence = (
                    sum(cell_confs) / len(cell_confs) if cell_confs else 0.0
                )
                tables.append(table)

        return tables

    def _group_words_by_proximity(
        self, sorted_words: List[Dict], gap_threshold: float = 30.0
    ) -> List[List[Dict]]:
        """Group words that are close together horizontally.

        Args:
            sorted_words: Words sorted by left position.
            gap_threshold: Pixel gap to consider words as separate columns.

        Returns:
            List of word groups (potential columns).
        """
        if not sorted_words:
            return []

        groups = [[sorted_words[0]]]
        for word in sorted_words[1:]:
            prev = groups[-1][-1]
            gap = word["left"] - (prev["left"] + prev["width"])
            if gap > gap_threshold:
                groups.append([word])
            else:
                groups[-1].append(word)

        return groups

