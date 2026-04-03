"""Arabic OCR service for multi-page PDF document processing."""

from .arabic_ocr_service import (
    ArabicOCRService,
    DetectedTable,
    OCRResult,
    PageResult,
    TableCell,
    TextRegion,
)
from .pdf_processor import PDFDocument, PDFProcessor, PageImage

__all__ = [
    "ArabicOCRService",
    "DetectedTable",
    "OCRResult",
    "PageResult",
    "PDFDocument",
    "PDFProcessor",
    "PageImage",
    "TableCell",
    "TextRegion",
]

