# HIG & SAP Design Library Audit — UI5 Playground

**Project:** `ui5-webcomponents-ngx-main/apps/playground`
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

### A-01 🔴 Nav buttons lack accessible role — ✅ FIXED
**File:** `app.component.html` lines 83–115
**Issue:** The secondary `<nav>` bar uses plain `<button>` elements without `aria-current="page"` on the active item. Screen readers cannot determine the current page.
**Fix:** Add `[attr.aria-current]="isActive(path) ? 'page' : null"` to each nav button.
**Status:** Fixed — `aria-current="page"` added to all 9 nav buttons.

### A-02 🔴 Home cards lack keyboard activation semantics — ✅ FIXED
**File:** `main.component.html` lines 13–131
**Issue:** `<ui5-card>` elements have `(click)` handlers making them interactive, but no `role="link"` or `tabindex="0"`. Cards are not focusable or activatable via keyboard alone. The nested `<ui5-button>` partially compensates but the card surface itself is a click target without keyboard equivalence.
**Fix:** Add `tabindex="0"` and `(keydown.enter)` handler to each card, or wrap in an `<a>` tag. Add `role="link"` and `aria-label` combining title + subtitle.
**Status:** Fixed — `tabindex="0"`, `role="link"`, `aria-label`, and `keydown.enter` added to all 8 home cards.

### A-03 🔴 OCR dropzone has no keyboard equivalent — ✅ FIXED
**File:** `ocr-page.component.html` lines 41–48
**Issue:** The drag-and-drop zone (`div.ocr-page__dropzone`) is mouse-only with no keyboard-accessible file selection alternative beyond the separate `<input type="file">`. The dropzone itself has no `role`, `tabindex`, or `aria-label`.
**Fix:** Add `role="button"` `tabindex="0"` `aria-label` and `(keydown.enter)/(keydown.space)` to trigger the file input.
**Status:** Fixed — `role="button"`, `tabindex="0"`, `aria-label`, and keyboard handlers added.

### A-04 🔴 OCR native `<table>` missing caption and scope — ✅ FIXED
**File:** `ocr-page.component.html` lines 105–125
**Issue:** The line-items `<table>` has no `<caption>` and `<th>` elements lack `scope="col"`. Screen readers cannot associate headers with data cells.
**Fix:** Add `<caption class="sr-only">{{ 'OCR_LINE_ITEMS' | ui5I18n }}</caption>` and `scope="col"` to each `<th>`.
**Status:** Fixed — `<caption>` and `scope="col"` added.

### A-05 🟡 Missing skip-to-content link — ✅ FIXED
**File:** `app.component.html`
**Issue:** No skip-navigation link exists. Users relying on keyboard must tab through the entire shellbar + nav bar to reach main content.
**Fix:** Add a visually-hidden skip link as the first focusable element: `<a class="skip-link" href="#main-content">Skip to content</a>`, and `id="main-content"` on the `<main>` element.
**Status:** Fixed — Skip link and `id="main-content"` added. Skip-link styles added to `styles.scss`.

### A-06 🟡 Busy indicators lack screen-reader text — ✅ FIXED
**File:** `component-playground-page.component.html` line 21, `mcp-page.component.html` line 24, `ocr-page.component.html` line 81
**Issue:** `<ui5-busy-indicator>` is used without an explicit `text` attribute. Screen readers announce it as a generic busy indicator without context.
**Fix:** Add `[text]="'LOADING' | ui5I18n"` to each busy indicator.
**Status:** Fixed — Descriptive `text` attribute added to all three busy indicators.

### A-07 🟡 Collab participant avatars lack accessible names — ✅ FIXED
**File:** `collab-demo.component.html` lines 55–66
**Issue:** Participant avatar circles use inline styles for `background` but no `aria-label` or `title` to identify the participant for screen readers.
**Fix:** Add `[attr.aria-label]="participant.name"` and `role="img"` to each avatar element.
**Status:** Fixed — `role="img"` and `aria-label` added. Also replaced `color: white` with `var(--sapContent_ContrastTextColor)`.

### A-08 🔵 Theme/language selects in nav lack visible labels — ✅ FIXED
**File:** `app.component.html` lines 156–176
**Issue:** The `<ui5-select>` for theme and language switching is preceded by a `<label>` but not programmatically associated (no `for`/`id` relationship on web components). Uses `<label class="app-nav__theme-label">` without linking.
**Fix:** Add `accessible-name` attribute to each `<ui5-select>` mirroring the label text.
**Status:** Fixed — `accessible-name` attribute added to both selects.

---

## B — SAP Fiori Design Tokens & Theming

### B-01 🟡 Presence avatar uses hardcoded `color: white` — ✅ FIXED
**File:** `joule-shell.component.scss` line 119
**Issue:** `.presence-avatar` sets `color: white` instead of a SAP token. In High Contrast Black theme this may become invisible.
**Fix:** Use `color: var(--sapContent_ContrastTextColor, #fff)`.
**Status:** Fixed — Replaced with SAP token.

### B-02 🔵 Main component uses non-token font size
**File:** `main.component.scss` line 27
**Issue:** `.home-hero__subtitle` uses `font-size: 1.0625rem` (17px) which doesn't align with SAP type scale. SAP Horizon uses 14/16/20/24/32px steps.
**Fix:** Use `font-size: var(--sapFontSize, 0.875rem)` or `1rem` (16px).

### B-03 🔵 Joule state badges use non-standard SAP token names
**File:** `joule-shell.component.scss` lines 47–66
**Issue:** Uses `--sapNeutralBackground`, `--sapNeutralColor`, `--sapInformationBackground`, etc. Some of these are not official SAP Horizon token names (`--sapNeutralBackground` is not in the Fiori 3 token set). Fallbacks are present but token names should be verified.
**Fix:** Verify token names against [SAP Theming Parameters](https://experience.sap.com/fiori-design-web/theming/) and use official names.

---

## C — Layout & Responsive Design

### C-01 🟡 Joule panel has fixed 400px width — ✅ FIXED
**File:** `joule-shell.component.scss` line 15
**Issue:** The chat panel is hardcoded to `width: 400px`. On tablets (768–1024px) this consumes ~50% of viewport, leaving insufficient space for the output panel. The 768px breakpoint converts to stacked but there's no intermediate breakpoint.
**Fix:** Add a `@media (max-width: 1024px)` breakpoint reducing to `width: 320px` or using `min-width: 280px; max-width: 40%;`.
**Status:** Fixed — Added `@media (max-width: 1024px) and (min-width: 769px)` breakpoint reducing to 320px.

### C-02 🟡 No medium breakpoint (600–768px) in app shell
**File:** `app.component.scss`
**Issue:** Only two states exist: desktop (default) and mobile (<600px). SAP Fiori specifies three breakpoints: phone (<600), tablet (600–1024), desktop (>1024). The nav bar doesn't adapt for tablet.
**Fix:** Add `@media (max-width: 1024px)` to collapse the nav bar or reduce spacing.

### C-03 🔵 Home page cards max-width limits on wide screens
**File:** `main.component.scss` line 38
**Issue:** `.home-cards` max-width is 860px. On 1440px+ displays the page feels narrow. Fiori Object Pages typically use wider containers.
**Fix:** Increase to `max-width: 1200px` or use `max-width: min(1200px, 90vw)`.

---

## D — HIG Consistency & Feedback

### D-01 🟡 Inconsistent loading patterns
**Issue:** Different pages use different loading indicators:
- `component-playground` and `ocr` use `<ui5-busy-indicator>`
- `joule-shell` uses state badges
- `mcp-page` uses inline text "Loading…"
- Home page cards have no loading state

**Fix:** Standardize on `<ui5-busy-indicator>` with descriptive `text` for all async operations.

### D-02 🟡 No confirmation for destructive actions
**File:** `collab-demo.component.html`
**Issue:** "Leave Room" action executes immediately without confirmation. Users may accidentally disconnect from collaboration.
**Fix:** Add `ui5-dialog` confirmation before executing `leaveRoom()`.

### D-03 🟡 Demo tour banner lacks dismiss persistence
**File:** `app.component.html` lines 166–183
**Issue:** The demo tour banner can be ended but has no "Don't show again" option. It reappears on navigation changes while active, with no way to minimize it.
**Fix:** Add a dismiss/minimize option that persists to `localStorage`.

### D-04 🔵 No empty state on readiness page when all healthy
**File:** `readiness-page.component.html`
**Issue:** When all routes are healthy, the page shows all green cards but no summary message like "All systems go." Apple HIG recommends confirming positive states explicitly.
**Fix:** Add a success message strip when `!demoBlocked`.

---

## E — RTL & Internationalization

### E-01 🔵 Product popover list items not i18n-ized
**File:** `app.component.html` lines 126–131
**Issue:** Product switcher labels like "AI Fabric Console", "Training Console" are hardcoded English strings, not translated via `ui5I18n` pipe.
**Fix:** Replace with `{{ 'PRODUCT_AI_FABRIC' | ui5I18n }}` etc.

### E-02 🔵 RTL overrides use physical properties
**File:** `app.component.scss` lines 112–142
**Issue:** RTL overrides use `[dir="rtl"] .app-nav { flex-direction: row-reverse }` instead of CSS logical properties. This is fragile and adds maintenance burden.
**Fix:** Convert to logical properties (`margin-inline-start`, `border-inline-end`, `padding-inline`) and remove explicit RTL overrides.

---

## F — Motion & Reduced Motion

### F-01 🟡 No `prefers-reduced-motion` guard — ✅ FIXED
**File:** All SCSS files
**Issue:** The playground app has no `@media (prefers-reduced-motion: reduce)` query. The `home-card` hover transition, Joule state badge transitions, and router animations all run regardless of user preference.
**Fix:** Add global reduced-motion guard to `styles.scss`.
**Status:** Fixed — Global `@media (prefers-reduced-motion: reduce)` guard added to `styles.scss`.

---

## G — Component API Correctness

### G-01 🔵 `ui5-shellbar-item` `count=""` is redundant
**File:** `app.component.html` lines 38–69
**Issue:** Every `<ui5-shellbar-item>` has `count=""` which renders an empty badge. If no count is needed, omit the attribute entirely.
**Fix:** Remove `count=""` from all shellbar items that don't display a count.

### G-02 🔵 Forms page uses `value-state` string literal
**File:** `forms-page.component.html`
**Issue:** The forms page conditionally applies `value-state="Negative"` but doesn't provide `value-state-message` slot content for all error states. UI5 components show a generic tooltip without the slot.
**Fix:** Add `<div slot="valueStateMessage">` with specific error descriptions.

---

## Compliance Summary

| Dimension | Critical | Major | Minor | Fixed | Score |
|-----------|----------|-------|-------|-------|-------|
| Accessibility (WCAG 2.1 AA) | ~~4~~ 0 | ~~3~~ 0 | ~~1~~ 0 | 8 | ✅ |
| SAP Fiori Tokens & Theming | 0 | ~~1~~ 0 | 2 | 1 | � |
| Layout & Responsive | 0 | ~~2~~ 1 | 1 | 1 | 🟡 |
| HIG Consistency & Feedback | 0 | 3 | 1 | 0 | 🟡 |
| RTL & i18n | 0 | 0 | 2 | 0 | 🔵 |
| Motion | 0 | ~~1~~ 0 | 0 | 1 | ✅ |
| Component API | 0 | 0 | 2 | 0 | 🔵 |
| **Total** | **0** | **4** | **8** | **11 fixed** | **12 remaining** |

### Snyk Code Scan

| Scan | Result |
|------|--------|
| `snyk code test --severity-threshold=medium apps/playground/src` | ✅ 0 issues |
