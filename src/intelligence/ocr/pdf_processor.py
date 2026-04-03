"""Multi-page PDF processor for OCR pipeline.

Converts PDF documents into per-page PIL images suitable for OCR processing.
"""

import logging
import os
from dataclasses import dataclass, field
from typing import List, Optional

from PIL import Image

logger = logging.getLogger(__name__)


@dataclass
class PageImage:
    """Represents a single page extracted from a PDF as an image."""

    page_number: int
    image: Image.Image
    width: int
    height: int
    dpi: int = 300


@dataclass
class PDFDocument:
    """Represents a processed PDF document with extracted page images."""

    file_path: str
    total_pages: int
    pages: List[PageImage] = field(default_factory=list)
    errors: List[str] = field(default_factory=list)


class PDFProcessor:
    """Handles multi-page PDF to image conversion for OCR processing."""

    def __init__(self, dpi: int = 300, image_format: str = "PNG"):
        """Initialize the PDF processor.

        Args:
            dpi: Resolution for PDF to image conversion. Higher = better OCR but slower.
            image_format: Output image format (PNG recommended for OCR).
        """
        self.dpi = dpi
        self.image_format = image_format

    def validate_pdf(self, file_path: str) -> None:
        """Validate that the file exists and appears to be a PDF.

        Args:
            file_path: Path to the PDF file.

        Raises:
            FileNotFoundError: If file does not exist.
            ValueError: If file is not a PDF or is corrupted.
        """
        if not os.path.exists(file_path):
            raise FileNotFoundError(f"PDF file not found: {file_path}")

        if not file_path.lower().endswith(".pdf"):
            raise ValueError(f"File does not have .pdf extension: {file_path}")

        if os.path.getsize(file_path) == 0:
            raise ValueError(f"PDF file is empty: {file_path}")

        # Check PDF magic bytes
        with open(file_path, "rb") as f:
            header = f.read(5)
            if header != b"%PDF-":
                raise ValueError(f"File does not appear to be a valid PDF: {file_path}")

    def process(
        self,
        file_path: str,
        start_page: Optional[int] = None,
        end_page: Optional[int] = None,
    ) -> PDFDocument:
        """Convert a PDF file into a list of page images.

        Args:
            file_path: Path to the PDF file.
            start_page: First page to process (1-based, inclusive). None = first page.
            end_page: Last page to process (1-based, inclusive). None = last page.

        Returns:
            PDFDocument with extracted page images.

        Raises:
            FileNotFoundError: If file does not exist.
            ValueError: If file is invalid.
            RuntimeError: If PDF conversion fails.
        """
        self.validate_pdf(file_path)

        try:
            from pdf2image import convert_from_path

            convert_kwargs = {"dpi": self.dpi, "fmt": self.image_format}
            if start_page is not None:
                convert_kwargs["first_page"] = start_page
            if end_page is not None:
                convert_kwargs["last_page"] = end_page

            images = convert_from_path(file_path, **convert_kwargs)
        except ImportError:
            raise RuntimeError(
                "pdf2image is not installed. Install it with: pip install pdf2image"
            )
        except Exception as e:
            raise RuntimeError(f"Failed to convert PDF to images: {e}")

        doc = PDFDocument(file_path=file_path, total_pages=len(images))

        base_page = start_page if start_page is not None else 1
        for idx, img in enumerate(images):
            page_num = base_page + idx
            try:
                page = PageImage(
                    page_number=page_num,
                    image=img,
                    width=img.width,
                    height=img.height,
                    dpi=self.dpi,
                )
                doc.pages.append(page)
            except Exception as e:
                error_msg = f"Error processing page {page_num}: {e}"
                logger.warning(error_msg)
                doc.errors.append(error_msg)

        logger.info(
            f"Processed {len(doc.pages)} pages from {file_path} "
            f"({len(doc.errors)} errors)"
        )
        return doc

