"""OCR result exporters for multiple output formats.

Supported formats:
  - JSON  (default, via OCRResult.to_json)
  - Plain text with page separators
  - hOCR  (Tesseract-compatible XHTML with bounding boxes)
  - ALTO XML (digitisation standard)
  - Searchable PDF overlay (requires reportlab, plus pypdf/PyPDF2 for PDFs)
"""

import html
import logging
import os
from io import BytesIO

logger = logging.getLogger(__name__)

# Re-usable type references (avoid circular import)
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from .arabic_ocr_service import OCRResult


# ------------------------------------------------------------------
# Plain text
# ------------------------------------------------------------------

def to_plain_text(result: "OCRResult", page_separator: str = "\n--- Page {n} ---\n") -> str:
    """Export OCR result as plain text with page separators.

    Args:
        result: OCRResult to export.
        page_separator: Format string (``{n}`` = page number).

    Returns:
        Plain text string.
    """
    parts: list[str] = []
    for page in result.pages:
        parts.append(page_separator.format(n=page.page_number))
        parts.append(page.text)
    return "\n".join(parts)


# ------------------------------------------------------------------
# hOCR
# ------------------------------------------------------------------

def to_hocr(result: "OCRResult") -> str:
    """Export OCR result as hOCR XHTML.

    hOCR embeds bounding-box and confidence metadata in ``<span>`` elements
    using the ``title`` attribute convention.

    Args:
        result: OCRResult to export.

    Returns:
        hOCR XHTML string.
    """
    lines = [
        '<?xml version="1.0" encoding="UTF-8"?>',
        '<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Transitional//EN"',
        '  "http://www.w3.org/TR/xhtml1/DTD/xhtml1-transitional.dtd">',
        '<html xmlns="http://www.w3.org/1999/xhtml">',
        "<head><title>OCR Output</title></head>",
        "<body>",
    ]
    for page in result.pages:
        bbox = f"0 0 {page.width} {page.height}"
        lines.append(
            f'  <div class="ocr_page" title="bbox {bbox}; ppageno {page.page_number - 1}">'
        )
        for i, region in enumerate(page.text_regions):
            if region.bbox:
                b = region.bbox
                rb = f"{b['x']} {b['y']} {b['x'] + b['width']} {b['y'] + b['height']}"
            else:
                rb = "0 0 0 0"
            conf = int(region.confidence)
            escaped = html.escape(region.text)
            lines.append(
                f'    <span class="ocrx_word" title="bbox {rb}; x_wconf {conf}">'
                f"{escaped}</span>"
            )
        lines.append("  </div>")
    lines.append("</body></html>")
    return "\n".join(lines)


# ------------------------------------------------------------------
# ALTO XML
# ------------------------------------------------------------------

def to_alto_xml(result: "OCRResult") -> str:
    """Export OCR result as ALTO XML v3.

    ALTO (Analyzed Layout and Text Object) is a standard XML schema
    used in digitisation workflows.

    Args:
        result: OCRResult to export.

    Returns:
        ALTO XML string.
    """
    lines = [
        '<?xml version="1.0" encoding="UTF-8"?>',
        '<alto xmlns="http://www.loc.gov/standards/alto/ns-v3#">',
        "  <Layout>",
    ]
    for page in result.pages:
        lines.append(
            f'    <Page ID="page_{page.page_number}" '
            f'WIDTH="{page.width}" HEIGHT="{page.height}">'
        )
        lines.append("      <PrintSpace>")
        for i, region in enumerate(page.text_regions):
            b = region.bbox or {"x": 0, "y": 0, "width": 0, "height": 0}
            conf = region.confidence / 100.0 if region.confidence else 0.0
            escaped = html.escape(region.text)
            lines.append(
                f'        <String ID="w_{page.page_number}_{i}" '
                f'HPOS="{b["x"]}" VPOS="{b["y"]}" '
                f'WIDTH="{b["width"]}" HEIGHT="{b["height"]}" '
                f'WC="{conf:.2f}" CONTENT="{escaped}"/>'
            )
        lines.append("      </PrintSpace>")
        lines.append("    </Page>")
    lines.append("  </Layout>")
    lines.append("</alto>")
    return "\n".join(lines)


# ------------------------------------------------------------------
# Searchable PDF overlay
# ------------------------------------------------------------------

def _get_pdf_backend():
    try:
        from pypdf import PdfReader, PdfWriter

        return PdfReader, PdfWriter
    except ImportError:
        try:
            from PyPDF2 import PdfReader, PdfWriter

            return PdfReader, PdfWriter
        except ImportError as e:
            raise ImportError(
                "PDF searchable export requires pypdf or PyPDF2"
            ) from e


def _draw_invisible_text(canvas_obj, page, page_width: float, page_height: float) -> None:
    """Draw invisible text regions on a reportlab canvas."""
    x_scale = page_width / page.width if page.width else 1.0
    y_scale = page_height / page.height if page.height else 1.0

    for region in page.text_regions:
        if not region.bbox or not region.text.strip():
            continue

        bbox = region.bbox
        x = bbox["x"] * x_scale
        y = page_height - ((bbox["y"] + bbox["height"]) * y_scale)
        font_size = max(1, bbox["height"] * y_scale)

        text_obj = canvas_obj.beginText()
        if hasattr(text_obj, "setTextRenderMode"):
            text_obj.setTextRenderMode(3)
        else:
            canvas_obj.saveState()
            canvas_obj.setFillAlpha(0)
        text_obj.setTextOrigin(x, y)
        text_obj.setFont("Helvetica", font_size)
        text_obj.textLine(region.text)
        canvas_obj.drawText(text_obj)
        if not hasattr(text_obj, "setTextRenderMode"):
            canvas_obj.restoreState()


def _build_overlay_pdf(result: "OCRResult", page_sizes: list[tuple[float, float]]) -> BytesIO:
    from reportlab.lib.pagesizes import letter
    from reportlab.pdfgen import canvas

    buffer = BytesIO()
    pdf = canvas.Canvas(buffer, pagesize=letter)
    for page, (page_width, page_height) in zip(result.pages, page_sizes):
        pdf.setPageSize((page_width, page_height))
        _draw_invisible_text(pdf, page, page_width, page_height)
        pdf.showPage()
    pdf.save()
    buffer.seek(0)
    return buffer


def _write_pdf_source_searchable_pdf(result: "OCRResult", output_path: str) -> str:
    PdfReader, PdfWriter = _get_pdf_backend()

    reader = PdfReader(result.file_path)
    writer = PdfWriter()

    page_sizes: list[tuple[float, float]] = []
    for page in result.pages:
        try:
            source_page = reader.pages[page.page_number - 1]
        except IndexError as e:
            raise ValueError(
                f"Source PDF does not have page {page.page_number}"
            ) from e
        page_sizes.append(
            (
                float(source_page.mediabox.width),
                float(source_page.mediabox.height),
            )
        )

    overlay_reader = PdfReader(_build_overlay_pdf(result, page_sizes))
    for idx, page in enumerate(result.pages):
        source_page = reader.pages[page.page_number - 1]
        source_page.merge_page(overlay_reader.pages[idx])
        writer.add_page(source_page)

    with open(output_path, "wb") as fh:
        writer.write(fh)
    return output_path


def _write_image_source_searchable_pdf(result: "OCRResult", output_path: str) -> str:
    from PIL import Image
    from reportlab.lib.utils import ImageReader
    from reportlab.pdfgen import canvas

    pdf = canvas.Canvas(output_path)
    with Image.open(result.file_path) as source_image:
        total_frames = getattr(source_image, "n_frames", 1)
        for page in result.pages:
            frame_index = page.page_number - 1
            if frame_index >= total_frames:
                raise ValueError(
                    f"Source image does not have frame {page.page_number}"
                )

            source_image.seek(frame_index)
            frame = source_image.copy()
            if frame.mode not in ("RGB", "RGBA"):
                frame = frame.convert("RGB")

            page_width = page.width or frame.width
            page_height = page.height or frame.height
            pdf.setPageSize((page_width, page_height))
            pdf.drawImage(
                ImageReader(frame),
                0,
                0,
                width=page_width,
                height=page_height,
            )
            _draw_invisible_text(pdf, page, page_width, page_height)
            pdf.showPage()

    pdf.save()
    return output_path


def to_searchable_pdf(result: "OCRResult", output_path: str) -> str:
    """Create a searchable PDF by overlaying invisible OCR text.

    Preserves the original source content by merging an invisible OCR-text
    overlay onto the source PDF, or by embedding the source image/TIFF frame
    behind the text layer. PDF sources also require ``pypdf`` or ``PyPDF2``.

    Args:
        result: OCRResult to export.
        output_path: Destination file path for the PDF.

    Returns:
        The output_path on success.

    Raises:
        ImportError: If reportlab or the PDF merge backend is not installed.
        ValueError: If the source file is missing or does not match the OCR result.
    """
    if not result.file_path or not os.path.exists(result.file_path):
        raise ValueError(
            "Searchable PDF export requires result.file_path to point to the "
            "original source document"
        )

    ext = os.path.splitext(result.file_path)[1].lower()
    if ext == ".pdf":
        return _write_pdf_source_searchable_pdf(result, output_path)
    return _write_image_source_searchable_pdf(result, output_path)
