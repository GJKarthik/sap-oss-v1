"""CLI entry point for the Arabic OCR module.

Usage:
    python -m intelligence.ocr <input> [options]

Examples:
    # Process a single PDF
    python -m intelligence.ocr document.pdf --output result.json

    # Process all PDFs in a directory
    python -m intelligence.ocr input_dir/ --output-dir results/ --format text

    # Process a single image
    python -m intelligence.ocr scan.png --format hocr
"""

import argparse
import glob
import json
import os
import sys
import time

from .arabic_ocr_service import ArabicOCRService
from .exporters import to_alto_xml, to_hocr, to_plain_text


def _build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="python -m intelligence.ocr",
        description="Arabic/English OCR processing for PDFs and images.",
    )
    p.add_argument("input", help="PDF file, image file, or directory of PDFs")
    p.add_argument("--output", "-o", help="Output file path (single-file mode)")
    p.add_argument(
        "--output-dir", help="Output directory (batch mode, one result per input)"
    )
    p.add_argument(
        "--format",
        choices=["json", "text", "hocr", "alto"],
        default="json",
        help="Output format (default: json)",
    )
    p.add_argument("--languages", default="ara+eng", help="Tesseract language string")
    p.add_argument("--dpi", type=int, default=300, help="DPI for PDF conversion")
    p.add_argument("--workers", type=int, default=1, help="Parallel page workers")
    p.add_argument("--no-tables", action="store_true", help="Disable table detection")
    p.add_argument("--start-page", type=int, default=None)
    p.add_argument("--end-page", type=int, default=None)
    p.add_argument("--quiet", "-q", action="store_true", help="Suppress progress output")
    p.add_argument(
        "--config", "-c",
        help="Path to YAML/TOML config file (overrides other CLI options)",
    )
    return p


def _export(result, fmt: str) -> str:
    """Convert OCRResult to the requested format string."""
    if fmt == "json":
        return result.to_json()
    elif fmt == "text":
        return to_plain_text(result)
    elif fmt == "hocr":
        return to_hocr(result)
    elif fmt == "alto":
        return to_alto_xml(result)
    return result.to_json()


def _extension(fmt: str) -> str:
    return {"json": ".json", "text": ".txt", "hocr": ".hocr", "alto": ".xml"}[fmt]


def main() -> None:
    parser = _build_parser()
    args = parser.parse_args()

    if args.config:
        from .config import load_config, service_from_config

        cfg = load_config(args.config)
        service = service_from_config(cfg)
    else:
        service = ArabicOCRService(
            languages=args.languages,
            dpi=args.dpi,
            max_workers=args.workers,
        )
    detect_tables = not args.no_tables

    # Collect input files
    _SUPPORTED_EXT = {".pdf", ".png", ".jpg", ".jpeg", ".tiff", ".tif", ".bmp"}

    if os.path.isdir(args.input):
        # Batch mode — collect all supported files
        files = []
        for ext in _SUPPORTED_EXT:
            files.extend(glob.glob(os.path.join(args.input, f"*{ext}")))
        files = sorted(files)
        if not files:
            print(f"No supported files found in {args.input}", file=sys.stderr)
            sys.exit(1)
    elif os.path.isfile(args.input):
        files = [args.input]
    else:
        print(f"Input not found: {args.input}", file=sys.stderr)
        sys.exit(1)

    if args.output and args.output_dir:
        parser.error("--output and --output-dir cannot be used together")
    if args.output and len(files) > 1:
        parser.error(
            "--output can only be used with a single input file; "
            "use --output-dir for batch mode"
        )

    if args.output_dir:
        os.makedirs(args.output_dir, exist_ok=True)

    for filepath in files:
        if not args.quiet:
            print(f"Processing: {filepath} ...", end=" ", flush=True)

        t0 = time.monotonic()

        ext = os.path.splitext(filepath)[1].lower()

        if ext == ".pdf":
            result = service.process_pdf(
                filepath, args.start_page, args.end_page, detect_tables
            )
        elif ext in (".tiff", ".tif"):
            result = service.process_tiff(filepath, detect_tables)
        else:
            from PIL import Image

            with Image.open(filepath) as img:
                page_result = service.process_image(img, detect_tables)
            from .arabic_ocr_service import OCRResult

            result = OCRResult(
                file_path=filepath,
                total_pages=1,
                pages=[page_result],
                overall_confidence=page_result.confidence,
            )

        elapsed = time.monotonic() - t0
        output_str = _export(result, args.format)

        # Write output
        if args.output:
            with open(args.output, "w", encoding="utf-8") as f:
                f.write(output_str)
        elif args.output_dir:
            base = os.path.splitext(os.path.basename(filepath))[0]
            out_path = os.path.join(args.output_dir, base + _extension(args.format))
            with open(out_path, "w", encoding="utf-8") as f:
                f.write(output_str)
        else:
            print(output_str)

        if not args.quiet:
            pages = len(result.pages)
            conf = result.overall_confidence
            print(f"done ({pages} pages, conf={conf:.1f}%, {elapsed:.1f}s)")


if __name__ == "__main__":
    main()
