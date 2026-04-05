"""Type definitions for the OCR module.

Provides ``TypedDict`` definitions for Tesseract output data and
``Protocol`` classes for pluggable components (preprocessor, postprocessor,
table detector, language detector).
"""

from typing import Any, Dict, Generator, List, Optional, Protocol, runtime_checkable

from PIL import Image

try:
    from typing import TypedDict
except ImportError:
    from typing_extensions import TypedDict


# ---------------------------------------------------------------------------
# TypedDict definitions for Tesseract OCR output
# ---------------------------------------------------------------------------

class TesseractData(TypedDict):
    """Dictionary returned by ``pytesseract.image_to_data(output_type=DICT)``."""

    text: List[str]
    conf: List[float]
    left: List[int]
    top: List[int]
    width: List[int]
    height: List[int]
    block_num: List[int]
    par_num: List[int]
    line_num: List[int]
    word_num: List[int]


class BBox(TypedDict):
    """Bounding box dictionary used throughout the module."""

    x: int
    y: int
    width: int
    height: int


class AnalyticsPageStat(TypedDict):
    """Per-page statistics from ``get_analytics``."""

    page: int
    confidence: float
    word_count: int
    flagged: bool
    processing_time_s: float


class AnalyticsSummary(TypedDict):
    """Summary statistics from ``get_analytics``."""

    min_confidence: float
    max_confidence: float
    mean_confidence: float
    median_confidence: float
    total_words: int
    total_pages: int
    pages_with_errors: int
    total_error_messages: int
    error_rate: float


class AnalyticsResult(TypedDict):
    """Full analytics result from ``get_analytics``."""

    per_page: List[AnalyticsPageStat]
    histogram: Dict[str, int]
    summary: AnalyticsSummary


# ---------------------------------------------------------------------------
# Protocol definitions for pluggable components
# ---------------------------------------------------------------------------

@runtime_checkable
class ImagePreprocessorProtocol(Protocol):
    """Interface for image pre-processing components."""

    def process(self, image: Image.Image, source_dpi: int = 300) -> Image.Image:
        """Apply pre-processing transforms to an image."""
        ...


@runtime_checkable
class TextPostprocessorProtocol(Protocol):
    """Interface for text post-processing components."""

    def process(self, text: str) -> str:
        """Apply post-processing corrections to OCR text."""
        ...


@runtime_checkable
class LanguageDetectorProtocol(Protocol):
    """Interface for language/script detection."""

    def detect(self, text: str) -> str:
        """Detect dominant language(s) and return Tesseract lang string."""
        ...


@runtime_checkable
class TableDetectorProtocol(Protocol):
    """Interface for table detection components."""

    def detect(self, image: Image.Image) -> list:
        """Detect tables in an image; return list of table objects."""
        ...

