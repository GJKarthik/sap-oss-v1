# OCR UI Design — Dual-Persona Document Processing

**Date:** 2026-04-04
**Route:** `/training/document-ocr` (existing)
**App:** `training-webcomponents-ngx`
**Status:** Approved for implementation

---

## Overview

A single page that serves two distinct personas through Angular's existing `UserMode` switcher (`novice | intermediate | expert`). Novice and intermediate users get a clean document-extraction UI; expert users get a full data-curation workspace — inline annotation, structured ground-truth correction, per-page QA review, and pipeline handoff — without leaving the page.

---

## Personas

### Normal user (novice / intermediate)
Uploads Arabic/English financial PDFs and consumes results in three equally-weighted ways: sending extracted text to the Chat page for AI Q&A, pulling structured financial figures, and downloading the OCR output. No primary use case dominates; all three actions must be equally prominent.

### Training persona (expert)
ML engineer performing the full data-curation workflow in a single session:
1. **Annotate** — inline text correction against the rendered page image
2. **Correct fields** — override extracted financial values with verified ground truth
3. **QA** — approve or flag each page with reviewer notes
4. **Handoff** — export approved pages as a JSONL training dataset or trigger the pipeline directly

---

## Architecture

One Angular standalone component at `pages/document-ocr/`. Mode-aware layout driven by a `computed()` signal reading from `UserSettingsService.mode` (the actual property name — **not** `userMode`). No routing change, no new page.

```
UserSettingsService.mode()  ─→  computed: isExpert = mode() === 'expert'
                                        │
                              ┌─────────┴──────────┐
                         false (normal)        true (expert)
                              │                     │
                    full-width results         split-pane layout
```

The component listens to `isExpert` and applies layout classes. The split-pane DOM is always rendered but hidden in normal mode (avoids layout shift on mode toggle mid-session).

**Mode-switch during active session:** curation state (`corrections`, `groundTruth`, `pageStatus`, `reviewNotes`) is **preserved** when switching modes — the component is not destroyed. Switching from expert → normal and back retains all review work. No warning is shown to the user on mode switch.

---

## Layout

### Normal mode

```
┌─────────────────────────────────────────────────────┐
│  Upload zone (drag-drop + file picker, 50 MB, PDF)  │
├─────────────────────────────────────────────────────┤
│  [Text] [Tables] [Financial] [Metadata]             │
│  ─────────────────────────────────────────────────  │
│  Tab content (full width)                           │
├─────────────────────────────────────────────────────┤
│  [→ Send to Chat]  [⬇ JSON]  [⬇ Text]   filename   │
└─────────────────────────────────────────────────────┘
```

After upload the upload zone collapses to a compact single-line bar showing filename + "Replace ↺". The action bar is always pinned at the bottom regardless of active tab.

### Expert mode

```
┌─────────────────────────────────────────────────────┐
│  annual-report-2024.pdf · 3 pages      Replace ↺   │
├──── QA status ribbon ───────────────────────────────┤
│  🔬 Curation: ✓ P1 approved · ⏳ P2 pending · 🚩 P3  │
├──────────────────────┬──────────────────────────────┤
│                      │ [✏️ Text] [Fields] [QA] [🚀]  │
│   Page image viewer  ├──────────────────────────────┤
│   (zoom, page nav)   │  Right-panel tab content     │
│                      │                              │
│                      │  [✓ Approve] [🚩 Flag] [↩]   │
├──────────────────────┴──────────────────────────────┤
│  Dataset: 1/3 pages reviewed  ■■■░░░                │
└─────────────────────────────────────────────────────┘
```

The split is ~50/50. The page image viewer is always visible while the right panel changes tabs. The Approve / Flag / Reset controls at the bottom of the right panel are always visible regardless of which expert tab is active — they always operate on `activePage`. The progress tracker spans full width.

---

## Normal Mode — Tab Detail

### Text tab
- Page-by-page extracted text, paginated with Prev / Next controls
- RTL for Arabic content (`dir="rtl"`), LTR for English, automatic per page
- Per-page confidence badge (green ≥ 90%, amber 70–89%, red < 70%)
- Low-confidence regions highlighted amber inline — clicking a highlight scrolls to it
- Page selector shows current page and total

### Tables tab
- All detected tables across all pages listed, with a table selector dropdown for multi-table documents
- Arabic and English column headers preserved side-by-side
- Per-cell confidence colouring (amber < 80%)
- Per-table CSV export button
- Rows with any low-confidence cell shown with amber background

### Financial tab
- All **14** glossary terms always listed (never hidden) — the full `FINANCIAL_GLOSSARY` from `ocr.service.ts`
- Each row: Arabic term · English label · extracted value · currency (from `FinancialField.currency`; `OcrService.FinancialField` must gain a `currency?: string` field, defaulting to `'SAR'` when absent) · source page number
- Missing fields shown in amber with "not found" — not hidden
- Values are read-only in normal mode

### Metadata tab
- Document-level stats in a 2×3 grid: page count, average confidence, processing time, detected languages, error count, flagged-for-review count
- Flagged page count is a link — clicking navigates to the Text tab at that page

### Action bar (pinned, all tabs)
- **Primary:** `→ Send to Chat` (blue, fills sessionStorage with extracted text, navigates to `/training/chat`)
- **Secondary:** `⬇ Export JSON` (outlined blue), `⬇ Export Text` (outlined grey)
- File summary on the right (filename, page count, average confidence)

---

## Expert Mode — Right Panel Tabs

### ✏️ Text — inline diff editor

**Page image rendering:** The left panel renders the page image **client-side** using `pdf.js` (`pdfjs-dist`) from the original uploaded `File` object, which is retained in component state after upload. `pdf.js` renders each page to a `<canvas>` at 1.5× device pixel ratio. The `/ocr/pdf` response provides no image data — only text and bounding boxes. The uploaded `File` is stored in `OcrCurationState.sourceFile`.

**Colour coding:**
| Colour | Meaning |
|--------|---------|
| Green highlight | Corrected by reviewer |
| Amber highlight | Low-confidence region (< 80%) |
| Red highlight | Not yet reviewed |
| No highlight | High-confidence, unedited |

**Click-to-scroll:** Clicking a bounding-box overlay on the page canvas scrolls the text pane to the matching region. Algorithm: on canvas click, find the `OcrTextRegion` whose `bbox` (in page-pixel space) contains the click point after scaling by `canvasWidth / page.naturalWidth`. The matched region's index determines the `scrollTop` of the text pane by summing rendered line heights above it. For v1, this is a best-effort scroll — sub-pixel accuracy is not required.

- Edits are saved automatically to a per-document corrections map in component state
- Reset button restores the original OCR text for the current page
- Per-page Approve / Flag / Note controls at the bottom of the right panel (always visible across all expert tabs)

### Fields — structured ground truth
Always shows all **14** financial glossary terms regardless of active page. Three-column layout:

| Field (AR + EN) | OCR value (strikethrough) | Ground-truth input | Status |
|---|---|---|---|

Status indicators: ✓ verified (green), ⏳ pending (amber), ✗ not found / needs entry (red).

Ground-truth values are saved into the corrections map alongside the page-level text corrections and included in all training exports.

### QA — per-page review board
Tile grid, one tile per page. Each tile shows:
- Page number
- Approval status (approved / in-review / flagged)
- Confidence score
- Coloured border and background matching status

Clicking a tile sets `activePage` and `expertTab = 'text'`, navigating the split pane to that page. The Approve / Flag / Note controls in the footer always reflect `activePage`.

Flagged tiles expand inline to show the reviewer note and an "Override → Approve" button. Notes are free text, saved in component state.

Summary line below the grid: `N approved · N pending · N flagged`.

**Readiness for export:** `pageStatus === 'pending'` exclusively determines the pending count. Flagged pages are counted separately and excluded from the readiness check (a flagged page is reviewed — the reviewer made an active decision).

### 🚀 Export — pipeline handoff
Readiness check at the top: shows how many pages are approved and warns only if any pages are `'pending'` (flagged does not trigger the warning).

**Export formats (radio):**
1. `Training dataset (JSONL)` — one line per approved page: `{ page, text, ground_truth_fields, corrections }`
2. `Annotated JSON` — full `OcrResult` with corrections overlay merged in
3. `Searchable PDF` — original PDF with OCR text layer. This option is **disabled** (greyed out with tooltip "Requires reportlab + pypdf on the server") when `/ocr/health` reports `reportlab` or `pypdf/PyPDF2` as unavailable in `missing_optional`.

**Include checkboxes:** Approved pages (default on), Flagged pages (default off), Ground-truth fields (default on).

**Actions:**
- `⬇ Download dataset` — browser download of the selected format
- `🚀 Send to pipeline` — `POST /api/v1/training/ocr-dataset` with the JSONL payload; navigates to Pipeline page on success. **This endpoint does not yet exist** — the backend route and its request/response schema must be defined as part of implementation. For v1 the button may be implemented as a stub that downloads the JSONL locally and shows a toast: "Dataset ready — trigger pipeline manually from the Pipeline page."

---

## State Model

```typescript
interface OcrCurationState {
  result: OcrResult | null;
  sourceFile: File | null;                     // retained for pdf.js rendering
  activePage: number;                          // 1-based
  normalTab: 'text' | 'tables' | 'financial' | 'metadata';  // normal-mode tabs
  expertTab: 'text' | 'fields' | 'qa' | 'export';           // expert-mode tabs
  corrections: Record<number, string>;         // pageNumber → corrected text
  groundTruth: Record<string, string | null>;  // glossaryKey → verified value
  pageStatus: Record<number, 'pending' | 'approved' | 'flagged'>;
  reviewNotes: Record<number, string>;         // pageNumber → note
  uploading: boolean;
  processing: boolean;
  progress: number;                            // 0–100
}
```

`normalTab` and `expertTab` are distinct — switching between modes does not reset either. `sourceFile` is set on upload and cleared only when the user clicks "Replace ↺".

---

## API Integration

| Action | Method | Endpoint | Notes |
|--------|--------|----------|-------|
| Upload PDF | `POST` | `/ocr/pdf` | Replaces deprecated `/api/ocr/process` |
| Health check | `GET` | `/ocr/health` | Polled on page init and every 30 s; re-checked on HTTP 503 from upload |
| Send to pipeline | `POST` | `/api/v1/training/ocr-dataset` | **New endpoint — not yet implemented; stub for v1** |

`/ocr/image` and `/ocr/batch` are out of scope for this page. The upload zone accepts single PDF files only.

**Health gating:** on page init, call `/ocr/health`. If `status === 'unhealthy'`, disable the upload button and show an inline "Service unavailable — missing: [deps]" banner. Poll every 30 s; re-enable automatically when health recovers. On HTTP 503 from `/ocr/pdf`, trigger an immediate re-check.

---

## Upload & Processing State

1. **Idle** — drag-drop zone shown full width
2. **Uploading** — progress bar (real byte progress via streaming)
3. **Processing** — indeterminate spinner with "OCR in progress…" message
4. **Done** — zone collapses to compact bar; results appear; `sourceFile` retained for pdf.js
5. **Error** — inline error banner with detail from the API (413 → "File too large", 429 → "Server busy, try again", 503 → "Service unavailable", 500 → "Processing failed")

Expert mode: after upload completes, the split pane becomes active, `activePage = 1`, and pdf.js renders page 1 into the canvas automatically.

---

## Accessibility & i18n

- All tab panels use `role="tabpanel"` with `aria-labelledby`
- Colour coding never carries meaning alone — icons and text labels always accompany colour
- RTL layout via `I18nService.dir()` signal (returns `'ltr' | 'rtl'`) bound to the host element `[dir]` attribute
- Arabic financial terms use the `"72 Arabic"` / `"Noto Kufi Arabic"` font stack already loaded globally
- Confidence badges use `aria-label="confidence: 94 percent"`
- Export format radio group uses `<fieldset>` + `<legend>`

**i18n keys (additive — do not replace existing `ocr.*` keys):**
- `ocr.curation.*` — annotation editor labels, approve/flag/reset
- `ocr.export.*` — format names, include checkboxes, pipeline action
- `ocr.qa.*` — tile statuses, reviewer note, override

---

## Files to Create / Modify

| File | Change |
|------|--------|
| `pages/document-ocr/document-ocr.component.ts` | Rewrite: dual-mode layout, `OcrCurationState`, pdf.js integration, new API endpoint |
| `pages/document-ocr/document-ocr.component.html` | New template: upload bar, QA ribbon, split pane, four right-panel tabs |
| `pages/document-ocr/document-ocr.component.scss` | Split-pane layout, diff highlight colours, mode-aware visibility |
| `services/ocr.service.ts` | Update endpoint to `/ocr/pdf`; add `currency?: string` to `FinancialField`; add health-check method; add pipeline handoff stub |
| `assets/i18n/en.json` | Add `ocr.curation.*`, `ocr.export.*`, `ocr.qa.*` keys (~30 keys) |
| `assets/i18n/ar.json` | Same keys in Arabic |
