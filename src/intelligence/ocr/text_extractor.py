"""PDF text layer extractor.

Attempts to extract text directly from the PDF's text layer (digitally
created documents) before falling back to OCR.  This is much faster
than OCR for documents that already contain selectable text.

Requires ``PyMuPDF`` (``fitz``) or ``pdfminer.six``.  Falls back
gracefully when neither is available.
"""

import logging
from dataclasses import dataclass, field
from typing import Dict, List, Optional

logger = logging.getLogger(__name__)

# Minimum character count to consider a page as having useful text
_MIN_TEXT_LENGTH = 10


@dataclass
class ExtractedPage:
    """Text extracted from a single PDF page's text layer."""

    page_number: int
    text: str
    has_text_layer: bool = False
    char_count: int = 0


@dataclass
class ExtractionResult:
    """Result of text layer extraction for an entire PDF."""

    file_path: str
    pages: List[ExtractedPage] = field(default_factory=list)
    pages_with_text: int = 0
    pages_without_text: int = 0
    extraction_method: str = ""
    errors: List[str] = field(default_factory=list)


class TextLayerExtractor:
    """Extract text from PDF text layers without OCR.

    Tries PyMuPDF (fitz) first, then pdfminer.six, then returns empty.
    """

    def __init__(self, min_text_length: int = _MIN_TEXT_LENGTH):
        """
        Args:
            min_text_length: Minimum chars on a page to consider it as
                having a useful text layer.
        """
        self.min_text_length = min_text_length

    def extract(
        self,
        file_path: str,
        start_page: Optional[int] = None,
        end_page: Optional[int] = None,
        password: Optional[str] = None,
    ) -> ExtractionResult:
        """Extract text from the PDF text layer.

        Args:
            file_path: Path to the PDF.
            start_page: First page (1-based).  None = first.
            end_page: Last page (1-based).  None = last.
            password: Optional PDF password.

        Returns:
            ExtractionResult with per-page text.
        """
        result = ExtractionResult(file_path=file_path)

        # Try PyMuPDF first
        try:
            return self._extract_fitz(
                file_path, start_page, end_page, password, result
            )
        except ImportError:
            pass
        except Exception as e:
            logger.debug("PyMuPDF extraction failed: %s", e)

        # Try pdfminer.six
        try:
            return self._extract_pdfminer(
                file_path, start_page, end_page, password, result
            )
        except ImportError:
            pass
        except Exception as e:
            logger.debug("pdfminer extraction failed: %s", e)

        result.extraction_method = "none"
        result.errors.append(
            "No text extraction library available. "
            "Install PyMuPDF (pip install PyMuPDF) or "
            "pdfminer.six (pip install pdfminer.six)."
        )
        return result

    def _extract_fitz(
        self, file_path, start_page, end_page, password, result
    ) -> ExtractionResult:
        import fitz  # PyMuPDF

        doc = fitz.open(file_path)
        try:
            if password:
                doc.authenticate(password)

            result.extraction_method = "PyMuPDF"
            total = doc.page_count
            s = (start_page or 1) - 1  # 0-based
            e = end_page or total

            for i in range(s, min(e, total)):
                page = doc[i]
                text = page.get_text().strip()
                has_text = len(text) >= self.min_text_length
                result.pages.append(ExtractedPage(
                    page_number=i + 1,
                    text=text,
                    has_text_layer=has_text,
                    char_count=len(text),
                ))
                if has_text:
                    result.pages_with_text += 1
                else:
                    result.pages_without_text += 1
        finally:
            doc.close()
        return result

    def _extract_pdfminer(
        self, file_path, start_page, end_page, password, result
    ) -> ExtractionResult:
        from pdfminer.high_level import extract_text
        from pdfminer.pdfpage import PDFPage

        result.extraction_method = "pdfminer.six"

        with open(file_path, "rb") as fh:
            total_pages = sum(
                1 for _ in PDFPage.get_pages(fh, password=password or "")
            )

        start_idx = (start_page or 1) - 1
        end_idx = end_page if end_page is not None else total_pages

        for page_idx in range(start_idx, min(end_idx, total_pages)):
            text = extract_text(
                file_path,
                password=password or "",
                page_numbers={page_idx},
            ).strip()
            has_text = len(text) >= self.min_text_length
            result.pages.append(ExtractedPage(
                page_number=page_idx + 1,
                text=text,
                has_text_layer=has_text,
                char_count=len(text),
            ))
            if has_text:
                result.pages_with_text += 1
            else:
                result.pages_without_text += 1
        return result

    def needs_ocr(self, extraction: ExtractionResult) -> bool:
        """Determine if OCR is needed based on text layer quality.

        Returns True if more than half the pages lack useful text.
        """
        if not extraction.pages:
            return True
        return extraction.pages_without_text > extraction.pages_with_text
