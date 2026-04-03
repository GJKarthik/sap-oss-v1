"""In-process metrics collector for the OCR module.

Collects counters, histograms, and gauges that can be exposed via
``/ocr/metrics`` in Prometheus text format, or queried programmatically.

Thread-safe.  No external dependencies.
"""

import threading
import time
from typing import Dict, List


class OCRMetrics:
    """Lightweight metrics collector for OCR processing.

    Tracks:
      - ``pages_processed``: total pages OCR'd
      - ``documents_processed``: total documents processed
      - ``errors_total``: total page-level errors
      - ``confidence_sum`` / ``confidence_count``: for avg confidence
      - ``processing_time_histogram``: bucket counts for processing time

    Thread-safe.
    """

    # Processing time histogram buckets (seconds)
    _TIME_BUCKETS = [0.1, 0.5, 1.0, 2.0, 5.0, 10.0, 30.0, 60.0, float("inf")]

    def __init__(self):
        self._lock = threading.Lock()
        self.pages_processed: int = 0
        self.documents_processed: int = 0
        self.errors_total: int = 0
        self.confidence_sum: float = 0.0
        self.confidence_count: int = 0
        self._time_buckets: Dict[str, int] = {
            f"le_{b}": 0 for b in self._TIME_BUCKETS
        }
        self._time_sum: float = 0.0

    def record_page(self, confidence: float, processing_time_s: float, error: bool = False) -> None:
        """Record metrics for a single processed page."""
        with self._lock:
            self.pages_processed += 1
            if confidence > 0:
                self.confidence_sum += confidence
                self.confidence_count += 1
            if error:
                self.errors_total += 1
            self._time_sum += processing_time_s
            for bucket in self._TIME_BUCKETS:
                if processing_time_s <= bucket:
                    self._time_buckets[f"le_{bucket}"] += 1

    def record_document(self) -> None:
        """Record that a document was processed."""
        with self._lock:
            self.documents_processed += 1

    def _avg_confidence_unlocked(self) -> float:
        """Internal helper — caller MUST hold self._lock."""
        if self.confidence_count == 0:
            return 0.0
        return self.confidence_sum / self.confidence_count

    @property
    def avg_confidence(self) -> float:
        """Average confidence across all recorded pages."""
        with self._lock:
            return self._avg_confidence_unlocked()

    def to_prometheus(self) -> str:
        """Export metrics in Prometheus text exposition format."""
        with self._lock:
            avg = self._avg_confidence_unlocked()
            lines = [
                "# HELP ocr_pages_processed_total Total pages processed",
                "# TYPE ocr_pages_processed_total counter",
                f"ocr_pages_processed_total {self.pages_processed}",
                "",
                "# HELP ocr_documents_processed_total Total documents processed",
                "# TYPE ocr_documents_processed_total counter",
                f"ocr_documents_processed_total {self.documents_processed}",
                "",
                "# HELP ocr_errors_total Total page-level errors",
                "# TYPE ocr_errors_total counter",
                f"ocr_errors_total {self.errors_total}",
                "",
                "# HELP ocr_confidence_avg Average OCR confidence",
                "# TYPE ocr_confidence_avg gauge",
                f"ocr_confidence_avg {avg:.2f}",
                "",
                "# HELP ocr_processing_time_seconds Processing time histogram",
                "# TYPE ocr_processing_time_seconds histogram",
            ]
            for bucket_label, count in self._time_buckets.items():
                le_val = bucket_label.replace("le_", "")
                if le_val == "inf":
                    le_val = "+Inf"
                lines.append(
                    f'ocr_processing_time_seconds_bucket{{le="{le_val}"}} {count}'
                )
            lines.append(
                f"ocr_processing_time_seconds_sum {self._time_sum:.4f}"
            )
            lines.append(
                f"ocr_processing_time_seconds_count {self.pages_processed}"
            )
            return "\n".join(lines) + "\n"

    def to_dict(self) -> dict:
        """Export metrics as a plain dictionary."""
        with self._lock:
            return {
                "pages_processed": self.pages_processed,
                "documents_processed": self.documents_processed,
                "errors_total": self.errors_total,
                "avg_confidence": round(self._avg_confidence_unlocked(), 2),
                "processing_time_sum_s": round(self._time_sum, 4),
                "time_histogram": dict(self._time_buckets),
            }

    def reset(self) -> None:
        """Reset all metrics to zero."""
        with self._lock:
            self.pages_processed = 0
            self.documents_processed = 0
            self.errors_total = 0
            self.confidence_sum = 0.0
            self.confidence_count = 0
            self._time_buckets = {f"le_{b}": 0 for b in self._TIME_BUCKETS}
            self._time_sum = 0.0


# Module-level singleton
_metrics = OCRMetrics()


def get_metrics() -> OCRMetrics:
    """Return the module-level metrics singleton."""
    return _metrics

