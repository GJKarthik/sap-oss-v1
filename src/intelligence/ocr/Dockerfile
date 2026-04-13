FROM python:3.11-slim

WORKDIR /app

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        libgl1 \
        libglib2.0-0 \
        libgomp1 \
        libsm6 \
        libxext6 \
        libxrender1 \
        poppler-utils \
        tesseract-ocr \
        tesseract-ocr-ara \
        tesseract-ocr-eng \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt requirements-service.txt ./
RUN pip install --no-cache-dir -r requirements-service.txt

COPY . /app/src/intelligence/ocr

RUN useradd --no-create-home --shell /bin/false appuser \
    && chown -R appuser:appuser /app

USER appuser

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONPATH=/app/src \
    PORT=8060 \
    OCR_LANGUAGES=ara+eng \
    OCR_DPI=300 \
    OCR_MAX_WORKERS=2 \
    OCR_MAX_CONCURRENT=4 \
    OCR_MAX_UPLOAD_BYTES=104857600 \
    OCR_ALLOWED_CALLBACK_HOSTS="" \
    OCR_WEBHOOK_SECRET=""

EXPOSE 8060

HEALTHCHECK --interval=30s --timeout=10s --start-period=20s --retries=3 \
    CMD curl -f http://localhost:${PORT}/ocr/health || exit 1

CMD ["sh", "-c", "python -m uvicorn intelligence.ocr.server:app --host 0.0.0.0 --port ${PORT:-8060}"]
