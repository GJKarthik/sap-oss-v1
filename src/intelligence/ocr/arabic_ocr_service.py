"""Arabic OCR service for multi-page PDF document processing.

Provides OCR text extraction optimized for Arabic (and mixed Arabic/English)
documents with table detection, confidence scoring, and structured JSON output.
"""

import json
import logging
import re
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import asdict, dataclass, field
from typing import Any, Dict, Generator, List, Optional

from PIL import Image

from .pdf_processor import (
    MAX_DPI,
    MIN_DPI,
    PDFDocument,
    PDFProcessor,
    PageImage,
)
from .cache import OCRCache
from .language_detector import LanguageDetector
from .postprocessing import PostprocessingConfig, TextPostprocessor
from .preprocessing import ImagePreprocessor, PreprocessingConfig
from .table_detector import TableDetector
from .text_extractor import TextLayerExtractor

logger = logging.getLogger(__name__)

# Default gap threshold (pixels) at 300 DPI for table column separation
_BASE_GAP_THRESHOLD_PX = 30.0
_BASE_GAP_DPI = 300

# Minimum table heuristic: fraction of lines matching the dominant column count
_TABLE_COL_MATCH_RATIO = 0.5
# Minimum number of columns to consider a block as a table
_TABLE_MIN_COLUMNS = 2
# Minimum number of lines (rows) to consider a block as a table
_TABLE_MIN_ROWS = 2

# Retry defaults
_DEFAULT_MAX_RETRIES = 0  # disabled by default
_DEFAULT_RETRY_DELAY = 1.0  # seconds between retries (base)
# Timeout default (None = no timeout)
_DEFAULT_PAGE_TIMEOUT: Optional[float] = None


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
    flagged_for_review: bool = False
    processing_time_s: float = 0.0
    errors: List[str] = field(default_factory=list)


@dataclass
class OCRResult:
    """Complete OCR result for a document."""

    file_path: str
    total_pages: int
    pages: List[PageResult] = field(default_factory=list)
    metadata: Dict[str, Any] = field(default_factory=dict)
    overall_confidence: float = 0.0
    total_processing_time_s: float = 0.0
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
    - Multi-page PDF processing with optional parallelism
    - Arabic text extraction with proper RTL ordering
    - Mixed Arabic/English document support
    - Table structure detection (heuristic, spatial-analysis based)
    - Per-page and per-region confidence scoring
    - Structured JSON output
    - Generator-based streaming for memory-efficient processing
    - Configurable image pre-processing pipeline
    - Confidence-based flagging for human review
    - Per-page timeout protection
    - Automatic retry with exponential backoff
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
        max_workers: int = 1,
        preprocessing: Optional[PreprocessingConfig] = None,
        postprocessing: Optional[PostprocessingConfig] = None,
        min_confidence: Optional[float] = None,
        page_timeout: Optional[float] = _DEFAULT_PAGE_TIMEOUT,
        max_retries: int = _DEFAULT_MAX_RETRIES,
        retry_delay: float = _DEFAULT_RETRY_DELAY,
        allowed_dirs: Optional[List[str]] = None,
        password: Optional[str] = None,
        auto_detect_language: bool = False,
        use_line_detection: bool = False,
        enable_cache: bool = False,
        cache_max_size: int = 128,
        skip_ocr_if_text_layer: bool = False,
    ):
        """Initialize the Arabic OCR service.

        Args:
            languages: Tesseract language string (default: "ara+eng" for mixed).
            dpi: Resolution for PDF conversion (72–1200).
            tesseract_config: Additional tesseract configuration flags.
            max_workers: Number of threads for parallel page processing (>=1).
            preprocessing: Optional image pre-processing pipeline config.
            postprocessing: Optional text post-processing pipeline config.
            min_confidence: Pages/regions below this value are flagged
                           for human review.  None = no flagging.
            page_timeout: Maximum seconds per page.  None = no timeout.
            max_retries: Retries per page on transient failure (0 = none).
            retry_delay: Base delay between retries (exponential backoff).
            allowed_dirs: Optional directory whitelist for path sanitization.
            password: Optional password for encrypted PDFs.
            auto_detect_language: If True, run a quick OCR pass first to
                detect the dominant script(s) and select the best Tesseract
                language pack automatically (overrides *languages*).
            use_line_detection: If True, use OpenCV ruling-line analysis
                for table detection in addition to the heuristic approach.
            enable_cache: If True, cache OCR results keyed by file content
                hash + service config hash. Avoids re-processing identical
                documents.
            cache_max_size: Maximum number of cached results (LRU eviction).
            skip_ocr_if_text_layer: If True, attempt to extract text from
                the PDF's embedded text layer first.  Pages with sufficient
                text are skipped for OCR, saving processing time.

        Raises:
            ValueError: If dpi, max_workers, or retry parameters are invalid.
        """
        if not isinstance(max_workers, int) or max_workers < 1:
            raise ValueError(f"max_workers must be >= 1, got {max_workers}")
        if min_confidence is not None and (
            min_confidence < 0 or min_confidence > 100
        ):
            raise ValueError(
                f"min_confidence must be 0–100 or None, got {min_confidence}"
            )
        if page_timeout is not None and page_timeout <= 0:
            raise ValueError(
                f"page_timeout must be > 0 or None, got {page_timeout}"
            )
        if max_retries < 0:
            raise ValueError(f"max_retries must be >= 0, got {max_retries}")
        if retry_delay < 0:
            raise ValueError(f"retry_delay must be >= 0, got {retry_delay}")

        self.languages = languages or self.MIXED_LANG
        self.dpi = dpi
        self.tesseract_config = tesseract_config or "--oem 3 --psm 6"
        self.max_workers = max_workers
        self.min_confidence = min_confidence
        self.page_timeout = page_timeout
        self.max_retries = max_retries
        self.retry_delay = retry_delay
        self.auto_detect_language = auto_detect_language
        self.use_line_detection = use_line_detection
        self.pdf_processor = PDFProcessor(
            dpi=dpi, allowed_dirs=allowed_dirs, password=password,
        )
        self._preprocessing_config = preprocessing
        self._postprocessing_config = postprocessing
        self._preprocessor = (
            ImagePreprocessor(preprocessing) if preprocessing else None
        )
        self._postprocessor = (
            TextPostprocessor(postprocessing) if postprocessing else None
        )
        self._language_detector = (
            LanguageDetector() if auto_detect_language else None
        )
        self._table_detector = (
            TableDetector() if use_line_detection else None
        )
        self._cache = OCRCache(max_size=cache_max_size) if enable_cache else None
        self.skip_ocr_if_text_layer = skip_ocr_if_text_layer
        self._text_extractor = (
            TextLayerExtractor() if skip_ocr_if_text_layer else None
        )
        # DPI-aware gap threshold for table column detection
        self._gap_threshold = _BASE_GAP_THRESHOLD_PX * (dpi / _BASE_GAP_DPI)

    def _config_dict(self) -> dict:
        """Return a dict of config values used for cache key generation."""
        return {
            "languages": self.languages,
            "dpi": self.dpi,
            "tesseract_config": self.tesseract_config,
            "max_workers": self.max_workers,
            "min_confidence": self.min_confidence,
            "page_timeout": self.page_timeout,
            "max_retries": self.max_retries,
            "retry_delay": self.retry_delay,
            "preprocessing": (
                asdict(self._preprocessing_config)
                if self._preprocessing_config is not None
                else None
            ),
            "postprocessing": (
                asdict(self._postprocessing_config)
                if self._postprocessing_config is not None
                else None
            ),
            "auto_detect_language": self.auto_detect_language,
            "use_line_detection": self.use_line_detection,
            "skip_ocr_if_text_layer": self.skip_ocr_if_text_layer,
        }

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
        t0 = time.monotonic()

        # --- Cache lookup ---
        cache_key: Optional[str] = None
        if self._cache is not None:
            try:
                real_path = self.pdf_processor.sanitize_path(file_path)
                cache_key = self._cache.make_key(
                    real_path,
                    {
                        **self._config_dict(),
                        "start_page": start_page,
                        "end_page": end_page,
                        "detect_tables": detect_tables,
                    },
                )
                cached = self._cache.get(cache_key)
                if cached is not None:
                    logger.info("Cache hit for %s", file_path)
                    return cached
            except (OSError, ValueError):
                pass  # file doesn't exist yet — will fail below

        result = OCRResult(file_path=file_path, total_pages=0)

        # --- Text layer extraction (skip OCR for pages with existing text) ---
        text_layer_pages: Dict[int, str] = {}
        if self._text_extractor is not None:
            try:
                extraction = self._text_extractor.extract(
                    file_path, start_page, end_page,
                    password=self.pdf_processor.password,
                )
                for ep in extraction.pages:
                    if ep.has_text_layer:
                        text_layer_pages[ep.page_number] = ep.text
            except Exception as e:
                logger.debug("Text layer extraction failed: %s", e)

        try:
            pdf_doc = self.pdf_processor.process(file_path, start_page, end_page)
        except (FileNotFoundError, ValueError, RuntimeError) as e:
            result.errors.append(str(e))
            return result

        result.total_pages = pdf_doc.total_pages
        result.errors.extend(pdf_doc.errors)

        try:
            pages_to_ocr = []
            for page_img in pdf_doc.pages:
                if page_img.page_number in text_layer_pages:
                    # Use text layer directly — skip OCR
                    page_result = PageResult(
                        page_number=page_img.page_number,
                        text=text_layer_pages[page_img.page_number],
                        width=page_img.width,
                        height=page_img.height,
                    )
                    result.pages.append(page_result)
                else:
                    pages_to_ocr.append(page_img)

            if pages_to_ocr:
                if self.max_workers > 1 and len(pages_to_ocr) > 1:
                    ocr_results = self._process_pages_parallel(
                        pages_to_ocr, detect_tables
                    )
                else:
                    ocr_results = [
                        self._process_page(p, detect_tables)
                        for p in pages_to_ocr
                    ]
                result.pages.extend(ocr_results)

            # Sort by page number
            result.pages.sort(key=lambda p: p.page_number)
        finally:
            pdf_doc.close()

        # Calculate overall confidence & flag low-confidence pages
        if result.pages:
            confidences = [p.confidence for p in result.pages if p.confidence > 0]
            result.overall_confidence = (
                sum(confidences) / len(confidences) if confidences else 0.0
            )
            if self.min_confidence is not None:
                for page in result.pages:
                    if page.confidence < self.min_confidence:
                        page.flagged_for_review = True

        elapsed = time.monotonic() - t0
        result.total_processing_time_s = round(elapsed, 4)
        flagged_count = sum(1 for p in result.pages if p.flagged_for_review)
        result.metadata = {
            "languages": self.languages,
            "dpi": self.dpi,
            "tesseract_config": self.tesseract_config,
            "pages_processed": len(result.pages),
            "pages_with_errors": len([p for p in result.pages if p.errors]),
            "pages_flagged_for_review": flagged_count,
            "preprocessing_enabled": self._preprocessor is not None,
            "total_processing_time_s": result.total_processing_time_s,
            "text_layer_pages_skipped": len(text_layer_pages),
        }

        logger.info(
            f"OCR complete: {len(result.pages)} pages, "
            f"confidence={result.overall_confidence:.2f}, "
            f"flagged={flagged_count}, "
            f"elapsed={elapsed:.2f}s"
        )

        # --- Cache store ---
        if self._cache is not None and cache_key is not None:
            self._cache.put(cache_key, result)

        return result

    def process_pdf_pages(
        self,
        file_path: str,
        start_page: Optional[int] = None,
        end_page: Optional[int] = None,
        detect_tables: bool = True,
    ) -> Generator[PageResult, None, None]:
        """Process a PDF and yield results one page at a time.

        Memory-efficient alternative to process_pdf(): each page image is
        released after its result is yielded.

        Args:
            file_path: Path to the PDF file.
            start_page: First page to process (1-based). None = first.
            end_page: Last page to process (1-based). None = last.
            detect_tables: Whether to attempt table detection.

        Yields:
            PageResult for each processed page.
        """
        for page_img in self.pdf_processor.process_pages(
            file_path, start_page, end_page
        ):
            try:
                yield self._process_page(page_img, detect_tables)
            finally:
                page_img.close()

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

    def process_region(
        self,
        image: Image.Image,
        x: int,
        y: int,
        width: int,
        height: int,
        detect_tables: bool = False,
    ) -> PageResult:
        """OCR a specific rectangular region of an image.

        Crops the image to the bounding box ``(x, y, x+width, y+height)``
        and runs OCR only on that region.  Useful for form fields, headers,
        stamps, or other known areas.

        Args:
            image: Full PIL Image.
            x: Left edge of region (pixels).
            y: Top edge of region (pixels).
            width: Width of region (pixels).
            height: Height of region (pixels).
            detect_tables: Whether to detect tables in the region.

        Returns:
            PageResult for the cropped region.

        Raises:
            ValueError: If the bounding box is invalid or outside image.
        """
        if width <= 0 or height <= 0:
            raise ValueError(
                f"Region dimensions must be positive, got {width}×{height}"
            )
        if x < 0 or y < 0:
            raise ValueError(f"Region origin must be non-negative, got ({x}, {y})")
        if x + width > image.width or y + height > image.height:
            raise ValueError(
                f"Region ({x},{y},{width},{height}) exceeds image "
                f"bounds ({image.width}×{image.height})"
            )

        cropped = image.crop((x, y, x + width, y + height))
        result = self.process_image(cropped, detect_tables)
        # Adjust region bounding boxes to be relative to the full image
        for region in result.text_regions:
            if region.bbox:
                region.bbox["x"] += x
                region.bbox["y"] += y
        return result

    @staticmethod
    def get_analytics(result: "OCRResult") -> Dict[str, Any]:
        """Compute confidence analytics for an OCR result.

        Returns a dict with:
          - per_page: list of {page, confidence, word_count, flagged}
          - histogram: confidence bucket counts (0-10, 10-20, ..., 90-100)
          - summary: min/max/mean/median confidence, total words,
            ``pages_with_errors`` (count of pages with ≥1 error message),
            ``total_error_messages`` (sum of error strings), and
            ``error_rate`` (fraction of pages with errors).

        Args:
            result: An OCRResult to analyse.

        Returns:
            Analytics dict.
        """
        page_stats = []
        all_confidences: List[float] = []
        total_words = 0
        pages_with_errors_count = 0
        total_error_messages = 0

        for page in result.pages:
            word_count = len(page.text.split()) if page.text else 0
            total_words += word_count
            err_n = len(page.errors)
            total_error_messages += err_n
            if err_n:
                pages_with_errors_count += 1
            page_stats.append({
                "page": page.page_number,
                "confidence": round(page.confidence, 2),
                "word_count": word_count,
                "flagged": page.flagged_for_review,
                "processing_time_s": page.processing_time_s,
            })
            if page.confidence > 0:
                all_confidences.append(page.confidence)
            # Collect word-level confidences
            for region in page.text_regions:
                if region.confidence > 0:
                    all_confidences.append(region.confidence)

        # Histogram: 10 buckets
        histogram = {f"{i*10}-{(i+1)*10}": 0 for i in range(10)}
        for conf in all_confidences:
            bucket = min(int(conf // 10), 9)
            key = f"{bucket*10}-{(bucket+1)*10}"
            histogram[key] += 1

        # Summary statistics
        sorted_conf = sorted(all_confidences) if all_confidences else [0.0]
        n = len(sorted_conf)
        median = (
            sorted_conf[n // 2]
            if n % 2 == 1
            else (sorted_conf[n // 2 - 1] + sorted_conf[n // 2]) / 2
        )
        summary = {
            "min_confidence": round(min(sorted_conf), 2),
            "max_confidence": round(max(sorted_conf), 2),
            "mean_confidence": round(
                sum(sorted_conf) / n if n else 0, 2
            ),
            "median_confidence": round(median, 2),
            "total_words": total_words,
            "total_pages": len(result.pages),
            "pages_with_errors": pages_with_errors_count,
            "total_error_messages": total_error_messages,
            "error_rate": round(
                pages_with_errors_count / len(result.pages)
                if result.pages
                else 0,
                4,
            ),
        }

        return {
            "per_page": page_stats,
            "histogram": histogram,
            "summary": summary,
        }


    def process_tiff(
        self,
        file_path: str,
        detect_tables: bool = True,
    ) -> "OCRResult":
        """Process a multi-frame TIFF file (each frame = one page).

        Args:
            file_path: Path to the TIFF file.
            detect_tables: Whether to detect tables.

        Returns:
            OCRResult with one PageResult per TIFF frame.
        """
        import os as _os

        t0 = time.monotonic()
        result = OCRResult(file_path=file_path, total_pages=0)

        if not _os.path.exists(file_path):
            result.errors.append(f"File not found: {file_path}")
            return result

        try:
            tiff = Image.open(file_path)
        except (OSError, ValueError) as e:
            result.errors.append(f"Cannot open TIFF: {e}")
            return result

        try:
            page_idx = 0
            while True:
                page_idx += 1
                frame = tiff.copy()
                try:
                    rgb = frame.convert("RGB")
                    page_img = PageImage(
                        page_number=page_idx,
                        image=rgb,
                        width=frame.width,
                        height=frame.height,
                        dpi=self.dpi,
                    )
                    page_result = self._process_page(page_img, detect_tables)
                    result.pages.append(page_result)
                finally:
                    frame.close()
                try:
                    tiff.seek(tiff.tell() + 1)
                except EOFError:
                    break
        finally:
            tiff.close()

        result.total_pages = len(result.pages)

        elapsed = time.monotonic() - t0
        result.total_processing_time_s = round(elapsed, 4)
        if result.pages:
            confs = [p.confidence for p in result.pages if p.confidence > 0]
            result.overall_confidence = (
                sum(confs) / len(confs) if confs else 0.0
            )
        result.metadata = {
            "languages": self.languages,
            "dpi": self.dpi,
            "format": "tiff",
            "pages_processed": len(result.pages),
        }
        return result

    def process_directory(
        self,
        dir_path: str,
        extensions: Optional[List[str]] = None,
        detect_tables: bool = True,
    ) -> List["OCRResult"]:
        """Process all image/PDF files in a directory.

        Args:
            dir_path: Path to directory.
            extensions: File extensions to include (default: common formats).
            detect_tables: Whether to detect tables.

        Returns:
            List of OCRResult, one per file.
        """
        import glob
        import os as _os

        if extensions is None:
            extensions = [".pdf", ".png", ".jpg", ".jpeg", ".tiff", ".tif", ".bmp"]

        results: List[OCRResult] = []
        for ext in extensions:
            pattern = _os.path.join(dir_path, f"*{ext}")
            for filepath in sorted(glob.glob(pattern)):
                if ext == ".pdf":
                    results.append(
                        self.process_pdf(filepath, detect_tables=detect_tables)
                    )
                elif ext in (".tiff", ".tif"):
                    results.append(
                        self.process_tiff(filepath, detect_tables=detect_tables)
                    )
                else:
                    with Image.open(filepath) as img:
                        page_result = self.process_image(img, detect_tables)
                    results.append(OCRResult(
                        file_path=filepath,
                        total_pages=1,
                        pages=[page_result],
                        overall_confidence=page_result.confidence,
                    ))
        return results



    async def process_pdf_async(
        self,
        file_path: str,
        start_page: Optional[int] = None,
        end_page: Optional[int] = None,
        detect_tables: bool = True,
    ) -> "OCRResult":
        """Async wrapper around process_pdf for use in async frameworks.

        Runs the synchronous OCR processing in a background thread via
        ``asyncio.to_thread`` so it does not block the event loop.

        Args:
            file_path: Path to the PDF file.
            start_page: First page to process (1-based). None = first.
            end_page: Last page to process (1-based). None = last.
            detect_tables: Whether to attempt table detection.

        Returns:
            OCRResult with page-by-page text, tables, and metadata.
        """
        import asyncio

        return await asyncio.to_thread(
            self.process_pdf, file_path, start_page, end_page, detect_tables
        )

    async def process_image_async(
        self, image: Image.Image, detect_tables: bool = True
    ) -> PageResult:
        """Async wrapper around process_image.

        Args:
            image: PIL Image to process.
            detect_tables: Whether to attempt table detection.

        Returns:
            PageResult with extracted text and metadata.
        """
        import asyncio

        return await asyncio.to_thread(
            self.process_image, image, detect_tables
        )

    async def process_pdf_stream_async(
        self,
        file_path: str,
        start_page: Optional[int] = None,
        end_page: Optional[int] = None,
        detect_tables: bool = True,
    ):
        """Async generator that yields PageResult for each page.

        Each page is processed in a background thread, and results are
        yielded one at a time for real-time streaming in async frameworks.

        Usage::

            async for page_result in service.process_pdf_stream_async("doc.pdf"):
                print(page_result.text)

        Args:
            file_path: Path to the PDF file.
            start_page: First page (1-based). None = first.
            end_page: Last page (1-based). None = last.
            detect_tables: Whether to detect tables.

        Yields:
            PageResult for each page.
        """
        import asyncio

        # Get all page images synchronously (needed for pdf2image)
        pdf_doc = await asyncio.to_thread(
            self.pdf_processor.process, file_path, start_page, end_page
        )
        try:
            for page_img in pdf_doc.pages:
                page_result = await asyncio.to_thread(
                    self._process_page, page_img, detect_tables
                )
                yield page_result
        finally:
            pdf_doc.close()




    def _process_pages_parallel(
        self,
        pages: List[PageImage],
        detect_tables: bool,
    ) -> List[PageResult]:
        """Process multiple pages in parallel using a thread pool.

        Args:
            pages: List of PageImage objects to process.
            detect_tables: Whether to detect tables.

        Returns:
            List of PageResult in original page order.
        """
        results: List[Optional[PageResult]] = [None] * len(pages)

        with ThreadPoolExecutor(max_workers=self.max_workers) as executor:
            future_to_idx = {
                executor.submit(self._process_page, page, detect_tables): idx
                for idx, page in enumerate(pages)
            }
            for future in as_completed(future_to_idx):
                idx = future_to_idx[future]
                results[idx] = future.result()

        return [r for r in results if r is not None]

    def _process_page(
        self, page_img: PageImage, detect_tables: bool
    ) -> PageResult:
        """Process a single page image through OCR.

        Applies optional pre-processing, runs OCR with retry/timeout,
        flags low-confidence results, and avoids duplicate Tesseract calls.

        Args:
            page_img: PageImage to process.
            detect_tables: Whether to detect tables.

        Returns:
            PageResult with extracted text.
        """
        page_t0 = time.monotonic()
        page_result = PageResult(
            page_number=page_img.page_number,
            text="",
            width=page_img.width,
            height=page_img.height,
        )

        # --- Pre-processing ---
        ocr_image = page_img.image
        if self._preprocessor is not None:
            try:
                ocr_image = self._preprocessor.process(
                    page_img.image, source_dpi=page_img.dpi
                )
            except (OSError, ValueError) as e:
                logger.warning(
                    "Preprocessing failed on page %d: %s",
                    page_img.page_number, e,
                )

        # --- OCR with retry ---
        last_error: Optional[Exception] = None
        attempts = 1 + self.max_retries
        for attempt in range(attempts):
            try:
                self._run_ocr(ocr_image, page_result, detect_tables, page_img)
                last_error = None
                break  # success
            except ImportError:
                page_result.errors.append(
                    "pytesseract is not installed. "
                    "Install with: pip install pytesseract"
                )
                return page_result  # no point retrying
            except (OSError, RuntimeError, UnicodeDecodeError) as e:
                last_error = e
                if attempt < self.max_retries:
                    delay = self.retry_delay * (2 ** attempt)
                    logger.warning(
                        "OCR attempt %d/%d failed on page %d: %s — "
                        "retrying in %.1fs",
                        attempt + 1, attempts,
                        page_img.page_number, e, delay,
                    )
                    time.sleep(delay)

        if last_error is not None:
            page_result.errors.append(
                f"OCR error on page {page_img.page_number}: {last_error}"
            )
            logger.error(
                "OCR error on page %d after %d attempt(s): %s",
                page_img.page_number, attempts, last_error,
            )

        # --- Confidence flagging ---
        if (
            self.min_confidence is not None
            and page_result.confidence < self.min_confidence
        ):
            page_result.flagged_for_review = True

        page_result.processing_time_s = round(
            time.monotonic() - page_t0, 4
        )
        return page_result

    def _run_ocr(
        self,
        image: Image.Image,
        page_result: PageResult,
        detect_tables: bool,
        page_img: PageImage,
    ) -> None:
        """Execute a single OCR pass on *image*, populating *page_result*.

        When ``auto_detect_language`` is enabled, a quick initial OCR pass
        is used to determine the dominant script before the full run.

        Raises:
            ImportError: If pytesseract is missing.
            OSError, RuntimeError, UnicodeDecodeError: On Tesseract failure.
        """
        import pytesseract

        timeout_deadline = (
            time.monotonic() + self.page_timeout
            if self.page_timeout is not None
            else None
        )

        def _remaining_timeout() -> Optional[float]:
            if timeout_deadline is None:
                return None
            remaining = timeout_deadline - time.monotonic()
            if remaining <= 0:
                raise RuntimeError(f"OCR timed out after {self.page_timeout}s")
            return remaining

        def _call_image_to_string(ocr_lang: str, config: str) -> str:
            kwargs = {"lang": ocr_lang, "config": config}
            remaining = _remaining_timeout()
            if remaining is not None:
                kwargs["timeout"] = remaining
            return pytesseract.image_to_string(image, **kwargs).strip()

        def _call_image_to_data() -> Dict[str, List[Any]]:
            kwargs = {
                "lang": lang,
                "config": self.tesseract_config,
                "output_type": pytesseract.Output.DICT,
            }
            remaining = _remaining_timeout()
            if remaining is not None:
                kwargs["timeout"] = remaining
            return pytesseract.image_to_data(image, **kwargs)

        # --- Auto-language detection ---
        lang = self.languages
        if self._language_detector is not None:
            quick = ""
            # Try OSD mode first, but only if the osd traineddata is available
            try:
                osd_langs = pytesseract.get_languages()
                if "osd" in osd_langs:
                    quick = _call_image_to_string("osd", "--psm 0")
            except (OSError, RuntimeError):
                pass  # OSD not available
            # Fallback: use the configured languages with normal PSM
            if not quick:
                try:
                    quick = _call_image_to_string(self.languages, "--psm 6")
                except (OSError, RuntimeError):
                    pass
            if quick:
                detected = self._language_detector.detect(quick)
                if detected:
                    lang = detected
                    logger.debug("Auto-detected language: %s", lang)

        try:
            ocr_data = _call_image_to_data()
        except RuntimeError as e:
            if self.page_timeout is not None and "timeout" in str(e).lower():
                raise RuntimeError(
                    f"OCR timed out after {self.page_timeout}s"
                ) from e
            raise

        page_result.text_regions = self._extract_regions(ocr_data)

        raw_text = self._reconstruct_text(ocr_data)
        page_result.text = self._fix_arabic_text(raw_text)

        # --- Post-processing ---
        if self._postprocessor is not None:
            page_result.text = self._postprocessor.process(page_result.text)

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

        # --- Table detection ---
        if detect_tables:
            page_result.tables = self._detect_tables(ocr_data, page_img)
            # Augment with OpenCV line-based detection
            if self._table_detector is not None:
                grid_tables = self._table_detector.detect(page_img.image)
                for gt in grid_tables:
                    page_result.tables.append(DetectedTable(
                        table_index=len(page_result.tables),
                        rows=gt.rows,
                        columns=gt.cols,
                        confidence=0.0,
                    ))

    @staticmethod
    def _reconstruct_text(ocr_data: Dict[str, List[Any]]) -> str:
        """Reconstruct page text from Tesseract image_to_data output.

        Groups words by block/paragraph/line and joins with appropriate
        whitespace, avoiding a redundant image_to_string call.

        Args:
            ocr_data: Tesseract OCR data dictionary.

        Returns:
            Reconstructed full-page text.
        """
        n_boxes = len(ocr_data.get("text", []))
        if n_boxes == 0:
            return ""

        lines: Dict[tuple, List[tuple]] = {}
        for i in range(n_boxes):
            text = ocr_data["text"][i]
            if not text.strip():
                continue
            key = (
                ocr_data["block_num"][i],
                ocr_data["par_num"][i] if "par_num" in ocr_data else 0,
                ocr_data["line_num"][i],
            )
            lines.setdefault(key, []).append((ocr_data["word_num"][i], text))

        sorted_keys = sorted(lines.keys())
        result_lines: List[str] = []
        prev_block = None
        for key in sorted_keys:
            block = key[0]
            if prev_block is not None and block != prev_block:
                result_lines.append("")  # blank line between blocks
            prev_block = block
            words = [w[1] for w in sorted(lines[key], key=lambda x: x[0])]
            result_lines.append(" ".join(words))

        return "\n".join(result_lines)

    def _extract_regions(self, ocr_data: Dict) -> List[TextRegion]:
        """Extract text regions with bounding boxes from OCR data.

        Language detection is performed on raw text (before reshaping)
        to avoid confusing the Arabic character detection heuristic.

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

            # Detect language on raw text, then reshape
            lang = self._detect_language(text)
            fixed_text = self._fix_arabic_text(text)

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

    # Pre-compiled patterns for language detection (class-level, compiled once)
    _ARABIC_PATTERN = re.compile(
        r"[\u0600-\u06FF\u0750-\u077F\u08A0-\u08FF]"
    )
    _LATIN_PATTERN = re.compile(r"[a-zA-Z]")

    def _detect_language(self, text: str) -> str:
        """Simple language detection for Arabic vs English text.

        Args:
            text: Text to analyze.

        Returns:
            Language code: 'ara', 'eng', 'mixed', or 'unknown'.
        """
        if not text:
            return "unknown"

        has_arabic = bool(self._ARABIC_PATTERN.search(text))
        has_latin = bool(self._LATIN_PATTERN.search(text))

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
        based on alignment patterns of text blocks.  The gap threshold is
        DPI-aware (scaled relative to 300 DPI baseline).

        Args:
            ocr_data: Tesseract OCR data dictionary.
            page_img: The page image for dimensions.

        Returns:
            List of DetectedTable objects.
        """
        tables: List[DetectedTable] = []

        # Group words by block_num to find potential table rows
        blocks: Dict[int, List[Dict]] = {}
        n_boxes = len(ocr_data.get("text", []))

        for i in range(n_boxes):
            text = ocr_data["text"][i].strip()
            if not text:
                continue

            block_num = ocr_data["block_num"][i]
            blocks.setdefault(block_num, []).append(
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
                lines.setdefault(w["line_num"], []).append(w)

            if len(lines) < _TABLE_MIN_ROWS:
                continue

            # Check if lines have consistent number of "columns" (word groups)
            col_counts = []
            for line_words in lines.values():
                sorted_words = sorted(line_words, key=lambda w: w["left"])
                groups = self._group_words_by_proximity(sorted_words)
                col_counts.append(len(groups))

            if not col_counts:
                continue

            most_common_cols = max(set(col_counts), key=col_counts.count)
            matching = sum(1 for c in col_counts if c == most_common_cols)

            if (
                most_common_cols >= _TABLE_MIN_COLUMNS
                and matching >= len(col_counts) * _TABLE_COL_MATCH_RATIO
            ):
                table = DetectedTable(
                    table_index=len(tables),
                    rows=len(lines),
                    columns=most_common_cols,
                )

                # Build cells — apply Arabic reshaping per cell
                for line_num, line_words in sorted(lines.items()):
                    sorted_words = sorted(line_words, key=lambda w: w["left"])
                    groups = self._group_words_by_proximity(sorted_words)
                    for col_idx, group in enumerate(groups):
                        cell_text = " ".join(w["text"] for w in group)
                        cell_text = self._fix_arabic_text(cell_text)
                        confs = [
                            w["conf"] for w in group if w["conf"] >= 0
                        ]
                        avg_conf = (
                            sum(confs) / len(confs) if confs else 0.0
                        )
                        table.cells.append(
                            TableCell(
                                row=line_num,
                                column=col_idx,
                                text=cell_text,
                                confidence=avg_conf,
                            )
                        )

                # Table confidence = avg of cell confidences
                cell_confs = [
                    c.confidence for c in table.cells if c.confidence > 0
                ]
                table.confidence = (
                    sum(cell_confs) / len(cell_confs) if cell_confs else 0.0
                )
                tables.append(table)

        return tables

    def _group_words_by_proximity(
        self,
        sorted_words: List[Dict],
        gap_threshold: Optional[float] = None,
    ) -> List[List[Dict]]:
        """Group words that are close together horizontally.

        Args:
            sorted_words: Words sorted by left position.
            gap_threshold: Pixel gap to consider words as separate columns.
                           Defaults to the DPI-aware instance threshold.

        Returns:
            List of word groups (potential columns).
        """
        if not sorted_words:
            return []

        if gap_threshold is None:
            gap_threshold = self._gap_threshold

        groups = [[sorted_words[0]]]
        for word in sorted_words[1:]:
            prev = groups[-1][-1]
            gap = word["left"] - (prev["left"] + prev["width"])
            if gap > gap_threshold:
                groups.append([word])
            else:
                groups[-1].append(word)

        return groups
