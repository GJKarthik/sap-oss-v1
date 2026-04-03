"""Arabic OCR service for multi-page PDF document processing."""

from .arabic_ocr_service import (
    ArabicOCRService,
    DetectedTable,
    OCRResult,
    PageResult,
    TableCell,
    TextRegion,
)
from .cache import DiskCache, OCRCache
from .config import load_config, service_from_config
from .dependencies import DependencyReport, DependencyStatus, check_dependencies
from .differ import DiffReport, PageDiff, diff_results
from .exporters import to_alto_xml, to_hocr, to_plain_text, to_searchable_pdf
from .language_detector import LanguageDetector
from .logging_config import JSONFormatter, RequestContextFilter, configure_logging
from .metrics import OCRMetrics, get_metrics
from .pdf_processor import MAX_DPI, MIN_DPI, PDFDocument, PDFProcessor, PageImage
from .postprocessing import PostprocessingConfig, TextPostprocessor
from .preprocessing import ImagePreprocessor, PreprocessingConfig
from .table_detector import CellBBox, GridTable, TableDetector
from .text_extractor import ExtractionResult, ExtractedPage, TextLayerExtractor
from .types import (
    AnalyticsResult,
    BBox,
    ImagePreprocessorProtocol,
    LanguageDetectorProtocol,
    TableDetectorProtocol,
    TesseractData,
    TextPostprocessorProtocol,
)

__all__ = [
    "AnalyticsResult",
    "ArabicOCRService",
    "BBox",
    "CellBBox",
    "DependencyReport",
    "DependencyStatus",
    "DetectedTable",
    "DiffReport",
    "DiskCache",
    "ExtractionResult",
    "ExtractedPage",
    "GridTable",
    "ImagePreprocessor",
    "ImagePreprocessorProtocol",
    "JSONFormatter",
    "LanguageDetector",
    "LanguageDetectorProtocol",
    "MAX_DPI",
    "MIN_DPI",
    "OCRCache",
    "OCRMetrics",
    "OCRResult",
    "PageDiff",
    "PageResult",
    "PDFDocument",
    "PDFProcessor",
    "PageImage",
    "PostprocessingConfig",
    "PreprocessingConfig",
    "RequestContextFilter",
    "TableCell",
    "TableDetector",
    "TableDetectorProtocol",
    "TesseractData",
    "TextLayerExtractor",
    "TextPostprocessor",
    "TextPostprocessorProtocol",
    "TextRegion",
    "check_dependencies",
    "configure_logging",
    "diff_results",
    "get_metrics",
    "load_config",
    "service_from_config",
    "to_alto_xml",
    "to_hocr",
    "to_plain_text",
    "to_searchable_pdf",
]

