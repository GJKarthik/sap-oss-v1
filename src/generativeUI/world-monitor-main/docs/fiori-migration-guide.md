# World Monitor Fiori Migration Guide

## Overview

This guide documents the migration strategy from World Monitor's custom TypeScript DOM components to SAP Fiori UI5 Web Components.

## POC: AuditPanelFiori

The `AuditPanelFiori.ts` component demonstrates the migration pattern for all 53 panels in World Monitor.

### Component Mapping

| Custom Component | UI5 Equivalent | Accessibility Notes |
|------------------|----------------|---------------------|
| `Panel` class | `ui5-card` | Built-in header, slots |
| `h('button')` toggles | `ui5-segmented-button` | ARIA pressed, keyboard nav |
| `h('table')` | `ui5-table` | Native keyboard nav, sort |
| Custom badges | `ui5-badge` | Semantic designs |
| Custom loading | `ui5-busy-indicator` | Live region support |
| Custom errors | `ui5-message-strip` | Alert role built-in |

### Import Pattern

```typescript
// Side-effect imports register custom elements
import '@anthropic/ui5-webcomponents/dist/Card.js';
import '@anthropic/ui5-webcomponents/dist/Table.js';
import '@anthropic/ui5-webcomponents/dist/Badge.js';
// etc.
```

### Before (Custom DOM)

```typescript
const filterBar = h('div', { class: 'audit-filters' },
  ...(['all', 'allowed', 'blocked'].map(f =>
    h('button', {
      class: `audit-filter-btn${this.filter === f ? ' active' : ''}`,
      'aria-pressed': this.filter === f ? 'true' : 'false',
      onclick: () => { this.filter = f; this.render(); },
    }, f),
  )),
);
```

### After (UI5 Web Components)

```typescript
const segBtn = document.createElement('ui5-segmented-button');
segBtn.setAttribute('accessible-name', 'Filter decisions by outcome');
segBtn.addEventListener('selection-change', (e) => this.handleFilterChange(e));

for (const f of ['all', 'allowed', 'blocked']) {
  const item = document.createElement('ui5-segmented-button-item');
  item.setAttribute('data-filter', f);
  item.textContent = f.charAt(0).toUpperCase() + f.slice(1);
  if (f === this.filter) item.setAttribute('pressed', '');
  segBtn.appendChild(item);
}
```

## Accessibility Preservation

### Built-in Features from UI5

| Feature | UI5 Component | Auto-handled |
|---------|---------------|--------------|
| `aria-pressed` | `ui5-segmented-button-item` | ✅ |
| Keyboard navigation | `ui5-table` | ✅ |
| Focus management | All components | ✅ |
| `role="grid"` | `ui5-table` | ✅ |
| `aria-label` | `accessible-name` attribute | ✅ |

### Custom Additions Required

| Feature | Implementation |
|---------|----------------|
| Live regions | Add `role="status"` div for filter changes |
| Color independence | Text decorations on outcome badges |
| Reduced motion | CSS `prefers-reduced-motion` |
| High contrast | CSS `forced-colors` |

## Design Token Integration

UI5 Web Components use CSS custom properties for theming:

```css
.audit-panel-fiori ui5-card {
  --sapContent_HeaderBackground: var(--surface);
  --sapTile_Background: var(--surface);
}
```

### Token Mapping

| World Monitor Token | SAP Fiori Token |
|---------------------|-----------------|
| `--surface` | `--sapTile_Background` |
| `--surface-hover` | `--sapList_Hover_Background` |
| `--accent` | `--sapBrandColor` |
| `--text` | `--sapTextColor` |
| `--border` | `--sapGroup_TitleBorderColor` |

## Migration Phases

### Phase 1: Core Components (Weeks 1-2)
- [ ] Install `@ui5/webcomponents` dependencies
- [ ] Create shared import bundle
- [ ] Migrate `Panel` base class → `ui5-card`
- [ ] POC: `AuditPanel` ✅

### Phase 2: Data Panels (Weeks 3-5)
- [ ] Migrate table-based panels (12 files)
- [ ] Migrate chart panels (use `ui5-card` + existing MapLibre)
- [ ] Migrate form panels (7 files)

### Phase 3: Complex Panels (Weeks 6-8)
- [ ] Shell/navigation integration
- [ ] Drag-and-drop panel reordering
- [ ] Responsive breakpoints
- [ ] Storybook documentation

## Testing Checklist

### Accessibility Tests
- [ ] axe-core scan passes
- [ ] Keyboard-only navigation works
- [ ] Screen reader announces all content
- [ ] 4.5:1 contrast maintained
- [ ] Focus indicators visible

### Functional Tests
- [ ] Data loads correctly
- [ ] Filters work
- [ ] Sorting works
- [ ] Responsive layout

### Performance Tests
- [ ] Initial paint < 500ms
- [ ] Interaction latency < 100ms
- [ ] Bundle size increase < 50KB

