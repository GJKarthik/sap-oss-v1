# Arabic OCR Service — Integration Test Results

**Date:** 2026-04-13 14:36:18 UTC+8  
**Target:** `https://arabic-ocr.c-054c570.kyma.ondemand.com`  
**Image:** `docker.io/plturrell/arabic-ocr:1.0.0` (linux/amd64)  
**Namespace:** `sap-ai-services`

---

## Summary

| Metric | Value |
|---|---|
| Total Tests | 28 |
| Passed | **28 (100%)** |
| Failed | 0 |
| Avg Response Time | 542ms |

---

## Test Results by Category

### Health & Status

| Test | Status | Detail | Time |
|---|---|---|---|
| `GET /ocr/health → 200` | ✅ PASS | `status=healthy missing_required=[]` | 134ms |
| Health response has required fields | ✅ PASS | `keys=['status','service','missing_required','missing_optional']` | — |
| Service status is `'healthy'` | ✅ PASS | `status=healthy` | — |
| `GET /api/ocr/health` (legacy) `→ 200` | ✅ PASS | `status=healthy` | 148ms |

### Metrics

| Test | Status | Detail | Time |
|---|---|---|---|
| `GET /ocr/metrics → 200` | ✅ PASS | `content-type=text/plain; charset=utf-8` | 116ms |
| Metrics returns non-empty Prometheus text | ✅ PASS | `body_length=1080 chars` | — |

### Image OCR (`/ocr/image`)

| Test | Status | Detail | Time |
|---|---|---|---|
| `POST /ocr/image` (PNG, detect_tables=true) `→ 200` | ✅ PASS | `keys=['page_number','text','text_regions','tables','confidence','width','height','flagged_for_review','processing_time_s','errors']` | 659ms |
| Image OCR response contains text/pages field | ✅ PASS | All expected fields present | — |
| `POST /ocr/image` (PNG, detect_tables=false) `→ 200` | ✅ PASS | `status=200` | 606ms |
| `POST /ocr/image` (invalid data) `→ 400` | ✅ PASS | `detail=Could not open file as an image` | 164ms |
| `POST /ocr/image` (JPEG format) `→ 200` | ✅ PASS | `status=200` | 464ms |

### PDF OCR (`/ocr/pdf`)

| Test | Status | Detail | Time |
|---|---|---|---|
| `POST /ocr/pdf` (single page) `→ 200` | ✅ PASS | `keys=['file_path','total_pages','pages','metadata','overall_confidence','total_processing_time_s','errors']` | 1034ms |
| PDF OCR response contains pages/text field | ✅ PASS | All expected fields present | — |
| PDF OCR returns at least 1 page | ✅ PASS | `page_count=1` | — |
| `POST /ocr/pdf` (start_page=1, end_page=1) `→ 200` | ✅ PASS | `status=200` | 1084ms |
| `POST /ocr/pdf` (non-PDF file) `→ 400` | ✅ PASS | `detail=File must be a PDF` | 126ms |
| `POST /api/ocr/process` (legacy) `→ 200` | ✅ PASS | `status=200` | 1406ms |

### Batch OCR (`/ocr/batch`)

| Test | Status | Detail | Time |
|---|---|---|---|
| `POST /ocr/batch` (2 PDFs) `→ 200` | ✅ PASS | `batch_size=2 keys=['batch_size','results']` | 2148ms |
| Batch response has `batch_size=2` | ✅ PASS | `batch_size=2` | — |
| Batch response has results array | ✅ PASS | `results_count=2` | — |
| `POST /ocr/batch` (1 valid + 1 invalid) `→ 200` | ✅ PASS | `batch_size=2` | 1085ms |
| Batch mixed: invalid file returns error entry | ✅ PASS | Error entry present in results | — |

### Pipeline Compatibility (`/ocr/pipeline`)

| Test | Status | Detail | Time |
|---|---|---|---|
| `POST /ocr/pipeline` (Angular compat) `→ 200` | ✅ PASS | `queued=True pages_received=2` | 118ms |
| Pipeline response: `queued=true, pages_received=2` | ✅ PASS | `{'queued': True, 'pages_received': 2, 'status': 'accepted'}` | — |

### Error / Edge Cases

| Test | Status | Detail | Time |
|---|---|---|---|
| `POST /ocr/pdf` (no file) `→ 422 Unprocessable` | ✅ PASS | `status=422` | 117ms |
| `POST /ocr/image` (no file) `→ 422 Unprocessable` | ✅ PASS | `status=422` | 125ms |
| `POST /ocr/pdf` (start_page=0, violates ge=1) `→ 422` | ✅ PASS | `status=422` | 113ms |
| `POST /ocr/pdf` (callback_url, no allowlist) `→ 400` | ✅ PASS | `detail=callback_url is disabled; set OCR_ALLOWED_CALLBACK_HOSTS...` | 111ms |

---

## Response Schema

### `/ocr/image` response
```json
{
  "page_number": 1,
  "text": "...",
  "text_regions": [],
  "tables": [],
  "confidence": 0.0,
  "width": 800,
  "height": 200,
  "flagged_for_review": false,
  "processing_time_s": 0.5,
  "errors": []
}
```

### `/ocr/pdf` response
```json
{
  "file_path": "/tmp/tmpXXXXXX.pdf",
  "total_pages": 1,
  "pages": [ { ...per-page OCR result... } ],
  "metadata": {},
  "overall_confidence": 0.0,
  "total_processing_time_s": 0.9,
  "errors": []
}
```

### `/ocr/batch` response
```json
{
  "batch_size": 2,
  "results": [ { ...OCRResult... }, { ...OCRResult... } ]
}
```

---

## Performance Observations

| Endpoint | Typical Latency |
|---|---|
| `/ocr/health` | ~130ms |
| `/ocr/metrics` | ~120ms |
| `/ocr/image` (PNG/JPEG) | 460–660ms |
| `/ocr/pdf` (1 page) | ~1000–1400ms |
| `/ocr/batch` (2 PDFs) | ~2100ms |
| `/ocr/pipeline` | ~120ms |

PDF processing at ~1s/page is consistent with Tesseract at 300 DPI on a 2-core pod (500m request / 2000m limit).

---

## Deployment Info

| Resource | Value |
|---|---|
| Deployment | `arabic-ocr` |
| Service | `arabic-ocr-service` (ClusterIP, port 8060) |
| APIRule | `arabic-ocr` (gateway.kyma-project.io/v2) |
| Host | `arabic-ocr.c-054c570.kyma.ondemand.com` |
| Image | `docker.io/plturrell/arabic-ocr:1.0.0` |
| Replicas | 1 |
| CPU | 500m req / 2000m limit |
| Memory | 1Gi req / 4Gi limit |
| Languages | `ara+eng` (Tesseract) |