# @ui5/genui-streaming

Progressive streaming UI composition for generative interfaces - renders A2UI components as they arrive from the agent.

## Overview

This library bridges AG-UI events with the GenUI Renderer, enabling progressive UI materialization as the agent streams A2UI schemas. It provides skeleton loading states, optimistic updates, and smooth transitions.

## Features

- **Progressive Rendering** - Render UI components as they stream in
- **Skeleton States** - Show loading placeholders while waiting for content
- **Delta Updates** - Efficiently update only changed components
- **Layout Streaming** - Stream layout structure before content
- **Optimistic UI** - Show predicted states during tool execution
- **Smooth Transitions** - Animate between states

## Installation

```bash
npm install @ui5/genui-streaming
```

## Usage

### Basic Setup

```typescript
import { GenUiStreamingModule } from '@ui5/genui-streaming';
import { AgUiModule } from '@ui5/ag-ui-angular';
import { GenUiRendererModule } from '@ui5/genui-renderer';

@NgModule({
  imports: [
    AgUiModule.forRoot({ endpoint: 'http://localhost:8080/ag-ui' }),
    GenUiRendererModule.forRoot(),
    GenUiStreamingModule.forRoot({
      enableSkeletons: true,
      transitionDuration: 300
    })
  ]
})
export class AppModule {}
```

### Using the Streaming Outlet

```typescript
import { Component } from '@angular/core';
import { StreamingUiService } from '@ui5/genui-streaming';

@Component({
  template: `
    <genui-streaming-outlet
      [runId]="currentRunId"
      (stateChange)="onStateChange($event)"
      (error)="onError($event)">
      
      <ng-template #skeleton>
        <ui5-busy-indicator active></ui5-busy-indicator>
      </ng-template>
      
    </genui-streaming-outlet>
  `
})
export class MyComponent {
  currentRunId: string | null = null;
  
  constructor(private streaming: StreamingUiService) {
    this.streaming.runStarted$.subscribe(runId => {
      this.currentRunId = runId;
    });
  }
}
```

### Event-Driven Updates

```typescript
import { StreamingUiService } from '@ui5/genui-streaming';

@Injectable()
export class MyService {
  constructor(private streaming: StreamingUiService) {
    // Listen for UI component events
    this.streaming.componentReceived$.subscribe(schema => {
      console.log('New component:', schema.component);
    });
    
    // Listen for layout changes
    this.streaming.layoutChanged$.subscribe(layout => {
      console.log('Layout updated:', layout.type);
    });
  }
}
```

## Streaming States

The service manages these states:

| State | Description |
|-------|-------------|
| `idle` | No active run |
| `connecting` | Establishing connection |
| `streaming` | Receiving events |
| `rendering` | Processing UI updates |
| `complete` | Run finished |
| `error` | Error occurred |

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    AG-UI Client                          │
│           (SSE/WebSocket event stream)                   │
└────────────────────────┬────────────────────────────────┘
                         │
                         │ ui.component events
                         │ ui.layout events
                         │ ui.component_update events
                         ▼
┌────────────────────────────────────────────────────────┐
│              Streaming UI Service                       │
│  - Buffers incoming events                             │
│  - Manages skeleton states                             │
│  - Coordinates progressive rendering                   │
│  - Handles delta updates                               │
└────────────────────────┬───────────────────────────────┘
                         │
                         │ A2UiSchema
                         ▼
┌────────────────────────────────────────────────────────┐
│               GenUI Renderer                            │
│  - Validates schemas                                   │
│  - Creates UI5 components                              │
│  - Manages component lifecycle                         │
└────────────────────────┬───────────────────────────────┘
                         │
                         ▼
              Live UI5 Angular Components
```

## License

Apache-2.0 - SAP SE