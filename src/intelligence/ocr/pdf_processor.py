"""Multi-page PDF processor for OCR pipeline.

Converts PDF documents into per-page PIL images suitable for OCR processing.
"""

import logging
import os
import struct
from dataclasses import dataclass, field
from typing import Generator, List, Optional, Sequence

from PIL import Image

logger = logging.getLogger(__name__)

# Minimum acceptable DPI for OCR processing
MIN_DPI = 72
# Maximum DPI to prevent excessive memory usage
MAX_DPI = 1200


@dataclass
class PageImage:
    """Represents a single page extracted from a PDF as an image."""

    page_number: int
    image: Image.Image
    width: int
    height: int
    dpi: int = 300

    def close(self) -> None:
        """Release the underlying PIL image memory."""
        if self.image is not None:
            self.image.close()


@dataclass
class PDFDocument:
    """Represents a processed PDF document with extracted page images.

    Supports context manager protocol for automatic resource cleanup.
    """

    file_path: str
    total_pages: int
    pages: List[PageImage] = field(default_factory=list)
    pages_processed: int = 0
    errors: List[str] = field(default_factory=list)

    def close(self) -> None:
        """Release all page image resources."""
        for page in self.pages:
            page.close()

    def __enter__(self) -> "PDFDocument":
        return self

    def __exit__(self, exc_type: object, exc_val: object, exc_tb: object) -> None:
        self.close()


class PDFProcessor:
    """Handles multi-page PDF to image conversion for OCR processing."""

    def __init__(
        self,
        dpi: int = 300,
        image_format: str = "PNG",
        allowed_dirs: Optional[Sequence[str]] = None,
        password: Optional[str] = None,
        chunk_size: Optional[int] = None,
    ):
        """Initialize the PDF processor.

        Args:
            dpi: Resolution for PDF to image conversion (72–1200).
                 Higher = better OCR but slower.
            image_format: Output image format (PNG recommended for OCR).
            allowed_dirs: Optional whitelist of directory paths.  When set,
                          only PDFs inside one of these directories (resolved
                          via ``os.path.realpath``) are accepted.
            password: Optional password for encrypted/protected PDFs.
            chunk_size: If set, convert pages in chunks of this size to
                        limit peak memory usage.  None = all at once.

        Raises:
            ValueError: If dpi is outside the valid range.
        """
        if not isinstance(dpi, int) or dpi < MIN_DPI or dpi > MAX_DPI:
            raise ValueError(
                f"dpi must be an integer between {MIN_DPI} and {MAX_DPI}, got {dpi}"
            )
        if chunk_size is not None and (not isinstance(chunk_size, int) or chunk_size < 1):
            raise ValueError(f"chunk_size must be >= 1 or None, got {chunk_size}")
        self.dpi = dpi
        self.image_format = image_format
        self.chunk_size = chunk_size
        self.allowed_dirs: Optional[List[str]] = (
            [os.path.realpath(d) for d in allowed_dirs]
            if allowed_dirs is not None
            else None
        )
        self.password = password

    def sanitize_path(self, file_path: str) -> str:
        """Resolve and validate a file path against the allowed_dirs whitelist.

        Args:
            file_path: Raw file path from caller.

        Returns:
            Canonicalized absolute path.

        Raises:
            ValueError: If the path is outside every allowed directory.
        """
        real = os.path.realpath(file_path)
        if self.allowed_dirs is not None:
            if not any(real.startswith(d + os.sep) or real == d
                       for d in self.allowed_dirs):
                raise ValueError(
                    f"File path is outside allowed directories: {file_path}"
                )
        return real

    def validate_pdf(self, file_path: str) -> None:
        """Validate that the file exists and appears to be a valid PDF.

        Checks existence, extension, size, magic bytes, and encryption status.

        Args:
            file_path: Path to the PDF file (already sanitized).

        Raises:
            FileNotFoundError: If file does not exist.
            ValueError: If file is not a PDF, is corrupted, or is encrypted
                        and no password was provided.
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
                raise ValueError(
                    f"File does not appear to be a valid PDF: {file_path}"
                )

        # Detect encrypted/password-protected PDF
        if self._is_encrypted(file_path) and self.password is None:
            raise ValueError(
                f"PDF is password-protected and no password was provided: "
                f"{file_path}"
            )

    @staticmethod
    def _is_encrypted(file_path: str) -> bool:
        """Quick heuristic check for PDF encryption markers.

        Scans the last 4 KB of the file for ``/Encrypt`` dictionary entry
        which is present in password-protected PDFs.

        Args:
            file_path: Path to the PDF.

        Returns:
            True if the PDF appears to be encrypted.
        """
        try:
            size = os.path.getsize(file_path)
            read_size = min(size, 4096)
            with open(file_path, "rb") as f:
                f.seek(max(0, size - read_size))
                tail = f.read(read_size)
            return b"/Encrypt" in tail
        except OSError:
            return False


    @staticmethod
    def detect_pdfa(file_path: str) -> Optional[str]:
        """Detect whether a PDF is PDF/A and return the conformance level.

        Scans the first 4 KB of the file for ``pdfaid:conformance`` and
        ``pdfaid:part`` XMP metadata markers.

        Args:
            file_path: Path to the PDF.

        Returns:
            Conformance string like ``"PDF/A-1b"`` or ``"PDF/A-2a"``,
            or None if the file is not PDF/A.
        """
        try:
            with open(file_path, "rb") as f:
                head = f.read(8192)
            # Look for XMP metadata with PDF/A markers
            head_str = head.decode("latin-1", errors="ignore")
            part = None
            conformance = None
            import re
            part_match = re.search(r"pdfaid:part[>\s]*(\d+)", head_str, re.IGNORECASE)
            conf_match = re.search(r"pdfaid:conformance[>\s]*([A-Za-z])", head_str, re.IGNORECASE)
            if part_match:
                part = part_match.group(1)
            if conf_match:
                conformance = conf_match.group(1).lower()
            if part:
                level = conformance or "?"
                return f"PDF/A-{part}{level}"
            return None
        except OSError:
            return None


    def _validate_page_range(
        self,
        start_page: Optional[int],
        end_page: Optional[int],
    ) -> None:
        """Validate page range arguments.

        Args:
            start_page: First page (1-based). None = first page.
            end_page: Last page (1-based). None = last page.

        Raises:
            ValueError: If page range is invalid.
        """
        if start_page is not None and start_page < 1:
            raise ValueError(f"start_page must be >= 1, got {start_page}")
        if end_page is not None and end_page < 1:
            raise ValueError(f"end_page must be >= 1, got {end_page}")
        if (
            start_page is not None
            and end_page is not None
            and start_page > end_page
        ):
            raise ValueError(
                f"start_page ({start_page}) must be <= end_page ({end_page})"
            )

    def _get_total_pages(self, file_path: str) -> int:
        """Get the total number of pages in a PDF without converting.

        Args:
            file_path: Path to the PDF file.

        Returns:
            Total page count.
        """
        try:
            from pdf2image import pdfinfo_from_path

            info = pdfinfo_from_path(file_path)
            return info.get("Pages", 0)
        except (ImportError, Exception):
            # Fallback: unknown total pages
            return 0

    def _build_convert_kwargs(
        self,
        start_page: Optional[int] = None,
        end_page: Optional[int] = None,
    ) -> dict:
        """Build keyword arguments for ``pdf2image.convert_from_path``."""
        kwargs: dict = {"dpi": self.dpi, "fmt": self.image_format}
        if start_page is not None:
            kwargs["first_page"] = start_page
        if end_page is not None:
            kwargs["last_page"] = end_page
        if self.password is not None:
            kwargs["userpw"] = self.password
        return kwargs

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
            ValueError: If file is invalid or page range is bad.
            RuntimeError: If PDF conversion fails.
        """
        file_path = self.sanitize_path(file_path)
        self.validate_pdf(file_path)
        self._validate_page_range(start_page, end_page)

        total_pages = self._get_total_pages(file_path)

        try:
            from pdf2image import convert_from_path
            from pdf2image.exceptions import (
                PDFInfoNotInstalledError,
                PDFPageCountError,
                PDFSyntaxError,
            )
        except ImportError:
            raise RuntimeError(
                "pdf2image is not installed. Install it with: pip install pdf2image"
            )

        effective_start = start_page if start_page is not None else 1
        effective_end = end_page if end_page is not None else (
            total_pages if total_pages > 0 else None
        )

        try:
            if self.chunk_size is not None:
                images = self._convert_chunked(
                    convert_from_path, file_path,
                    effective_start, effective_end,
                )
            else:
                convert_kwargs = self._build_convert_kwargs(start_page, end_page)
                images = convert_from_path(file_path, **convert_kwargs)
        except (
            OSError,
            ValueError,
            PDFInfoNotInstalledError,
            PDFPageCountError,
            PDFSyntaxError,
        ) as e:
            raise RuntimeError(f"Failed to convert PDF to images: {e}")

        actual_total = total_pages if total_pages > 0 else len(images)
        doc = PDFDocument(
            file_path=file_path,
            total_pages=actual_total,
            pages_processed=len(images),
        )

        for idx, img in enumerate(images):
            page_num = effective_start + idx
            try:
                page = PageImage(
                    page_number=page_num,
                    image=img,
                    width=img.width,
                    height=img.height,
                    dpi=self.dpi,
                )
                doc.pages.append(page)
            except (AttributeError, TypeError) as e:
                error_msg = f"Error processing page {page_num}: {e}"
                logger.warning(error_msg)
                doc.errors.append(error_msg)

        logger.info(
            f"Processed {len(doc.pages)}/{doc.total_pages} pages from "
            f"{file_path} ({len(doc.errors)} errors)"
        )
        return doc

    def _convert_chunked(
        self, convert_fn, file_path: str,
        start: int, end: Optional[int],
    ) -> list:
        """Convert pages in chunks to limit peak memory usage.

        Args:
            convert_fn: ``pdf2image.convert_from_path`` function.
            file_path: Path to the PDF.
            start: First page (1-based).
            end: Last page (1-based) or None for last.

        Returns:
            Combined list of PIL Images.
        """
        chunk = self.chunk_size
        all_images: list = []
        cursor = start
        limit = end if end is not None else 999_999
        while cursor <= limit:
            chunk_end = min(cursor + chunk - 1, limit)
            kwargs = self._build_convert_kwargs(cursor, chunk_end)
            try:
                images = convert_fn(file_path, **kwargs)
            except Exception:
                break  # past the end of the document
            if not images:
                break
            all_images.extend(images)
            cursor = chunk_end + 1
            if len(images) < chunk:
                break  # last chunk was partial → done
        return all_images

    def process_pages(
        self,
        file_path: str,
        start_page: Optional[int] = None,
        end_page: Optional[int] = None,
    ) -> Generator[PageImage, None, None]:
        """Yield page images one at a time to limit memory usage.

        Each yielded PageImage should be closed by the caller when done.

        Args:
            file_path: Path to the PDF file.
            start_page: First page to process (1-based). None = first page.
            end_page: Last page to process (1-based). None = last page.

        Yields:
            PageImage for each page in the range.

        Raises:
            FileNotFoundError: If file does not exist.
            ValueError: If file is invalid or page range is bad.
            RuntimeError: If PDF conversion fails.
        """
        file_path = self.sanitize_path(file_path)
        self.validate_pdf(file_path)
        self._validate_page_range(start_page, end_page)

        try:
            from pdf2image import convert_from_path
            from pdf2image.exceptions import (
                PDFInfoNotInstalledError,
                PDFPageCountError,
                PDFSyntaxError,
            )
        except ImportError:
            raise RuntimeError(
                "pdf2image is not installed. Install it with: pip install pdf2image"
            )

        effective_start = start_page if start_page is not None else 1
        effective_end = end_page

        if self.chunk_size is not None:
            # Stream page-by-page in chunks to limit memory
            cursor = effective_start
            limit = effective_end if effective_end is not None else 999_999
            while cursor <= limit:
                chunk_end = min(cursor + self.chunk_size - 1, limit)
                kwargs = self._build_convert_kwargs(cursor, chunk_end)
                try:
                    images = convert_from_path(file_path, **kwargs)
                except (
                    OSError, ValueError,
                    PDFInfoNotInstalledError, PDFPageCountError, PDFSyntaxError,
                ):
                    break
                if not images:
                    break
                for idx, img in enumerate(images):
                    yield PageImage(
                        page_number=cursor + idx,
                        image=img,
                        width=img.width,
                        height=img.height,
                        dpi=self.dpi,
                    )
                if len(images) < self.chunk_size:
                    break
                cursor = chunk_end + 1
        else:
            try:
                convert_kwargs = self._build_convert_kwargs(start_page, end_page)
                images = convert_from_path(file_path, **convert_kwargs)
            except (
                OSError, ValueError,
                PDFInfoNotInstalledError, PDFPageCountError, PDFSyntaxError,
            ) as e:
                raise RuntimeError(f"Failed to convert PDF to images: {e}")

            for idx, img in enumerate(images):
                page_num = effective_start + idx
                yield PageImage(
                    page_number=page_num,
                    image=img,
                    width=img.width,
                    height=img.height,
                    dpi=self.dpi,
                )

