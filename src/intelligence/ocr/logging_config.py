"""Structured JSON logging for the OCR module.

Provides a JSON formatter and a convenience ``configure_logging`` function
that sets up all ``intelligence.ocr.*`` loggers to emit structured JSON
lines suitable for ingestion by ELK, Datadog, Splunk, etc.

Usage::

    from intelligence.ocr.logging_config import configure_logging
    configure_logging(level="INFO")
"""

import json
import logging
import time
import uuid
from typing import Optional


class JSONFormatter(logging.Formatter):
    """Emit log records as single-line JSON objects.

    Fields:
        timestamp, level, logger, message, module, funcName, lineno,
        and any extras attached to the record (e.g. request_id, file_hash,
        page_number).
    """

    def format(self, record: logging.LogRecord) -> str:
        entry = {
            "timestamp": self.formatTime(record, self.datefmt),
            "level": record.levelname,
            "logger": record.name,
            "message": record.getMessage(),
            "module": record.module,
            "funcName": record.funcName,
            "lineno": record.lineno,
        }
        # Include any extra fields set via `logger.info("msg", extra={...})`
        for key in ("request_id", "file_hash", "page_number", "dpi",
                     "languages", "elapsed_s", "confidence", "pages_processed",
                     "error"):
            val = getattr(record, key, None)
            if val is not None:
                entry[key] = val
        if record.exc_info and record.exc_info[1]:
            entry["exception"] = self.formatException(record.exc_info)
        return json.dumps(entry, default=str)


class RequestContextFilter(logging.Filter):
    """Inject a ``request_id`` into every log record for traceability.

    Call ``set_request_id(rid)`` to bind an ID; it will be included in
    every subsequent record until ``clear_request_id()`` is called.
    """

    _request_id: Optional[str] = None

    def filter(self, record: logging.LogRecord) -> bool:
        record.request_id = self._request_id  # type: ignore[attr-defined]
        return True

    def set_request_id(self, rid: Optional[str] = None) -> str:
        """Set the current request ID (auto-generates if None)."""
        self._request_id = rid or uuid.uuid4().hex[:12]
        return self._request_id

    def clear_request_id(self) -> None:
        self._request_id = None


# Module-level singleton for easy access
_context_filter = RequestContextFilter()


def configure_logging(
    level: str = "INFO",
    handler: Optional[logging.Handler] = None,
    json_format: bool = True,
) -> None:
    """Configure structured logging for all ``intelligence.ocr`` loggers.

    Args:
        level: Log level string (DEBUG, INFO, WARNING, ERROR).
        handler: Custom handler; defaults to ``StreamHandler(stderr)``.
        json_format: If True, use JSONFormatter.  If False, use standard.
    """
    root_logger = logging.getLogger("intelligence.ocr")
    root_logger.setLevel(getattr(logging, level.upper(), logging.INFO))

    # Remove existing handlers to avoid duplication
    root_logger.handlers.clear()

    h = handler or logging.StreamHandler()
    if json_format:
        h.setFormatter(JSONFormatter())
    else:
        h.setFormatter(
            logging.Formatter(
                "%(asctime)s [%(levelname)s] %(name)s:%(funcName)s:%(lineno)d - %(message)s"
            )
        )

    h.addFilter(_context_filter)
    root_logger.addHandler(h)


def get_context_filter() -> RequestContextFilter:
    """Return the module-level request context filter."""
    return _context_filter

