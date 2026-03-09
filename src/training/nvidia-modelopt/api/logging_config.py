#!/usr/bin/env python3
"""
Structured JSON logging configuration.

Produces one JSON object per log line so logs are machine-parseable by
Datadog, Loki, CloudWatch, etc.  Falls back to human-readable format
when ``LOG_FORMAT=text`` is set (handy for local development).

Usage::

    from .logging_config import setup_logging, get_logger
    setup_logging()
    logger = get_logger("my-module")
    logger.info("hello", extra={"request_id": "abc", "model_id": "qwen"})
"""

import json
import logging
import os
import sys
from datetime import datetime, timezone
from typing import Any, Dict, Optional


LOG_LEVEL = os.getenv("LOG_LEVEL", "INFO").upper()
LOG_FORMAT = os.getenv("LOG_FORMAT", "json")  # "json" | "text"


class _JSONFormatter(logging.Formatter):
    """Emit each log record as a single JSON line."""

    def format(self, record: logging.LogRecord) -> str:
        payload: Dict[str, Any] = {
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "level": record.levelname,
            "logger": record.name,
            "message": record.getMessage(),
        }

        # Merge structured fields from ``extra``
        for key in ("request_id", "job_id", "model_id", "duration_ms", "status_code"):
            val = getattr(record, key, None)
            if val is not None:
                payload[key] = val

        if record.exc_info and record.exc_info[1]:
            payload["exception"] = self.formatException(record.exc_info)

        return json.dumps(payload, default=str)


class _TextFormatter(logging.Formatter):
    """Human-readable coloured output for local dev."""

    _COLOURS = {
        "DEBUG": "\033[36m",
        "INFO": "\033[32m",
        "WARNING": "\033[33m",
        "ERROR": "\033[31m",
        "CRITICAL": "\033[1;31m",
    }
    _RESET = "\033[0m"

    def format(self, record: logging.LogRecord) -> str:
        colour = self._COLOURS.get(record.levelname, "")
        ts = datetime.now(timezone.utc).strftime("%H:%M:%S")
        extras = ""
        for key in ("request_id", "job_id", "model_id"):
            val = getattr(record, key, None)
            if val is not None:
                extras += f" {key}={val}"
        base = f"{ts} {colour}{record.levelname:>7}{self._RESET} [{record.name}] {record.getMessage()}{extras}"
        if record.exc_info and record.exc_info[1]:
            base += "\n" + self.formatException(record.exc_info)
        return base


def setup_logging(level: Optional[str] = None) -> None:
    """Configure the root logger once."""
    effective_level = getattr(logging, level or LOG_LEVEL, logging.INFO)

    handler = logging.StreamHandler(sys.stdout)
    handler.setFormatter(
        _JSONFormatter() if LOG_FORMAT == "json" else _TextFormatter()
    )

    root = logging.getLogger()
    root.setLevel(effective_level)
    # Remove any existing handlers to avoid duplicate lines
    root.handlers.clear()
    root.addHandler(handler)

    # Quieten noisy libraries
    for name in ("uvicorn.access", "httpcore", "httpx"):
        logging.getLogger(name).setLevel(logging.WARNING)


def get_logger(name: str) -> logging.Logger:
    """Return a named logger (convenience wrapper)."""
    return logging.getLogger(name)

