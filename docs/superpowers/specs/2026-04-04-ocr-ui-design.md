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

One Angular standalone component at `pages/document-ocr/`. Mode-aware layout driven by a `computed()` signal reading from `UserSettingsService.userMode`. No routing change, no new page.

```
UserSettingsService.userMode()  ─→  computed: isExpert
                                        │
                              ┌─────────┴──────────┐
                         false (normal)        true (expert)
                              │                     │
                    full-width results         split-pane layout
```

The component listens to `isExpert` and applies layout classes. The split-pane DOM is always rendered but hidden in normal mode (avoids layout shift on mode toggle mid-session).

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

The split is ~50/50. The page image viewer is always visible while the right panel changes tabs. The progress tracker at the bottom spans full width.

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
- All 13 glossary terms always listed (never hidden)
- Each row: Arabic term · English label · extracted value · currency · source page number
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
The left panel shows the rendered page image (via the `/ocr/pdf` response; fall back to page thumbnail if image unavailable). The right panel shows the OCR text as an editable content area.

Colour coding:
| Colour | Meaning |
|--------|---------|
| Green highlight | Corrected by reviewer |
| Amber highlight | Low-confidence region (< 80%) |
| Red highlight | Not yet reviewed |
| No highlight | High-confidence, unedited |

- Clicking a coloured region in the image scrolls the text pane to the same region (coordinate mapping via `text_regions` array in `OcrPageResult`)
- Edits are saved automatically to a per-document corrections map in component state
- Reset button restores the original OCR text for the current page
- Per-page Approve / Flag / Note controls at the bottom of the right panel

### Fields — structured ground truth
Always shows all 13 financial glossary terms regardless of active page. Three-column layout:

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

Clicking a tile navigates the split pane to that page and activates the Text tab.

Flagged tiles expand inline to show the reviewer note and an "Override → Approve" button. Notes are free text, saved in component state.

Summary line below the grid: `N approved · N pending · N flagged`.

### 🚀 Export — pipeline handoff
Readiness check at the top: shows how many pages are approved and warns if any are still pending.

**Export formats (radio):**
1. `Training dataset (JSONL)` — one line per approved page: `{ page, text, ground_truth_fields, corrections }`
2. `Annotated JSON` — full `OcrResult` with corrections overlay merged in
3. `Searchable PDF` — original PDF with OCR text layer (requires `reportlab` + `pypdf`)

**Include checkboxes:** Approved pages (default on), Flagged pages (default off), Ground-truth fields (default on).

**Actions:**
- `⬇ Download dataset` — browser download of the selected format
- `🚀 Send to pipeline` — `POST /api/v1/training/ocr-dataset` with the JSONL payload; navigates to Pipeline page on success

---

## State Model

```typescript
interface OcrCurationState {
  result: OcrResult | null;
  activePage: number;                          // 1-based
  activeTab: 'text' | 'tables' | 'financial' | 'metadata';
  expertTab: 'text' | 'fields' | 'qa' | 'export';
  corrections: Record<number, string>;         // pageNumber → corrected text
  groundTruth: Record<string, string | null>;  // glossaryKey → verified value
  pageStatus: Record<number, 'pending' | 'approved' | 'flagged'>;
  reviewNotes: Record<number, string>;         // pageNumber → note
  uploading: boolean;
  processing: boolean;
  progress: number;                            // 0–100
}
```

All state lives in the component (Angular Signals). No store needed — this is page-local curation work. The corrections map is serialised into the export payload on demand.

---

## API Integration

| Action | Method | Endpoint |
|--------|--------|----------|
| Upload PDF | `POST` | `/ocr/pdf` (new server, replaces `/api/ocr/process`) |
| Upload image | `POST` | `/ocr/image` |
| Batch upload | `POST` | `/ocr/batch` |
| Send to pipeline | `POST` | `/api/v1/training/ocr-dataset` |

The component switches from the deprecated `/api/ocr/process` to the hardened `/ocr/pdf` endpoint. Health gating means the upload button is disabled and shows a "Service unavailable" banner when `/ocr/health` returns 503.

---

## Upload & Processing State

1. **Idle** — drag-drop zone shown full width
2. **Uploading** — progress bar (real byte progress via `_read_with_limit` streaming)
3. **Processing** — indeterminate spinner with "OCR in progress…" message
4. **Done** — zone collapses to compact bar; results appear
5. **Error** — inline error banner with detail from the API (413, 429, 503, 500)

Expert mode: after upload, the split pane becomes active and the first page is loaded automatically.

---

## Accessibility & i18n

- All tab panels use `role="tabpanel"` with `aria-labelledby`
- Colour coding never carries meaning alone — icons and text labels always accompany colour
- RTL layout automatic via `i18n.dir()` signal on the host element
- Arabic financial terms use the `"72 Arabic"` / `"Noto Kufi Arabic"` font stack already loaded globally
- Confidence badges use `aria-label="confidence: 94 percent"` (not just the visual badge)
- Export format radio group has `fieldset` + `legend`

---

## Files to Create / Modify

| File | Change |
|------|--------|
| `pages/document-ocr/document-ocr.component.ts` | Rewrite with dual-mode layout, curation state, new API endpoint |
| `pages/document-ocr/document-ocr.component.html` | New template: upload bar, QA ribbon, split pane, four right-panel tabs |
| `pages/document-ocr/document-ocr.component.scss` | Split-pane layout, diff highlight colours, mode-aware visibility |
| `services/ocr.service.ts` | Update endpoint from `/api/ocr/process` to `/ocr/pdf`; add pipeline handoff method |
| `assets/i18n/en.json` | Add keys: `ocr.curation.*`, `ocr.export.*`, `ocr.qa.*` |
| `assets/i18n/ar.json` | Same keys in Arabic |
