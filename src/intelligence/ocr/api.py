"""Backward-compatible entry point for the Arabic OCR HTTP service.

``app`` is the same FastAPI application as ``intelligence.ocr.server:app``
(``/ocr/*`` routes, ``/api/ocr/*`` legacy aliases, metrics, optional CORS).

Run either::

    uvicorn intelligence.ocr.server:app --reload
    uvicorn intelligence.ocr.api:app --reload
"""

from .server import app

__all__ = ["app"]
