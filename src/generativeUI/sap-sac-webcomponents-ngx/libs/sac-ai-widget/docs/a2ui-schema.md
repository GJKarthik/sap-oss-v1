# SAC A2UI (AI to UI) Schema Documentation

## Overview

This document defines the expanded A2UI schema for SAP Analytics Cloud widget generation. The schema enables AI models to generate accessible, responsive UI layouts for SAC dashboards.

## Widget Types

### Original Types (3)
| Type | Description | Data Binding |
|------|-------------|--------------|
| `chart` | Visualization chart | Yes |
| `table` | Data table | Yes |
| `kpi` | Key performance indicator | Yes |

### P2-002 Expansion (+10 types)

#### Filter Types
| Type | Description | ARIA Role |
|------|-------------|-----------|
| `filter-dropdown` | Single/multi-select dropdown | `combobox` |
| `filter-checkbox` | Checkbox list filter | `group` |
| `filter-date-range` | Date range picker | `group` |

#### Slider Types
| Type | Description | ARIA Role |
|------|-------------|-----------|
| `slider` | Single value slider | `slider` |
| `range-slider` | Dual-thumb range slider | `group` with 2 `slider` |

#### Text Types
| Type | Description | ARIA Role |
|------|-------------|-----------|
| `text-block` | Rich text content | none (semantic HTML) |
| `heading` | Semantic heading (h1-h6) | `heading` |
| `divider` | Visual separator | `separator` |

#### Layout Types
| Type | Description | ARIA Role |
|------|-------------|-----------|
| `grid-container` | CSS Grid layout | `group` (optional) |
| `flex-container` | Flexbox layout | `group` (optional) |

## Schema Definition

```typescript
interface SacWidgetSchema {
  // Core properties
  widgetType: SacWidgetType;
  id?: string;
  modelId: string;
  dimensions: string[];
  measures: string[];
  filters?: SacDimensionFilter[];
  title?: string;
  subtitle?: string;
  
  // Layout properties
  layout?: SacLayoutConfig | SacGridConfig;
  children?: SacWidgetSchema[];
  
  // Component-specific
  slider?: SacSliderConfig;
  text?: SacTextConfig;

  // Accessibility
  ariaLabel?: string;
  ariaDescription?: string;
}
```

## Accessibility Requirements

### All Widgets
- **MUST** include `ariaLabel` when visual label is not present
- **MUST** support keyboard navigation
- **MUST** have visible focus indicators
- **MUST** meet 4.5:1 contrast ratio for text

### Filters
```json
{
  "widgetType": "filter-dropdown",
  "ariaLabel": "Filter by region",
  "dimension": "Region"
}
```

### Sliders
- **MUST** include `aria-valuemin`, `aria-valuemax`, `aria-valuenow`
- **SHOULD** include `aria-valuetext` for formatted display
```json
{
  "widgetType": "slider",
  "slider": {
    "min": 0,
    "max": 100,
    "format": "percent"
  },
  "ariaLabel": "Filter by discount rate"
}
```

### Headings
- **MUST** use semantic heading levels (1-6)
- **MUST** follow logical heading hierarchy
```json
{
  "widgetType": "heading",
  "text": { "content": "Sales Overview", "level": 2 }
}
```

## Layout Guidelines

### Grid Layout
- Use 8px grid spacing (`gap: 1` = 8px)
- Responsive columns: 12 → 6 → 3 → 1
```json
{
  "widgetType": "grid-container",
  "layout": {
    "columns": 12,
    "gap": 2,
    "responsive": { "md": 6, "sm": 3, "xs": 1 }
  },
  "children": [...]
}
```

### Flex Layout
```json
{
  "widgetType": "flex-container",
  "layout": {
    "direction": "row",
    "justify": "space-between",
    "align": "center",
    "gap": 2,
    "wrap": true
  },
  "children": [...]
}
```


