# @ui5/genui-renderer

Schema-driven renderer for A2UI (Agent-to-UI) specifications - mapping JSON schemas to real UI5 Angular components.

## Overview

This library provides the A2UI rendering layer for SAP's generative UI implementation. It validates incoming A2UI schemas, resolves them to UI5 Angular components, and renders them dynamically with full data binding support.

## Features

- **Component Registry** - Curated catalog of allowed UI5 components with security allowlist
- **Schema Validation** - JSON Schema validation for A2UI specifications
- **Dynamic Instantiation** - Creates real UI5 Angular components at runtime
- **Layout Engine** - Supports Fiori floorplans (list, form, dashboard, analytical)
- **Data Binding** - Connects component properties to data sources
- **Security** - Deny-unknown-components policy, HTML sanitization

## Installation

```bash
npm install @ui5/genui-renderer
```

## Usage

### Basic Setup

```typescript
import { GenUiRendererModule } from '@ui5/genui-renderer';

@NgModule({
  imports: [
    GenUiRendererModule.forRoot({
      allowedComponents: 'fiori-standard', // or custom allowlist
      sanitize: true
    })
  ]
})
export class AppModule {}
```

### Rendering A2UI Schema

```typescript
import { A2UiRenderer, A2UiSchema } from '@ui5/genui-renderer';

@Component({
  template: `<genui-outlet [schema]="schema"></genui-outlet>`
})
export class MyComponent {
  schema: A2UiSchema = {
    component: 'ui5-table',
    props: {
      headerText: 'Suppliers at Risk'
    },
    children: [
      {
        component: 'ui5-table-column',
        props: { slot: 'columns' },
        children: [{ component: 'ui5-label', props: { text: 'Supplier' } }]
      }
    ]
  };
}
```

### Component Allowlist

```typescript
import { ComponentRegistry } from '@ui5/genui-renderer';

@Injectable()
export class MyRegistry {
  constructor(private registry: ComponentRegistry) {
    // Allow custom components
    this.registry.allow('my-custom-chart');
    
    // Block specific components
    this.registry.deny('ui5-file-uploader');
  }
}
```

## A2UI Schema Format

```typescript
interface A2UiSchema {
  // Component tag name (must be in allowlist)
  component: string;
  
  // Props to pass to component
  props?: Record<string, unknown>;
  
  // Child components
  children?: A2UiSchema[];
  
  // Slot assignments
  slots?: Record<string, A2UiSchema | A2UiSchema[]>;
  
  // Event handlers (mapped to tool calls)
  events?: Record<string, { toolName: string; arguments?: Record<string, unknown> }>;
  
  // Data bindings
  bindings?: Record<string, { source: string; path: string; transform?: string }>;
}
```

## Fiori Floorplans

The renderer supports standard SAP Fiori floorplans:

| Floorplan | Use Case |
|-----------|----------|
| `list-report` | Tabular data with filtering |
| `object-page` | Detailed entity view |
| `worklist` | Task-oriented view |
| `analytical` | Charts and KPIs |
| `wizard` | Multi-step processes |
| `master-detail` | Split-view navigation |

## Architecture

```
┌─────────────────────────────────────────────────────┐
│                  A2UI Schema (JSON)                  │
└────────────────────────┬────────────────────────────┘
                         │
┌────────────────────────▼────────────────────────────┐
│              Schema Validator                        │
│  - JSON Schema validation                           │
│  - Security checks (allowlist)                      │
│  - HTML sanitization                                │
└────────────────────────┬────────────────────────────┘
                         │
┌────────────────────────▼────────────────────────────┐
│            Component Registry                        │
│  - Maps component names to Angular components       │
│  - Resolves slots and children                      │
│  - Applies Fiori theming                            │
└────────────────────────┬────────────────────────────┘
                         │
┌────────────────────────▼────────────────────────────┐
│          Dynamic Component Factory                   │
│  - Creates ComponentRef at runtime                  │
│  - Binds inputs/outputs                             │
│  - Manages lifecycle                                │
└────────────────────────┬────────────────────────────┘
                         │
                         ▼
              Real UI5 Angular Components
```

## License

Apache-2.0 - SAP SE