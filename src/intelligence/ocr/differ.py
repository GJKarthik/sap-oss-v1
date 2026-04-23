"""OCR result diffing for regression detection.

Compares two OCR results on the same document to identify textual
differences and confidence regressions.  Useful for evaluating the
impact of config changes, model updates, or preprocessing changes.

Usage::

    from intelligence.ocr.differ import diff_results
    report = diff_results(result_a, result_b)
    print(report)
"""

import difflib
from dataclasses import dataclass, field
from typing import Dict, List, Optional, TYPE_CHECKING

if TYPE_CHECKING:
    from .arabic_ocr_service import OCRResult


@dataclass
class PageDiff:
    """Diff for a single page between two OCR runs."""

    page_number: int
    text_changed: bool
    confidence_a: float
    confidence_b: float
    confidence_delta: float
    char_error_rate: float  # fraction of chars that differ
    unified_diff: str  # unified diff string


@dataclass
class DiffReport:
    """Complete diff report between two OCR results."""

    file_path_a: str
    file_path_b: str
    total_pages: int
    pages_changed: int
    pages_improved: int  # confidence went up
    pages_regressed: int  # confidence went down
    avg_confidence_a: float
    avg_confidence_b: float
    page_diffs: List[PageDiff] = field(default_factory=list)

    def to_dict(self) -> dict:
        return {
            "file_path_a": self.file_path_a,
            "file_path_b": self.file_path_b,
            "total_pages": self.total_pages,
            "pages_changed": self.pages_changed,
            "pages_improved": self.pages_improved,
            "pages_regressed": self.pages_regressed,
            "avg_confidence_a": round(self.avg_confidence_a, 2),
            "avg_confidence_b": round(self.avg_confidence_b, 2),
            "confidence": round(self.avg_confidence_b, 2),  # Use result_b as the authoritative confidence
            "page_diffs": [
                {
                    "page_number": p.page_number,
                    "text_changed": p.text_changed,
                    "confidence": round(p.confidence_b, 2),  # Use b as primary
                    "confidence_a": round(p.confidence_a, 2),
                    "confidence_b": round(p.confidence_b, 2),
                    "confidence_delta": round(p.confidence_delta, 2),
                    "char_error_rate": round(p.char_error_rate, 4),
                }
                for p in self.page_diffs
            ],
        }

    def __str__(self) -> str:
        lines = [
            f"Diff: {self.file_path_a} vs {self.file_path_b}",
            f"  Pages: {self.total_pages} total, "
            f"{self.pages_changed} changed, "
            f"{self.pages_improved} improved, "
            f"{self.pages_regressed} regressed",
            f"  Avg confidence: {self.avg_confidence_a:.1f}% → "
            f"{self.avg_confidence_b:.1f}%",
        ]
        for pd in self.page_diffs:
            if pd.text_changed:
                lines.append(
                    f"  Page {pd.page_number}: "
                    f"conf {pd.confidence_a:.1f}→{pd.confidence_b:.1f} "
                    f"CER={pd.char_error_rate:.2%}"
                )
        return "\n".join(lines)


def _char_error_rate(a: str, b: str) -> float:
    """Compute character error rate between two strings.

    CER = edit_distance(a, b) / max(len(a), len(b))
    Uses SequenceMatcher ratio as a proxy.
    """
    if not a and not b:
        return 0.0
    ratio = difflib.SequenceMatcher(None, a, b).ratio()
    return 1.0 - ratio


def diff_results(
    result_a: "OCRResult",
    result_b: "OCRResult",
) -> DiffReport:
    """Compare two OCR results and produce a diff report.

    Args:
        result_a: First (baseline) OCR result.
        result_b: Second (comparison) OCR result.

    Returns:
        DiffReport with per-page diffs and summary statistics.
    """
    pages_a = {p.page_number: p for p in result_a.pages}
    pages_b = {p.page_number: p for p in result_b.pages}
    all_pages = sorted(set(pages_a.keys()) | set(pages_b.keys()))

    page_diffs: List[PageDiff] = []
    changed = improved = regressed = 0

    for pn in all_pages:
        pa = pages_a.get(pn)
        pb = pages_b.get(pn)
        text_a = pa.text if pa else ""
        text_b = pb.text if pb else ""
        conf_a = pa.confidence if pa else 0.0
        conf_b = pb.confidence if pb else 0.0

        text_changed = text_a != text_b
        if text_changed:
            changed += 1
        delta = conf_b - conf_a
        if delta > 1.0:
            improved += 1
        elif delta < -1.0:
            regressed += 1

        diff_str = "\n".join(difflib.unified_diff(
            text_a.splitlines(), text_b.splitlines(),
            fromfile=f"a/page_{pn}", tofile=f"b/page_{pn}",
            lineterm="",
        ))

        page_diffs.append(PageDiff(
            page_number=pn,
            text_changed=text_changed,
            confidence_a=conf_a,
            confidence_b=conf_b,
            confidence_delta=delta,
            char_error_rate=_char_error_rate(text_a, text_b),
            unified_diff=diff_str,
        ))

    return DiffReport(
        file_path_a=result_a.file_path,
        file_path_b=result_b.file_path,
        total_pages=len(all_pages),
        pages_changed=changed,
        pages_improved=improved,
        pages_regressed=regressed,
        avg_confidence_a=result_a.overall_confidence,
        avg_confidence_b=result_b.overall_confidence,
        page_diffs=page_diffs,
    )

