# HIG & SAP Design Library Audit — SAC Web Components

**Project:** `sac-webcomponents-ngx`
**Date:** 2025-01-XX
**Auditor:** Cascade (automated)
**Standards:** Apple HIG, SAP Fiori 3 Horizon, WCAG 2.1 AA

---

## Severity Legend

| Icon | Level | Definition |
|------|-------|------------|
| 🔴 | Critical | Accessibility blocker or broken interaction |
| 🟡 | Major | Visible deviation from Fiori/HIG guidelines |
| 🔵 | Minor | Polish / consistency nit |

---

## A — Accessibility (WCAG 2.1 AA)

### A-01 🔴 sac-table: No ARIA table semantics — ✅ FIXED
**File:** `libs/sac-table/src/lib/components/sac-table.component.ts` lines 56–114
**Issue:** The `<table>` element lacks `role="grid"` or `aria-label`. Column headers (`<th>`) have no `scope="col"`. The sortable column click handler is mouse-only — no `(keydown.enter)` or `(keydown.space)` equivalent. Checkbox inputs in table rows lack `aria-label` describing which row they control.
**Fix:** Added `role="grid"`, `aria-label`, `scope="col"`, keyboard handlers, and checkbox labels.
**Status:** Fixed — All ARIA table semantics implemented.

### A-02 🔴 sac-table: Pagination buttons lack accessible labels — ✅ FIXED
**File:** `libs/sac-table/src/lib/components/sac-table.component.ts` lines 120–121
**Issue:** Pagination uses `←` and `→` as button text. Screen readers announce "left arrow" / "right arrow" which is not meaningful. No `aria-label` is provided.
**Fix:** Added `aria-label` with i18n keys `table.previousPage` and `table.nextPage`.
**Status:** Fixed.

### A-03 🔴 sac-table: Loading overlay not announced — ✅ FIXED
**File:** `libs/sac-table/src/lib/components/sac-table.component.ts` lines 125–128
**Issue:** The loading spinner overlay has no `role="status"` or `aria-live` region. Screen readers are unaware that data is loading.
**Fix:** Added `role="status"`, `aria-live="polite"`, and sr-only loading text.
**Status:** Fixed.

### A-04 🟡 sac-filter-dropdown: `ngModel` binding uses native `<select>` without FormsModule import
**File:** `libs/sac-ai-widget/components/sac-filter.component.ts` line 51
**Issue:** The `SacFilterDropdownComponent` uses `[(ngModel)]` but imports `[CommonModule, SacTranslatePipe]` — `FormsModule` is missing from `imports`. This will fail at runtime unless a parent module provides it. The checkbox component also doesn't import `FormsModule`.
**Fix:** Add `FormsModule` to the `imports` array of `SacFilterDropdownComponent`.

### A-05 🟡 sac-data-widget: Date range inputs lack visible labels
**File:** `libs/sac-ai-widget/data-widget/sac-ai-data-widget.component.ts` lines 173–194
**Issue:** The date range picker uses `<input type="date">` with `aria-label` but no visible `<label>` element. Users who rely on visible text cannot identify which field is start/end without relying on the aria-label. The `<label>` above uses the generic `resolvedFilterLabel` for both inputs.
**Fix:** Add visible "From" / "To" labels or use `placeholder` text alongside the aria-labels.

### A-06 🟡 Chat panel input row: `role="form"` without accessible name
**File:** `libs/sac-ai-widget/chat/sac-ai-chat-panel.component.ts`
**Issue:** The chat input row uses `role="form"` with `[attr.aria-label]` which is good, but the `<input>` element uses a static `id="sac-chat-input"`. If multiple chat panels are on the same page, IDs will collide, breaking label associations.
**Fix:** Generate unique IDs using a component instance counter or `crypto.randomUUID()`.

### A-07 🔵 sac-slider: Focus indicator removed on input
**File:** `libs/sac-ai-widget/components/sac-slider.component.ts` lines 101–103
**Issue:** `.sac-slider__input:focus-visible { outline: none; }` — The focus indicator is removed from the slider track. While focus is shown on the thumb via box-shadow, removing outline entirely on the parent element may cause issues in some browsers where thumb pseudo-elements don't receive focus styles.
**Fix:** Keep `outline: none` but ensure the thumb focus style has sufficient contrast (≥ 3:1 against adjacent colors per WCAG 2.1 1.4.11).

---

## B — SAP Fiori Design Tokens & Theming

### B-01 🔴 sac-table: Fully hardcoded colors — no SAP tokens — ✅ FIXED
**File:** `libs/sac-table/src/lib/components/sac-table.component.ts` lines 130–241
**Issue:** The entire sac-table stylesheet used hardcoded hex colors instead of SAP tokens.
**Fix:** Replaced all hardcoded colors with `var(--sap*)` tokens with fallbacks.
**Status:** Fixed — All colors now use SAP Fiori design tokens.

### B-02 🟡 sac-data-widget: Mixed token usage
**File:** `libs/sac-ai-widget/data-widget/sac-ai-data-widget.component.ts` lines 294–414
**Issue:** The data widget styles mostly use SAP tokens but have a few hardcoded values:
- `filter-chip` uses `color-mix()` which is good but the fallback `#fff` should be `var(--sapBackgroundColor)`
- `min-height: 200px` for child widgets is arbitrary; should use a SAP spacing multiple

### B-03 🔵 sac-heading: Hardcoded font sizes instead of SAP type scale
**File:** `libs/sac-ai-widget/components/sac-text.component.ts` lines 57–62
**Issue:** Heading sizes (32/24/20/16/14px) are hardcoded. While they approximately match SAP Horizon's type scale, they should reference `--sapFontHeader1Size` through `--sapFontHeader6Size` tokens for theme consistency.
**Fix:** Use `font-size: var(--sapFontHeader1Size, 32px)` etc.

---

## C — Layout & Responsive Design

### C-01 🟡 sac-table: No responsive behavior — ✅ FIXED
**File:** `libs/sac-table/src/lib/components/sac-table.component.ts`
**Issue:** The table has `overflow-x: auto` (good) but no responsive adaptations. On narrow viewports (<600px), columns don't collapse or reflow. No `@media` queries exist in the component.
**Fix:** Added `@media (max-width: 600px)` breakpoint reducing cell padding and font size.
**Status:** Fixed — Responsive styles added for narrow viewports.

### C-02 🟡 sac-chat-panel: Fixed layout without responsive breakpoints
**File:** `libs/sac-ai-widget/chat/sac-ai-chat-panel.component.ts`
**Issue:** The chat panel has `height: 100%` and `display: flex; flex-direction: column` which works in a container, but has no intrinsic responsive behavior. When used in a narrow sidebar, the input row doesn't adapt (the send button may wrap awkwardly).
**Fix:** Add `@media (max-width: 320px)` to stack the input and button vertically.

### C-03 🔵 sac-data-widget child cards: Fixed min-height
**File:** `libs/sac-ai-widget/data-widget/sac-ai-data-widget.component.ts` line 322
**Issue:** `.sac-ai-data-widget__child { min-height: 200px }` — This is too tall for KPI or divider widgets in containers, causing excessive whitespace.
**Fix:** Reduce to `min-height: 120px` or make it widget-type-aware.

---

## D — HIG Consistency & Feedback

### D-01 🟡 sac-table: Spinner animation has no reduced-motion guard
**File:** `libs/sac-table/src/lib/components/sac-table.component.ts` lines 237–240
**Issue:** The `@keyframes spin` animation runs infinitely with no `prefers-reduced-motion` check.
**Fix:** Add:
```css
@media (prefers-reduced-motion: reduce) {
  .sac-table__spinner { animation: none; }
}
```

### D-02 🟡 sac-table: Empty state shows "No data available" during initial load — ✅ FIXED
**File:** `libs/sac-table/src/lib/components/sac-table.component.ts` lines 84–88
**Issue:** When `loading` is true AND rows are empty, the table shows the loading text in the empty state cell. However, the loading overlay also appears simultaneously, creating a double loading indication.
**Fix:** Only show the empty state cell when `!loading && displayRows.length === 0`.
**Status:** Fixed — Empty state now guarded with `!loading` condition.

### D-03 🔵 sac-filter: No visual feedback on selection change
**File:** `libs/sac-ai-widget/components/sac-filter.component.ts`
**Issue:** When a filter selection changes, the only feedback is the screen-reader announcement. No visual indicator (brief highlight, toast, or badge update) confirms the action to sighted users.
**Fix:** Consider adding a brief border-color flash or subtle transition on selection change.

---

## E — RTL & Internationalization

### E-01 🟡 sac-table: Sort icon uses `margin-left` (physical property) — ✅ FIXED
**File:** `libs/sac-table/src/lib/components/sac-table.component.ts` line 176
**Issue:** `.sac-table__sort-icon { margin-left: 4px }` — In RTL layouts, the sort icon will appear on the wrong side of the header text.
**Fix:** Use `margin-inline-start: 4px`.
**Status:** Fixed — Replaced with `margin-inline-start`.

### E-02 🟡 sac-table: `text-align: left` used throughout — ✅ FIXED
**File:** `libs/sac-table/src/lib/components/sac-table.component.ts` lines 156, 376
**Issue:** Header cells default to `text-align: left` and `resolveColumnAlignment()` returns `'left'`. In RTL layouts, table content should default to `text-align: start`.
**Fix:** Replace `text-align: left` with `text-align: start` in CSS; change default return value to `'start'`.
**Status:** Fixed — Replaced with `text-align: start`.

### E-03 🟡 sac-table: `justify-content: flex-end` in footer
**File:** `libs/sac-table/src/lib/components/sac-table.component.ts` line 203
**Issue:** Pagination footer uses `justify-content: flex-end`. In RTL this places pagination on the left, which is correct for RTL, but the arrow buttons `←` / `→` visually suggest LTR direction.
**Fix:** Use locale-aware icons or swap arrow direction in RTL context.

### E-04 🔵 sac-slider: Value display uses `text-align: right`
**File:** `libs/sac-ai-widget/components/sac-slider.component.ts` line 87
**Issue:** `.sac-slider__value { text-align: right }` — Should be `text-align: end` for RTL.
**Fix:** Replace with `text-align: end`.

### E-05 🔵 sac-text-block: List padding uses `padding-left`
**File:** `libs/sac-ai-widget/components/sac-text.component.ts` line 138
**Issue:** `.sac-text-block__content ul, ol { padding-left: 24px }` — Should be `padding-inline-start`.
**Fix:** Replace with `padding-inline-start: 24px`.

---

## F — Motion & Reduced Motion

### F-01 🟡 sac-slider has `prefers-reduced-motion` ✅ (Good)
The slider component correctly includes a `@media (prefers-reduced-motion: reduce)` guard. This is exemplary.

### F-02 🟡 sac-table spinner and sac-chat-panel cursor lack motion guard
**Files:** `sac-table.component.ts`, `sac-ai-chat-panel.component.ts`
**Issue:** The table spinner and the chat streaming cursor (`▌`) animation have no reduced-motion guard.
**Fix:** Add `@media (prefers-reduced-motion: reduce)` blocks.

---

## G — Component API & Architecture

### G-01 🔵 sac-table: Output names use `on` prefix (Angular anti-pattern)
**File:** `libs/sac-table/src/lib/components/sac-table.component.ts` lines 259–263
**Issue:** `@Output() onCellClick`, `@Output() onRowClick`, etc. Angular style guide recommends event names without the `on` prefix (e.g., `cellClick`, `rowClick`). The `on` prefix is for handler methods, not event emitters.
**Fix:** Rename to `cellClick`, `rowClick`, `selectionChange`, `sortChange`, `pageChange`. This is a breaking API change — consider deprecation path.

### G-02 🔵 sac-data-widget: Self-referential `forwardRef` import
**File:** `libs/sac-ai-widget/data-widget/sac-ai-data-widget.component.ts` line 85
**Issue:** `forwardRef(() => SacAiDataWidgetComponent)` in imports is required for recursive rendering of container children. This is correct but should be documented with a comment explaining why, as it's unusual.

---

## Compliance Summary (Post-Fix)

| Dimension | Critical | Major | Minor | Fixed | Score |
|-----------|----------|-------|-------|-------|-------|
| Accessibility (WCAG 2.1 AA) | ~~3~~ 0 | 3 | 1 | 3 | � |
| SAP Fiori Tokens & Theming | ~~1~~ 0 | 1 | 1 | 1 | � |
| Layout & Responsive | 0 | ~~2~~ 1 | 1 | 1 | 🟡 |
| HIG Consistency & Feedback | 0 | ~~2~~ 1 | 1 | 1 | 🟡 |
| RTL & i18n | 0 | ~~3~~ 1 | 2 | 2 | 🟡 |
| Motion | 0 | 1 | 0 | 0 | 🟡 |
| Component API | 0 | 0 | 2 | 0 | 🔵 |
| **Total** | **0** | **7** | **8** | **8 fixed** | **15 remaining** |

### Snyk Code Scan

| Scan | Result |
|------|--------|
| `snyk code test --severity-threshold=medium libs/` | ✅ 0 issues |

---

## Positive Observations

The SAC project demonstrates several best practices worth highlighting:

1. **sac-ai-chat-panel** — Exemplary WCAG compliance: `role="log"`, `aria-live="polite"`, screen-reader-only announcements, proper labeling, focus management, and SAP Fiori token usage throughout.
2. **sac-slider** — Correct `role="slider"` with `aria-valuemin/max/now/text`, keyboard support (Home/End/PageUp/PageDown), and `prefers-reduced-motion` guard.
3. **sac-filter components** — Good use of `<fieldset>`/`<legend>` in checkbox filter, `aria-labelledby`, live region announcements.
4. **i18n system** — Complete `SacI18nService` with locale switching, RTL detection, interpolation, and consumer-extensible translations.
5. **sac-text components** — Semantic heading hierarchy, DomSanitizer for markdown, proper `role="separator"` on dividers.
