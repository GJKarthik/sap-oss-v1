# @ui5/genui-collab

Real-time collaboration for SAP Generative UI - multi-user workspaces with presence and cursors.

## Overview

Enables multiple users to collaborate on AI-generated interfaces in real-time, supporting the SAP vision of "living workspaces" where teams can work together without briefing decks or context-setting calls.

## Features

- **Presence Awareness** - See who's online and what they're viewing
- **Cursor Tracking** - Multi-user cursors on shared interfaces
- **State Synchronization** - Keep UI state in sync across clients
- **Workspace Rooms** - Isolated collaboration spaces
- **Conflict Resolution** - Handle concurrent modifications

## Installation

```bash
npm install @ui5/genui-collab
```

## Usage

### Basic Setup

```typescript
import { GenUiCollabModule } from '@ui5/genui-collab';

@NgModule({
  imports: [
    GenUiCollabModule.forRoot({
      websocketUrl: 'wss://collab.example.com',
      userId: currentUser.id,
      displayName: currentUser.name
    })
  ]
})
export class AppModule {}
```

### Join Workspace

```typescript
import { CollaborationService } from '@ui5/genui-collab';

@Component({...})
export class WorkspaceComponent {
  constructor(private collab: CollaborationService) {}
  
  async joinWorkspace(workspaceId: string) {
    await this.collab.joinRoom(workspaceId);
    
    // See other participants
    this.collab.participants$.subscribe(users => {
      console.log('Online users:', users);
    });
    
    // Track their cursors
    this.collab.cursors$.subscribe(cursors => {
      // Render cursor positions
    });
  }
}
```

### Broadcast State Changes

```typescript
// When local user makes changes
this.collab.broadcastStateChange({
  type: 'component_update',
  componentId: 'chart-1',
  changes: { filter: 'Q4 2025' }
});

// Receive changes from others
this.collab.stateChanges$.subscribe(change => {
  if (change.userId !== this.userId) {
    this.applyRemoteChange(change);
  }
});
```

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    User A Browser                        │
│  ┌─────────────────────────────────────────────────┐    │
│  │           CollaborationService                   │    │
│  │  - Presence management                          │    │
│  │  - Cursor broadcasting                          │    │
│  │  - State synchronization                        │    │
│  └──────────────────────┬──────────────────────────┘    │
└─────────────────────────┼───────────────────────────────┘
                          │ WebSocket
                          ▼
           ┌──────────────────────────────┐
           │     Collaboration Server      │
           │  - Room management            │
           │  - Message routing            │
           │  - Conflict resolution        │
           └──────────────────────────────┘
                          ▲
                          │ WebSocket
┌─────────────────────────┼───────────────────────────────┐
│                    User B Browser                        │
│  ┌─────────────────────────────────────────────────┐    │
│  │           CollaborationService                   │    │
│  └─────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────┘
```

## Protocol

### Join Room
```json
{ "type": "join", "roomId": "workspace-123", "userId": "user-1", "displayName": "Alice" }
```

### Presence Update
```json
{ "type": "presence", "userId": "user-1", "status": "active", "location": "chart-panel" }
```

### Cursor Update
```json
{ "type": "cursor", "userId": "user-1", "x": 450, "y": 300, "componentId": "table-1" }
```

### State Change
```json
{ "type": "state", "userId": "user-1", "componentId": "filter-1", "changes": {...} }
```

## License

Apache-2.0 - SAP SE