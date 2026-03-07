# @ui5/ag-ui-angular

Angular client library for the AG-UI (Agent-to-UI) protocol - enabling real-time communication between AI agents and Angular user interfaces.

## Overview

This library provides the first Angular implementation of the [AG-UI Protocol](https://github.com/ag-ui-protocol/ag-ui), enabling SAP Joule and other AI agents to dynamically generate and control UI5 Web Components in Angular applications.

## Features

- **SSE/WebSocket Transport** - Dual transport layer for reliable agent communication
- **Event Parsing** - Full AG-UI event type support with TypeScript types
- **State Management** - RxJS-based reactive state synchronization
- **Tool Registry** - Frontend tool registration and invocation
- **Error Recovery** - Automatic reconnection and state recovery

## Installation

```bash
npm install @ui5/ag-ui-angular
```

## Usage

### Basic Setup

```typescript
import { AgUiModule } from '@ui5/ag-ui-angular';

@NgModule({
  imports: [AgUiModule.forRoot({
    endpoint: 'http://localhost:8080/ag-ui',
    transport: 'sse', // or 'websocket'
  })]
})
export class AppModule {}
```

### Connecting to an Agent

```typescript
import { AgUiClient, AgUiEvent } from '@ui5/ag-ui-angular';

@Component({...})
export class MyComponent {
  constructor(private agui: AgUiClient) {
    this.agui.events$.subscribe((event: AgUiEvent) => {
      // Handle incoming events
    });
  }

  async sendMessage(message: string) {
    await this.agui.send({ type: 'user_message', content: message });
  }
}
```

### Registering Frontend Tools

```typescript
import { AgUiToolRegistry } from '@ui5/ag-ui-angular';

@Injectable()
export class MyToolService {
  constructor(private registry: AgUiToolRegistry) {
    this.registry.register({
      name: 'show_notification',
      description: 'Display a notification to the user',
      parameters: {
        type: 'object',
        properties: {
          message: { type: 'string' },
          severity: { type: 'string', enum: ['info', 'warning', 'error'] }
        }
      },
      handler: (params) => this.showNotification(params)
    });
  }
}
```

## AG-UI Event Types

| Event Type | Description |
|------------|-------------|
| `lifecycle.run_started` | Agent run has begun |
| `lifecycle.run_finished` | Agent run completed |
| `lifecycle.run_error` | Agent run encountered error |
| `text.delta` | Incremental text update |
| `text.done` | Text generation complete |
| `tool.call_start` | Tool invocation started |
| `tool.call_result` | Tool returned result |
| `ui.component` | UI component to render (A2UI) |
| `ui.update` | Update existing component |
| `state.sync` | Full state synchronization |

## Architecture

```
┌─────────────────────────────────────────────────────┐
│                 Angular Application                  │
├─────────────────────────────────────────────────────┤
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐ │
│  │  AgUiModule │  │ ToolRegistry│  │ StateManager│ │
│  └──────┬──────┘  └──────┬──────┘  └──────┬──────┘ │
│         │                │                │         │
│  ┌──────┴────────────────┴────────────────┴──────┐ │
│  │              AgUiClient Service               │ │
│  └──────────────────────┬────────────────────────┘ │
│                         │                           │
│  ┌──────────────────────┴────────────────────────┐ │
│  │           Transport Layer (SSE/WS)            │ │
│  └──────────────────────┬────────────────────────┘ │
└─────────────────────────┼───────────────────────────┘
                          │
                          ▼
              ┌───────────────────────┐
              │   AG-UI Agent Server  │
              │   (SAP Joule / MCP)   │
              └───────────────────────┘
```

## License

Apache-2.0 - SAP SE