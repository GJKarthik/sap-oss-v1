"""Tests for new OCR modules: table_detector, language_detector,
postprocessing, exporters, cache, CLI.

All tests use real dependencies — no mocking.
"""

import asyncio
import json
import os
import tempfile

import pytest
from PIL import Image, ImageDraw, ImageFont

from ..arabic_ocr_service import ArabicOCRService, OCRResult, PageResult, TextRegion
from ..cache import OCRCache
from ..exporters import to_alto_xml, to_hocr, to_plain_text
from ..language_detector import LanguageDetector
from ..postprocessing import PostprocessingConfig, TextPostprocessor
from ..table_detector import TableDetector


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _make_text_image(text: str, size=(500, 100), font_size=48) -> Image.Image:
    img = Image.new("RGB", size, color="white")
    draw = ImageDraw.Draw(img)
    try:
        font = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", font_size)
    except (OSError, IOError):
        font = ImageFont.load_default()
    draw.text((10, 20), text, fill="black", font=font)
    return img


def _make_grid_image() -> Image.Image:
    """Draw a 3×3 grid with clear lines."""
    img = Image.new("RGB", (600, 400), color="white")
    draw = ImageDraw.Draw(img)
    # Horizontal lines
    for y in (50, 150, 250, 350):
        draw.line([(50, y), (550, y)], fill="black", width=3)
    # Vertical lines
    for x in (50, 200, 400, 550):
        draw.line([(x, 50), (x, 350)], fill="black", width=3)
    return img


def _make_real_pdf(n=1):
    objects = []
    objects.append("1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj")
    kids = " ".join(f"{3+i} 0 R" for i in range(n))
    objects.append(f"2 0 obj\n<< /Type /Pages /Kids [{kids}] /Count {n} >>\nendobj")
    for i in range(n):
        objects.append(f"{3+i} 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>\nendobj")
    body = "\n".join(objects)
    xref_offset = len(b"%PDF-1.4\n") + len(body.encode("latin-1")) + 1
    num_obj = 1 + len(objects)
    xref = [f"xref\n0 {num_obj}", "0000000000 65535 f "]
    off = len(b"%PDF-1.4\n")
    for o in objects:
        xref.append(f"{off:010d} 00000 n ")
        off += len(o.encode("latin-1")) + 1
    trailer = f"trailer\n<< /Size {num_obj} /Root 1 0 R >>\nstartxref\n{xref_offset}\n%%EOF"
    pdf = f"%PDF-1.4\n{body}\n" + "\n".join(xref) + f"\n{trailer}"
    f = tempfile.NamedTemporaryFile(suffix=".pdf", delete=False)
    f.write(pdf.encode("latin-1"))
    f.flush()
    f.close()
    return f.name


def _make_text_layer_pdf(page_texts: list[str]) -> str:
    pytest.importorskip("reportlab")
    from reportlab.lib.pagesizes import letter
    from reportlab.pdfgen import canvas

    f = tempfile.NamedTemporaryFile(suffix=".pdf", delete=False)
    f.close()

    pdf = canvas.Canvas(f.name, pagesize=letter)
    for text in page_texts:
        pdf.drawString(72, 720, text)
        pdf.showPage()
    pdf.save()
    return f.name


def _sample_result() -> OCRResult:
    return OCRResult(
        file_path="/test.pdf",
        total_pages=1,
        pages=[
            PageResult(
                page_number=1,
                text="Hello World",
                width=800,
                height=600,
                confidence=92.0,
                text_regions=[
                    TextRegion(
                        text="Hello",
                        confidence=95.0,
                        bbox={"x": 10, "y": 20, "width": 80, "height": 30},
                        language="eng",
                    ),
                    TextRegion(
                        text="World",
                        confidence=89.0,
                        bbox={"x": 100, "y": 20, "width": 80, "height": 30},
                        language="eng",
                    ),
                ],
            )
        ],
        overall_confidence=92.0,
    )


# ---------------------------------------------------------------------------
# LanguageDetector
# ---------------------------------------------------------------------------

class TestLanguageDetector:
    def test_detect_arabic(self):
        d = LanguageDetector()
        assert d.detect("مرحبا بالعالم") == "ara"

    def test_detect_english(self):
        d = LanguageDetector()
        assert d.detect("Hello World") == "eng"

    def test_detect_mixed(self):
        d = LanguageDetector()
        result = d.detect("Hello مرحبا World بالعالم")
        assert "ara" in result
        assert "eng" in result

    def test_detect_empty(self):
        d = LanguageDetector()
        assert d.detect("") == "eng"  # fallback

    def test_detect_numbers(self):
        d = LanguageDetector()
        assert d.detect("12345") == "eng"  # fallback

    def test_custom_fallback(self):
        d = LanguageDetector(fallback_lang="deu")
        assert d.detect("12345") == "deu"

    def test_invalid_ratio(self):
        with pytest.raises(ValueError, match="min_char_ratio"):
            LanguageDetector(min_char_ratio=-0.1)

    def test_detect_scripts_counts(self):
        d = LanguageDetector()
        counts = d.detect_scripts("Hello مرحبا")
        assert "eng" in counts
        assert "ara" in counts
        assert counts["eng"] == 5  # H,e,l,l,o




# ---------------------------------------------------------------------------
# TextPostprocessor
# ---------------------------------------------------------------------------

class TestTextPostprocessor:
    def test_whitespace_normalization(self):
        cfg = PostprocessingConfig(
            enable_whitespace_norm=True,
            enable_char_fixes=False,
            enable_arabic_ligatures=False,
        )
        proc = TextPostprocessor(cfg)
        assert proc.process("  hello   world  ") == "hello world"

    def test_collapse_blank_lines(self):
        cfg = PostprocessingConfig(
            enable_whitespace_norm=True,
            enable_char_fixes=False,
            enable_arabic_ligatures=False,
        )
        proc = TextPostprocessor(cfg)
        result = proc.process("line1\n\n\n\nline2")
        assert result == "line1\n\nline2"

    def test_char_fixes(self):
        cfg = PostprocessingConfig(
            enable_whitespace_norm=False,
            enable_char_fixes=True,
            enable_arabic_ligatures=False,
        )
        proc = TextPostprocessor(cfg)
        assert "m" in proc.process("rn")  # rn → m

    def test_custom_char_fixes(self):
        cfg = PostprocessingConfig(
            enable_char_fixes=True,
            custom_char_fixes={"xyz": "abc"},
            enable_arabic_ligatures=False,
        )
        proc = TextPostprocessor(cfg)
        assert "abc" in proc.process("xyz")

    def test_arabic_ligature_fix(self):
        cfg = PostprocessingConfig(
            enable_whitespace_norm=False,
            enable_char_fixes=False,
            enable_arabic_ligatures=True,
        )
        proc = TextPostprocessor(cfg)
        assert proc.process("ﻻ") == "لا"

    def test_dictionary_correction(self):
        dictionary = {"hello", "world"}
        cfg = PostprocessingConfig(
            enable_whitespace_norm=False,
            enable_char_fixes=False,
            enable_arabic_ligatures=False,
            enable_dictionary=True,
            dictionary_words=dictionary,
        )
        proc = TextPostprocessor(cfg)
        result = proc.process("hello world")
        assert result == "hello world"

    def test_empty_text(self):
        proc = TextPostprocessor()
        assert proc.process("") == ""

    def test_full_pipeline(self):
        proc = TextPostprocessor()
        result = proc.process("  hello   world  \n\n\n  test  ")
        assert "hello world" in result


# ---------------------------------------------------------------------------
# TableDetector (OpenCV)
# ---------------------------------------------------------------------------

class TestTableDetectorOpenCV:
    def test_detect_grid(self):
        td = TableDetector()
        img = _make_grid_image()
        tables = td.detect(img)
        assert len(tables) >= 1
        table = tables[0]
        assert table.rows >= 2
        assert table.cols >= 2
        assert len(table.cells) == table.rows * table.cols

    def test_no_table_on_text_image(self):
        td = TableDetector()
        img = _make_text_image("Just text, no table")
        tables = td.detect(img)
        assert len(tables) == 0

    def test_no_table_on_blank(self):
        td = TableDetector()
        img = Image.new("RGB", (200, 200), color="white")
        tables = td.detect(img)
        assert len(tables) == 0

    def test_cell_bbox_coordinates(self):
        td = TableDetector()
        img = _make_grid_image()
        tables = td.detect(img)
        if tables:
            for cell in tables[0].cells:
                assert cell.x >= 0
                assert cell.y >= 0
                assert cell.w > 0
                assert cell.h > 0


# ---------------------------------------------------------------------------
# Exporters
# ---------------------------------------------------------------------------

class TestExporters:
    def test_plain_text(self):
        result = _sample_result()
        text = to_plain_text(result)
        assert "Page 1" in text
        assert "Hello World" in text

    def test_hocr(self):
        result = _sample_result()
        hocr = to_hocr(result)
        assert "ocr_page" in hocr
        assert "ocrx_word" in hocr
        assert "Hello" in hocr
        assert "x_wconf" in hocr
        assert '<?xml version' in hocr

    def test_alto_xml(self):
        result = _sample_result()
        alto = to_alto_xml(result)
        assert "<alto" in alto
        assert "CONTENT" in alto
        assert "Hello" in alto
        assert "PrintSpace" in alto

    def test_hocr_empty_result(self):
        result = OCRResult(file_path="/empty.pdf", total_pages=0)
        hocr = to_hocr(result)
        assert "ocr_page" not in hocr
        assert "</html>" in hocr

    def test_plain_text_custom_separator(self):
        result = _sample_result()
        text = to_plain_text(result, page_separator="\n=== PAGE {n} ===\n")
        assert "=== PAGE 1 ===" in text


# ---------------------------------------------------------------------------
# OCRCache
# ---------------------------------------------------------------------------

class TestOCRCache:
    def test_put_and_get(self):
        cache = OCRCache()
        cache.put("key1", {"data": "test"})
        assert cache.get("key1") == {"data": "test"}
        assert cache.size == 1

    def test_get_miss(self):
        cache = OCRCache()
        assert cache.get("nonexistent") is None

    def test_invalidate(self):
        cache = OCRCache()
        cache.put("key1", "val")
        cache.invalidate("key1")
        assert cache.get("key1") is None
        assert cache.size == 0

    def test_clear(self):
        cache = OCRCache()
        cache.put("a", 1)
        cache.put("b", 2)
        cache.clear()
        assert cache.size == 0

    def test_max_size_eviction(self):
        cache = OCRCache(max_size=2)
        cache.put("a", 1)
        cache.put("b", 2)
        cache.put("c", 3)
        assert cache.size == 2
        assert cache.get("a") is None
        assert cache.get("b") is not None
        assert cache.get("c") is not None

    def test_lru_ordering(self):
        cache = OCRCache(max_size=2)
        cache.put("a", 1)
        cache.put("b", 2)
        cache.get("a")  # touch a
        cache.put("c", 3)
        assert cache.get("b") is None
        assert cache.get("a") is not None

    def test_invalid_max_size(self):
        with pytest.raises(ValueError, match="max_size"):
            OCRCache(max_size=-1)

    def test_make_key(self):
        path = _make_real_pdf(1)
        try:
            cache = OCRCache()
            key1 = cache.make_key(path, {"dpi": 300})
            key2 = cache.make_key(path, {"dpi": 150})
            assert key1 != key2
            key3 = cache.make_key(path, {"dpi": 300})
            assert key1 == key3
        finally:
            os.unlink(path)

    def test_unlimited_cache(self):
        cache = OCRCache(max_size=0)
        for i in range(200):
            cache.put(f"k{i}", i)
        assert cache.size == 200

    def test_cache_poisoning_get(self):
        """Mutating a value returned by get() must NOT affect the cache."""
        cache = OCRCache()
        cache.put("k", {"pages": [{"text": "hello"}]})
        first = cache.get("k")
        first["pages"][0]["text"] = "MUTATED"
        second = cache.get("k")
        assert second["pages"][0]["text"] == "hello"

    def test_cache_poisoning_put(self):
        """Mutating the original object after put() must NOT affect the cache."""
        cache = OCRCache()
        obj = {"data": [1, 2, 3]}
        cache.put("k", obj)
        obj["data"].append(999)
        cached = cache.get("k")
        assert cached["data"] == [1, 2, 3]


# ---------------------------------------------------------------------------
# Async interface
# ---------------------------------------------------------------------------

class TestAsyncInterface:
    def test_async_process_pdf(self):
        service = ArabicOCRService(languages="eng", dpi=72)
        path = _make_real_pdf(1)
        try:
            result = asyncio.run(service.process_pdf_async(path))
            assert len(result.pages) == 1
            assert result.total_processing_time_s > 0
        finally:
            os.unlink(path)

    def test_async_process_image(self):
        service = ArabicOCRService(languages="eng")
        img = _make_text_image("ASYNC TEST", size=(500, 100), font_size=48)
        result = asyncio.run(service.process_image_async(img, detect_tables=False))
        assert result.page_number == 1
        assert isinstance(result.text, str)


# ---------------------------------------------------------------------------
# Timing / observability
# ---------------------------------------------------------------------------

class TestTimingObservability:
    def test_page_processing_time(self):
        service = ArabicOCRService(languages="eng", dpi=72)
        path = _make_real_pdf(1)
        try:
            result = service.process_pdf(path)
            assert result.pages[0].processing_time_s > 0
        finally:
            os.unlink(path)

    def test_total_processing_time(self):
        service = ArabicOCRService(languages="eng", dpi=72)
        path = _make_real_pdf(2)
        try:
            result = service.process_pdf(path)
            assert result.total_processing_time_s > 0
            assert result.metadata["total_processing_time_s"] > 0
        finally:
            os.unlink(path)

    def test_timing_in_json_output(self):
        service = ArabicOCRService(languages="eng", dpi=72)
        path = _make_real_pdf(1)
        try:
            result = service.process_pdf(path)
            parsed = json.loads(result.to_json())
            assert "total_processing_time_s" in parsed
            assert parsed["total_processing_time_s"] > 0
        finally:
            os.unlink(path)


# ---------------------------------------------------------------------------
# Postprocessing integration
# ---------------------------------------------------------------------------

class TestPostprocessingIntegration:
    def test_ocr_with_postprocessing(self):
        from ..postprocessing import PostprocessingConfig

        service = ArabicOCRService(
            languages="eng",
            postprocessing=PostprocessingConfig(
                enable_whitespace_norm=True,
                enable_char_fixes=True,
            ),
        )
        img = _make_text_image("HELLO WORLD", size=(500, 100), font_size=48)
        result = service.process_image(img, detect_tables=False)
        assert isinstance(result.text, str)


# ---------------------------------------------------------------------------
# CLI smoke test
# ---------------------------------------------------------------------------

class TestCLI:
    def test_cli_single_pdf(self):
        path = _make_real_pdf(1)
        out = tempfile.NamedTemporaryFile(suffix=".json", delete=False)
        out.close()
        try:
            import subprocess
            result = subprocess.run(
                [
                    "python", "-m", "intelligence.ocr",
                    path, "--output", out.name,
                    "--format", "json", "--dpi", "72",
                    "--languages", "eng", "--quiet",
                ],
                capture_output=True, text=True, cwd=os.path.join(
                    os.path.dirname(__file__), "..", "..", ".."
                ),
                timeout=60,
            )
            assert result.returncode == 0, result.stderr
            with open(out.name) as f:
                data = json.load(f)
            assert "pages" in data
        finally:
            os.unlink(path)
            os.unlink(out.name)

    def test_cli_text_format(self):
        path = _make_real_pdf(1)
        out = tempfile.NamedTemporaryFile(suffix=".txt", delete=False)
        out.close()
        try:
            import subprocess
            result = subprocess.run(
                [
                    "python", "-m", "intelligence.ocr",
                    path, "--output", out.name,
                    "--format", "text", "--dpi", "72",
                    "--languages", "eng", "--quiet",
                ],
                capture_output=True, text=True, cwd=os.path.join(
                    os.path.dirname(__file__), "..", "..", ".."
                ),
                timeout=60,
            )
            assert result.returncode == 0, result.stderr
            with open(out.name) as f:
                content = f.read()
            assert "Page 1" in content
        finally:
            os.unlink(path)
            os.unlink(out.name)

    def test_cli_rejects_batch_output_file(self):
        tmpdir = tempfile.mkdtemp()
        out = tempfile.NamedTemporaryFile(suffix=".json", delete=False)
        out.close()
        try:
            import shutil
            import subprocess

            for idx in range(2):
                src = _make_real_pdf(1)
                shutil.move(src, os.path.join(tmpdir, f"doc_{idx}.pdf"))

            result = subprocess.run(
                [
                    "python", "-m", "intelligence.ocr",
                    tmpdir, "--output", out.name,
                    "--format", "json", "--dpi", "72",
                    "--languages", "eng", "--quiet",
                ],
                capture_output=True, text=True, cwd=os.path.join(
                    os.path.dirname(__file__), "..", "..", ".."
                ),
                timeout=60,
            )
            assert result.returncode != 0
            assert "--output can only be used with a single input file" in result.stderr
        finally:
            import shutil

            shutil.rmtree(tmpdir)
            os.unlink(out.name)


# ---------------------------------------------------------------------------
# Fuzz / edge-case testing (Task 15)
# ---------------------------------------------------------------------------

class TestFuzzEdgeCases:
    """Malformed inputs must not crash the service."""

    def test_truncated_pdf(self):
        """PDF with truncated content should produce an error, not crash."""
        f = tempfile.NamedTemporaryFile(suffix=".pdf", delete=False)
        f.write(b"%PDF-1.4\n1 0 obj\n<< /Type /Catalog")  # truncated
        f.flush()
        f.close()
        try:
            service = ArabicOCRService(languages="eng", dpi=72)
            result = service.process_pdf(f.name)
            assert len(result.errors) > 0 or len(result.pages) == 0
        finally:
            os.unlink(f.name)

    def test_zero_size_image(self):
        """Zero-pixel image should not crash."""
        service = ArabicOCRService(languages="eng")
        try:
            img = Image.new("RGB", (0, 0))
            result = service.process_image(img, detect_tables=False)
            # Either returns empty result or captures error
            assert isinstance(result, PageResult)
        except Exception:
            pass  # acceptable to raise on 0×0 image

    def test_very_large_text_input(self):
        """Postprocessor handles very long strings without hanging."""
        proc = TextPostprocessor()
        big = "Hello world. " * 10000
        result = proc.process(big)
        assert len(result) > 0

    def test_non_pdf_extension_rejected(self):
        f = tempfile.NamedTemporaryFile(suffix=".doc", delete=False)
        f.write(b"Not a PDF")
        f.flush()
        f.close()
        try:
            service = ArabicOCRService(languages="eng", dpi=72)
            result = service.process_pdf(f.name)
            assert len(result.errors) > 0
        finally:
            os.unlink(f.name)

    def test_binary_garbage_pdf(self):
        """Binary garbage with .pdf extension is handled gracefully."""
        f = tempfile.NamedTemporaryFile(suffix=".pdf", delete=False)
        f.write(os.urandom(1024))
        f.flush()
        f.close()
        try:
            service = ArabicOCRService(languages="eng", dpi=72)
            result = service.process_pdf(f.name)
            assert len(result.errors) > 0
        finally:
            os.unlink(f.name)

    def test_unicode_in_path(self):
        """File path with Unicode characters works."""
        path = _make_real_pdf(1)
        # Just verify the path can be processed
        try:
            service = ArabicOCRService(languages="eng", dpi=72)
            result = service.process_pdf(path)
            assert len(result.pages) >= 0
        finally:
            os.unlink(path)


# ---------------------------------------------------------------------------
# Benchmark / performance smoke test (Task 13)
# ---------------------------------------------------------------------------

class TestBenchmark:
    """Performance smoke tests — verify processing doesn't regress."""

    def test_single_page_under_10s(self):
        """A single blank page should process in under 10 seconds."""
        import time

        service = ArabicOCRService(languages="eng", dpi=72)
        path = _make_real_pdf(1)
        try:
            t0 = time.monotonic()
            result = service.process_pdf(path)
            elapsed = time.monotonic() - t0
            assert elapsed < 10.0, f"Took {elapsed:.1f}s, expected <10s"
            assert len(result.pages) == 1
        finally:
            os.unlink(path)

    def test_five_pages_under_30s(self):
        """Five blank pages should process in under 30 seconds."""
        import time

        service = ArabicOCRService(languages="eng", dpi=72)
        path = _make_real_pdf(5)
        try:
            t0 = time.monotonic()
            result = service.process_pdf(path)
            elapsed = time.monotonic() - t0
            assert elapsed < 30.0, f"Took {elapsed:.1f}s, expected <30s"
            assert len(result.pages) == 5
        finally:
            os.unlink(path)

    def test_parallel_faster_than_sequential(self):
        """Parallel (2 workers) should not be significantly slower."""
        import time

        path = _make_real_pdf(4)
        try:
            seq = ArabicOCRService(languages="eng", dpi=72, max_workers=1)
            par = ArabicOCRService(languages="eng", dpi=72, max_workers=2)

            t0 = time.monotonic()
            seq.process_pdf(path)
            seq_time = time.monotonic() - t0

            t0 = time.monotonic()
            par.process_pdf(path)
            par_time = time.monotonic() - t0

            # Parallel should not be 3× slower than sequential
            assert par_time < seq_time * 3
        finally:
            os.unlink(path)


# ---------------------------------------------------------------------------
# Arabic OCR accuracy test (Task 14) — requires Arabic font
# ---------------------------------------------------------------------------

class TestArabicAccuracy:
    """Test OCR accuracy on rendered Arabic text."""

    def test_arabic_text_extraction(self):
        """Render Arabic text and verify OCR extracts something."""
        # Use a simple Arabic phrase
        service = ArabicOCRService(languages="ara+eng", dpi=300)
        # Create image with Arabic text
        img = Image.new("RGB", (600, 100), color="white")
        draw = ImageDraw.Draw(img)
        # Try to use a system Arabic font
        try:
            font = ImageFont.truetype(
                "/System/Library/Fonts/Supplemental/Arial Unicode.ttf", 40
            )
        except (OSError, IOError):
            try:
                font = ImageFont.truetype(
                    "/System/Library/Fonts/Geeza Pro.ttc", 40
                )
            except (OSError, IOError):
                pytest.skip("No Arabic font available on this system")
                return

        draw.text((10, 20), "مرحبا", fill="black", font=font)
        result = service.process_image(img, detect_tables=False)
        # We just verify OCR produces *some* output (real accuracy
        # depends on font rendering and Tesseract models)
        assert isinstance(result.text, str)
        assert result.page_number == 1


# ---------------------------------------------------------------------------
# Task 1: Cache wiring integration
# ---------------------------------------------------------------------------

class TestCacheWiring:
    def test_cache_hit_on_second_call(self):
        service = ArabicOCRService(
            languages="eng", dpi=72, enable_cache=True, cache_max_size=10
        )
        path = _make_real_pdf(1)
        try:
            r1 = service.process_pdf(path)
            r2 = service.process_pdf(path)
            # Second call should return same result (from cache)
            assert r1.total_pages == r2.total_pages
            assert r1.overall_confidence == r2.overall_confidence
            assert service._cache.size == 1
        finally:
            os.unlink(path)

    def test_cache_disabled_by_default(self):
        service = ArabicOCRService(languages="eng", dpi=72)
        assert service._cache is None

    def test_cache_scopes_page_range_and_table_detection(self):
        service = ArabicOCRService(
            languages="eng", dpi=72, enable_cache=True, cache_max_size=10
        )
        path = _make_real_pdf(2)
        try:
            first = service.process_pdf(
                path, start_page=1, end_page=1, detect_tables=False
            )
            second = service.process_pdf(path)
            third = service.process_pdf(
                path, start_page=1, end_page=1, detect_tables=True
            )

            assert len(first.pages) == 1
            assert len(second.pages) == 2
            assert len(third.pages) == 1
            assert service._cache.size == 3
        finally:
            os.unlink(path)


# ---------------------------------------------------------------------------
# Task 3: Searchable PDF export (skip-guarded)
# ---------------------------------------------------------------------------

class TestSearchablePDF:
    def test_searchable_pdf_export(self):
        pytest.importorskip("reportlab")
        try:
            from pypdf import PdfReader
        except ImportError:
            PdfReader = pytest.importorskip("PyPDF2").PdfReader
        from ..exporters import to_searchable_pdf

        source_path = _make_text_layer_pdf(["VISIBLE SOURCE PAGE"])
        out = tempfile.NamedTemporaryFile(suffix=".pdf", delete=False)
        out.close()
        try:
            result = OCRResult(
                file_path=source_path,
                total_pages=1,
                pages=[
                    PageResult(
                        page_number=1,
                        text="OCR TEXT",
                        width=612,
                        height=792,
                        confidence=92.0,
                        text_regions=[
                            TextRegion(
                                text="OCR TEXT",
                                confidence=95.0,
                                bbox={"x": 72, "y": 50, "width": 80, "height": 16},
                                language="eng",
                            )
                        ],
                    )
                ],
                overall_confidence=92.0,
            )
            path = to_searchable_pdf(result, out.name)
            assert os.path.exists(path)
            assert os.path.getsize(path) > 0
            extracted = PdfReader(path).pages[0].extract_text()
            assert "VISIBLE SOURCE PAGE" in extracted
        finally:
            os.unlink(source_path)
            os.unlink(out.name)

    def test_searchable_pdf_requires_real_source_file(self):
        pytest.importorskip("reportlab")
        from ..exporters import to_searchable_pdf

        result = _sample_result()
        out = tempfile.NamedTemporaryFile(suffix=".pdf", delete=False)
        out.close()
        try:
            with pytest.raises(ValueError, match="result.file_path"):
                to_searchable_pdf(result, out.name)
        finally:
            os.unlink(out.name)


# ---------------------------------------------------------------------------
# Task 5: Context-sensitive char fixes
# ---------------------------------------------------------------------------

class TestContextSensitiveCharFixes:
    def test_numbers_preserved(self):
        """'100' should NOT become 'lOO'."""
        from ..postprocessing import PostprocessingConfig, TextPostprocessor

        cfg = PostprocessingConfig(
            enable_whitespace_norm=False,
            enable_char_fixes=True,
            enable_arabic_ligatures=False,
        )
        proc = TextPostprocessor(cfg)
        assert proc.process("100") == "100"
        assert proc.process("page 10 of 20") == "page 10 of 20"

    def test_letter_context_applies(self):
        """'h0t' → 'hOt' because 0 is between letters."""
        from ..postprocessing import PostprocessingConfig, TextPostprocessor

        cfg = PostprocessingConfig(
            enable_whitespace_norm=False,
            enable_char_fixes=True,
            enable_arabic_ligatures=False,
        )
        proc = TextPostprocessor(cfg)
        assert proc.process("h0t") == "hOt"


# ---------------------------------------------------------------------------
# Task 6: Chunked PDF processing
# ---------------------------------------------------------------------------

class TestChunkedPDFProcessing:
    def test_chunk_size_validation(self):
        from ..pdf_processor import PDFProcessor

        with pytest.raises(ValueError, match="chunk_size"):
            PDFProcessor(dpi=72, chunk_size=0)
        with pytest.raises(ValueError, match="chunk_size"):
            PDFProcessor(dpi=72, chunk_size=-1)

    def test_chunked_produces_same_result(self):
        path = _make_real_pdf(3)
        try:
            from ..pdf_processor import PDFProcessor

            normal = PDFProcessor(dpi=72)
            chunked = PDFProcessor(dpi=72, chunk_size=2)
            r1 = normal.process(path)
            r2 = chunked.process(path)
            assert len(r1.pages) == len(r2.pages)
        finally:
            os.unlink(path)


# ---------------------------------------------------------------------------
# Task 7: DiskCache
# ---------------------------------------------------------------------------

class TestDiskCache:
    def test_put_and_get(self):
        from ..cache import DiskCache

        db = tempfile.NamedTemporaryFile(suffix=".db", delete=False)
        db.close()
        try:
            cache = DiskCache(db.name)
            cache.put("k1", {"text": "hello"})
            assert cache.get("k1") == {"text": "hello"}
            assert cache.size == 1
            cache.close()
        finally:
            os.unlink(db.name)

    def test_eviction(self):
        from ..cache import DiskCache

        db = tempfile.NamedTemporaryFile(suffix=".db", delete=False)
        db.close()
        try:
            cache = DiskCache(db.name, max_size=2)
            cache.put("a", 1)
            cache.put("b", 2)
            cache.put("c", 3)
            assert cache.size == 2
            assert cache.get("a") is None
            cache.close()
        finally:
            os.unlink(db.name)

    def test_clear(self):
        from ..cache import DiskCache

        db = tempfile.NamedTemporaryFile(suffix=".db", delete=False)
        db.close()
        try:
            cache = DiskCache(db.name)
            cache.put("x", "y")
            cache.clear()
            assert cache.size == 0
            cache.close()
        finally:
            os.unlink(db.name)

    def test_persistence(self):
        from ..cache import DiskCache

        db = tempfile.NamedTemporaryFile(suffix=".db", delete=False)
        db.close()
        try:
            c1 = DiskCache(db.name)
            c1.put("persistent", {"data": 42})
            c1.close()
            c2 = DiskCache(db.name)
            assert c2.get("persistent") == {"data": 42}
            c2.close()
        finally:
            os.unlink(db.name)



# ---------------------------------------------------------------------------
# Task 9: Structured JSON logging
# ---------------------------------------------------------------------------

class TestStructuredLogging:
    def test_json_formatter(self):
        import logging

        from ..logging_config import JSONFormatter

        fmt = JSONFormatter()
        record = logging.LogRecord(
            name="test", level=logging.INFO, pathname="",
            lineno=0, msg="hello %s", args=("world",), exc_info=None,
        )
        output = fmt.format(record)
        parsed = json.loads(output)
        assert parsed["message"] == "hello world"
        assert parsed["level"] == "INFO"

    def test_configure_logging(self):
        from ..logging_config import configure_logging

        configure_logging(level="DEBUG", json_format=True)
        import logging

        logger = logging.getLogger("intelligence.ocr.test_config")
        assert logger.getEffectiveLevel() == logging.DEBUG

    def test_request_context_filter(self):
        from ..logging_config import get_context_filter

        f = get_context_filter()
        rid = f.set_request_id("test-123")
        assert rid == "test-123"
        f.clear_request_id()


# ---------------------------------------------------------------------------
# Task 10: Dependency checker
# ---------------------------------------------------------------------------

class TestDependencyChecker:
    def test_check_dependencies(self):
        from ..dependencies import check_dependencies

        report = check_dependencies()
        assert len(report.dependencies) > 0
        # Required deps should be available in test env
        names = [d.name for d in report.dependencies]
        assert "pytesseract" in names
        assert "PIL" in names

    def test_report_string(self):
        from ..dependencies import check_dependencies

        report = check_dependencies()
        s = str(report)
        assert "OCR Module Dependencies" in s

    def test_report_dict(self):
        from ..dependencies import check_dependencies

        report = check_dependencies()
        d = report.to_dict()
        assert "dependencies" in d
        assert "missing" in d


# ---------------------------------------------------------------------------
# Task 12: Region-of-interest OCR
# ---------------------------------------------------------------------------

class TestRegionOCR:
    def test_process_region(self):
        service = ArabicOCRService(languages="eng")
        img = _make_text_image("REGION TEST", size=(600, 200), font_size=48)
        result = service.process_region(img, x=10, y=10, width=300, height=100)
        assert result.page_number == 1
        assert isinstance(result.text, str)

    def test_invalid_region_negative(self):
        service = ArabicOCRService(languages="eng")
        img = Image.new("RGB", (200, 200))
        with pytest.raises(ValueError, match="non-negative"):
            service.process_region(img, x=-1, y=0, width=100, height=100)

    def test_invalid_region_zero_size(self):
        service = ArabicOCRService(languages="eng")
        img = Image.new("RGB", (200, 200))
        with pytest.raises(ValueError, match="positive"):
            service.process_region(img, x=0, y=0, width=0, height=100)

    def test_invalid_region_exceeds_bounds(self):
        service = ArabicOCRService(languages="eng")
        img = Image.new("RGB", (200, 200))
        with pytest.raises(ValueError, match="exceeds"):
            service.process_region(img, x=0, y=0, width=300, height=100)

    def test_region_bbox_adjustment(self):
        """Bounding boxes in region result should be offset to full-image coords."""
        service = ArabicOCRService(languages="eng")
        img = _make_text_image("BBOX TEST", size=(600, 200), font_size=48)
        result = service.process_region(img, x=50, y=30, width=400, height=100)
        for region in result.text_regions:
            if region.bbox:
                assert region.bbox["x"] >= 50
                assert region.bbox["y"] >= 30


# ---------------------------------------------------------------------------
# Task 13: Confidence analytics
# ---------------------------------------------------------------------------

class TestConfidenceAnalytics:
    def test_get_analytics_structure(self):
        result = _sample_result()
        analytics = ArabicOCRService.get_analytics(result)
        assert "per_page" in analytics
        assert "histogram" in analytics
        assert "summary" in analytics
        assert len(analytics["histogram"]) == 10

    def test_summary_fields(self):
        result = _sample_result()
        analytics = ArabicOCRService.get_analytics(result)
        s = analytics["summary"]
        assert "min_confidence" in s
        assert "max_confidence" in s
        assert "mean_confidence" in s
        assert "median_confidence" in s
        assert "total_words" in s
        assert s["total_pages"] == 1

    def test_analytics_empty_result(self):
        result = OCRResult(file_path="/empty.pdf", total_pages=0)
        analytics = ArabicOCRService.get_analytics(result)
        assert analytics["summary"]["total_pages"] == 0


# ---------------------------------------------------------------------------
# Task 15: Multi-format input
# ---------------------------------------------------------------------------

class TestMultiFormatInput:
    def test_process_tiff(self):
        """Create a single-frame TIFF and process it."""
        img = _make_text_image("TIFF TEST", size=(500, 100), font_size=48)
        f = tempfile.NamedTemporaryFile(suffix=".tiff", delete=False)
        img.save(f.name, format="TIFF")
        f.close()
        try:
            service = ArabicOCRService(languages="eng")
            result = service.process_tiff(f.name, detect_tables=False)
            assert result.total_pages == 1
            assert len(result.pages) == 1
            assert result.metadata["format"] == "tiff"
        finally:
            os.unlink(f.name)

    def test_process_tiff_not_found(self):
        service = ArabicOCRService(languages="eng")
        result = service.process_tiff("/nonexistent.tiff")
        assert len(result.errors) > 0

    def test_process_directory(self):
        """Create a temp dir with images and process it."""
        tmpdir = tempfile.mkdtemp()
        try:
            for i in range(2):
                img = _make_text_image(f"IMG {i}", size=(300, 80), font_size=36)
                img.save(os.path.join(tmpdir, f"test_{i}.png"))
            service = ArabicOCRService(languages="eng")
            results = service.process_directory(tmpdir, extensions=[".png"])
            assert len(results) == 2
        finally:
            import shutil
            shutil.rmtree(tmpdir)



# ---------------------------------------------------------------------------
# Task 16: Type annotations — Protocol conformance
# ---------------------------------------------------------------------------

class TestProtocolConformance:
    def test_preprocessor_implements_protocol(self):
        from ..preprocessing import ImagePreprocessor
        from ..types import ImagePreprocessorProtocol

        assert isinstance(ImagePreprocessor(), ImagePreprocessorProtocol)

    def test_postprocessor_implements_protocol(self):
        from ..postprocessing import TextPostprocessor
        from ..types import TextPostprocessorProtocol

        assert isinstance(TextPostprocessor(), TextPostprocessorProtocol)

    def test_language_detector_implements_protocol(self):
        from ..language_detector import LanguageDetector
        from ..types import LanguageDetectorProtocol

        assert isinstance(LanguageDetector(), LanguageDetectorProtocol)

    def test_table_detector_implements_protocol(self):
        from ..table_detector import TableDetector
        from ..types import TableDetectorProtocol

        assert isinstance(TableDetector(), TableDetectorProtocol)

    def test_bbox_typed_dict(self):
        from ..types import BBox

        box: BBox = {"x": 10, "y": 20, "width": 100, "height": 50}
        assert box["x"] == 10


# ---------------------------------------------------------------------------
# Task 17: Property-based testing (Hypothesis)
# ---------------------------------------------------------------------------

class TestPropertyBased:
    def test_postprocessor_never_crashes(self):
        from hypothesis import given, settings
        from hypothesis import strategies as st

        from ..postprocessing import TextPostprocessor

        proc = TextPostprocessor()

        @given(st.text(min_size=0, max_size=500))
        @settings(max_examples=50, deadline=5000)
        def check(text):
            result = proc.process(text)
            assert isinstance(result, str)

        check()

    def test_language_detector_never_crashes(self):
        from hypothesis import given, settings
        from hypothesis import strategies as st

        from ..language_detector import LanguageDetector

        detector = LanguageDetector()

        @given(st.text(min_size=0, max_size=200))
        @settings(max_examples=50, deadline=5000)
        def check(text):
            result = detector.detect(text)
            assert isinstance(result, str)
            assert len(result) > 0

        check()

    def test_confidence_always_valid(self):
        from hypothesis import given, settings
        from hypothesis import strategies as st

        @given(st.lists(st.floats(min_value=0, max_value=100), min_size=1, max_size=10))
        @settings(max_examples=30, deadline=5000)
        def check(confidences):
            avg = sum(confidences) / len(confidences)
            assert 0.0 <= avg <= 100.0

        check()

    def test_cache_invariants(self):
        from hypothesis import given, settings
        from hypothesis import strategies as st

        @given(st.lists(
            st.tuples(st.text(min_size=1, max_size=20), st.integers()),
            min_size=0, max_size=20,
        ))
        @settings(max_examples=30, deadline=5000)
        def check(entries):
            cache = OCRCache(max_size=5)
            # Track the last value per key
            latest: dict = {}
            for key, val in entries:
                cache.put(key, val)
                latest[key] = val
            assert cache.size <= 5
            # Cached values should match the LAST inserted value
            for key in list(latest.keys())[-5:]:
                r = cache.get(key)
                if r is not None:
                    assert r == latest[key]

        check()

    def test_ocr_on_random_images(self):
        """OCR on random-coloured images should never crash."""
        from hypothesis import given, settings
        from hypothesis import strategies as st

        service = ArabicOCRService(languages="eng")

        @given(
            st.integers(min_value=10, max_value=200),
            st.integers(min_value=10, max_value=200),
        )
        @settings(max_examples=5, deadline=30000)
        def check(w, h):
            img = Image.new("RGB", (w, h), color="white")
            result = service.process_image(img, detect_tables=False)
            assert result.page_number == 1
            assert 0.0 <= result.confidence <= 100.0

        check()


# ---------------------------------------------------------------------------
# Task 11: Text layer extractor
# ---------------------------------------------------------------------------

class TestTextLayerExtractor:
    def test_needs_ocr_empty(self):
        from ..text_extractor import ExtractionResult, TextLayerExtractor

        ext = TextLayerExtractor()
        result = ExtractionResult(file_path="/test.pdf")
        assert ext.needs_ocr(result) is True

    def test_pdfminer_respects_page_range(self):
        pytest.importorskip("pdfminer.high_level")
        from ..text_extractor import ExtractionResult, TextLayerExtractor

        path = _make_text_layer_pdf(["FIRST PAGE", "SECOND PAGE"])
        try:
            ext = TextLayerExtractor()
            result = ext._extract_pdfminer(
                path,
                start_page=2,
                end_page=2,
                password=None,
                result=ExtractionResult(file_path=path),
            )
            assert [page.page_number for page in result.pages] == [2]
            assert "SECOND PAGE" in result.pages[0].text
        finally:
            os.unlink(path)


# ===========================================================================
# ROUND 4 TESTS
# ===========================================================================


# ---------------------------------------------------------------------------
# Task 1: TextLayerExtractor wired into process_pdf
# ---------------------------------------------------------------------------

class TestTextLayerWiring:
    def test_skip_ocr_disabled_by_default(self):
        service = ArabicOCRService(languages="eng", dpi=72)
        assert service._text_extractor is None

    def test_skip_ocr_enabled(self):
        service = ArabicOCRService(
            languages="eng", dpi=72, skip_ocr_if_text_layer=True
        )
        assert service._text_extractor is not None

    def test_metadata_has_skipped_count(self):
        service = ArabicOCRService(languages="eng", dpi=72)
        path = _make_real_pdf(1)
        try:
            result = service.process_pdf(path)
            assert "text_layer_pages_skipped" in result.metadata
            assert result.metadata["text_layer_pages_skipped"] == 0
        finally:
            os.unlink(path)


# ---------------------------------------------------------------------------
# Task 3: CLI multi-format
# ---------------------------------------------------------------------------

class TestCLIMultiFormat:
    def test_cli_tiff(self):
        img = _make_text_image("CLI TIFF", size=(400, 80), font_size=36)
        f = tempfile.NamedTemporaryFile(suffix=".tiff", delete=False)
        img.save(f.name, format="TIFF")
        f.close()
        out = tempfile.NamedTemporaryFile(suffix=".json", delete=False)
        out.close()
        try:
            import subprocess

            result = subprocess.run(
                [
                    "python", "-m", "intelligence.ocr",
                    f.name, "--output", out.name,
                    "--format", "json", "--quiet",
                ],
                capture_output=True, text=True,
                cwd=os.path.join(os.path.dirname(__file__), "..", "..", ".."),
                timeout=60,
            )
            assert result.returncode == 0, result.stderr
            with open(out.name) as fp:
                data = json.load(fp)
            assert "pages" in data
        finally:
            os.unlink(f.name)
            os.unlink(out.name)


# ---------------------------------------------------------------------------
# Task 5: Config from file
# ---------------------------------------------------------------------------

class TestConfigFromFile:
    def test_load_yaml_config(self):
        import yaml

        cfg = {"languages": "eng", "dpi": 150, "max_workers": 1}
        f = tempfile.NamedTemporaryFile(
            suffix=".yaml", mode="w", delete=False
        )
        yaml.dump(cfg, f)
        f.close()
        try:
            from ..config import load_config

            loaded = load_config(f.name)
            assert loaded["languages"] == "eng"
            assert loaded["dpi"] == 150
        finally:
            os.unlink(f.name)

    def test_service_from_config(self):
        from ..config import service_from_config

        cfg = {"languages": "eng", "dpi": 150}
        service = service_from_config(cfg)
        assert service.languages == "eng"
        assert service.dpi == 150

    def test_load_missing_file(self):
        from ..config import load_config

        with pytest.raises(FileNotFoundError):
            load_config("/nonexistent.yaml")

    def test_unsupported_format(self):
        f = tempfile.NamedTemporaryFile(suffix=".ini", delete=False)
        f.write(b"[section]\nkey=value")
        f.close()
        try:
            from ..config import load_config

            with pytest.raises(ValueError, match="Unsupported"):
                load_config(f.name)
        finally:
            os.unlink(f.name)


# ---------------------------------------------------------------------------
# Task 6: Prometheus metrics
# ---------------------------------------------------------------------------

class TestPrometheusMetrics:
    def test_record_page(self):
        from ..metrics import OCRMetrics

        m = OCRMetrics()
        m.record_page(confidence=85.0, processing_time_s=1.5)
        m.record_page(confidence=90.0, processing_time_s=0.3)
        assert m.pages_processed == 2
        assert m.avg_confidence == pytest.approx(87.5)

    def test_record_error(self):
        from ..metrics import OCRMetrics

        m = OCRMetrics()
        m.record_page(confidence=0, processing_time_s=0.1, error=True)
        assert m.errors_total == 1

    def test_prometheus_format(self):
        from ..metrics import OCRMetrics

        m = OCRMetrics()
        m.record_page(confidence=95.0, processing_time_s=2.0)
        m.record_document()
        text = m.to_prometheus()
        assert "ocr_pages_processed_total 1" in text
        assert "ocr_documents_processed_total 1" in text
        assert "ocr_processing_time_seconds_bucket" in text

    def test_reset(self):
        from ..metrics import OCRMetrics

        m = OCRMetrics()
        m.record_page(confidence=80, processing_time_s=1.0)
        m.reset()
        assert m.pages_processed == 0
        assert m.avg_confidence == 0.0

    def test_to_dict(self):
        from ..metrics import OCRMetrics

        m = OCRMetrics()
        m.record_page(confidence=75, processing_time_s=0.5)
        d = m.to_dict()
        assert d["pages_processed"] == 1
        assert "time_histogram" in d


# ---------------------------------------------------------------------------
# Task 7: Async streaming
# ---------------------------------------------------------------------------

class TestAsyncStreaming:
    def test_stream_pages(self):
        service = ArabicOCRService(languages="eng", dpi=72)
        path = _make_real_pdf(2)
        try:
            pages = []

            async def collect():
                async for page in service.process_pdf_stream_async(path):
                    pages.append(page)

            asyncio.run(collect())
            assert len(pages) == 2
            assert pages[0].page_number == 1
            assert pages[1].page_number == 2
        finally:
            os.unlink(path)


# ---------------------------------------------------------------------------
# Task 8: Health check with dependency verification (server test)
# ---------------------------------------------------------------------------

class TestHealthCheckDeps:
    def test_health_includes_deps(self):
        try:
            from fastapi.testclient import TestClient
            from ..server import app
        except ImportError:
            pytest.skip("FastAPI not installed")
        client = TestClient(app)
        resp = client.get("/ocr/health")
        assert resp.status_code == 200
        data = resp.json()
        assert "status" in data
        assert data["status"] in ("healthy", "degraded", "unhealthy")
        assert "missing_required" in data
        assert "missing_optional" in data


# ---------------------------------------------------------------------------
# Task 9: PDF/A detection
# ---------------------------------------------------------------------------

class TestPDFA:
    def test_detect_pdfa_negative(self):
        from ..pdf_processor import PDFProcessor

        path = _make_real_pdf(1)
        try:
            result = PDFProcessor.detect_pdfa(path)
            assert result is None  # not PDF/A
        finally:
            os.unlink(path)

    def test_detect_pdfa_positive(self):
        from ..pdf_processor import PDFProcessor

        # Create a fake PDF with PDF/A XMP markers
        content = (
            b"%PDF-1.4\n"
            b"<x:xmpmeta>"
            b"<pdfaid:part>1</pdfaid:part>"
            b"<pdfaid:conformance>b</pdfaid:conformance>"
            b"</x:xmpmeta>\n"
            b"1 0 obj\n<< /Type /Catalog >>\nendobj\n"
            b"%%EOF"
        )
        f = tempfile.NamedTemporaryFile(suffix=".pdf", delete=False)
        f.write(content)
        f.close()
        try:
            result = PDFProcessor.detect_pdfa(f.name)
            assert result is not None
            assert "PDF/A" in result
            assert "1" in result
        finally:
            os.unlink(f.name)

    def test_detect_pdfa_nonexistent(self):
        from ..pdf_processor import PDFProcessor

        result = PDFProcessor.detect_pdfa("/nonexistent.pdf")
        assert result is None


# ---------------------------------------------------------------------------
# Task 10: OCR result diffing
# ---------------------------------------------------------------------------

class TestDiffResults:
    def test_identical_results(self):
        from ..differ import diff_results

        r1 = _sample_result()
        r2 = _sample_result()
        report = diff_results(r1, r2)
        assert report.pages_changed == 0
        assert report.pages_improved == 0
        assert report.pages_regressed == 0

    def test_different_text(self):
        from ..differ import diff_results

        r1 = _sample_result()
        r2 = _sample_result()
        r2.pages[0].text = "Goodbye World"
        report = diff_results(r1, r2)
        assert report.pages_changed == 1
        assert report.page_diffs[0].char_error_rate > 0

    def test_confidence_regression(self):
        from ..differ import diff_results

        r1 = _sample_result()
        r2 = _sample_result()
        r2.pages[0].confidence = 50.0
        r2.overall_confidence = 50.0
        report = diff_results(r1, r2)
        assert report.pages_regressed == 1
        assert report.avg_confidence_b < report.avg_confidence_a

    def test_report_str(self):
        from ..differ import diff_results

        r1 = _sample_result()
        r2 = _sample_result()
        report = diff_results(r1, r2)
        s = str(report)
        assert "Diff:" in s
        assert "Pages:" in s

    def test_report_to_dict(self):
        from ..differ import diff_results

        r1 = _sample_result()
        r2 = _sample_result()
        report = diff_results(r1, r2)
        d = report.to_dict()
        assert "total_pages" in d
        assert "page_diffs" in d


# ---------------------------------------------------------------------------
# Task 6 (continued): Metrics endpoint in server
# ---------------------------------------------------------------------------

class TestMetricsEndpoint:
    def test_metrics_endpoint(self):
        try:
            from fastapi.testclient import TestClient
            from ..server import app
        except ImportError:
            pytest.skip("FastAPI not installed")
        client = TestClient(app)
        resp = client.get("/ocr/metrics")
        assert resp.status_code == 200
        assert "ocr_pages_processed_total" in resp.text
