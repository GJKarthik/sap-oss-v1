# Adaptive UI Architecture

> **"The measure of intelligence is the ability to change."** — Albert Einstein

This architecture enables truly adaptive user interfaces that learn, adapt, and evolve based on user behavior, context, and tasks.

## The Problem

Current "Generative UI" implementations are **static renderers**:
- Schema comes from backend → UI renders it identically for every user
- No memory of user preferences
- No adaptation to behavior patterns
- No contextual awareness
- No learning over time

## The Vision

```
┌─────────────────────────────────────────────────────────────────────┐
│                         ADAPTIVE UI SYSTEM                          │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│   User Intent ──► Context Engine ──► Adaptation Engine ──► UI      │
│        ▲               │                    │               │      │
│        │               ▼                    ▼               │      │
│        │         User Model ◄────────► Learning Loop        │      │
│        │               │                    │               │      │
│        └───────────────┴────────────────────┴───────────────┘      │
│                         FEEDBACK                                    │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

## Core Principles

1. **Learn from Behavior** — Track interactions, infer preferences
2. **Adapt to Context** — Role, task, time, device, data characteristics
3. **Remember Across Sessions** — Preferences persist and evolve
4. **Fail Gracefully** — Sensible defaults, user overrides always win
5. **Privacy First** — Local-first learning, explicit consent for sync

## Architecture Layers

```
┌─────────────────────────────────────────────────────────────────────┐
│ Layer 4: ADAPTIVE COMPONENTS                                        │
│   Components that consume adaptation context and render accordingly │
├─────────────────────────────────────────────────────────────────────┤
│ Layer 3: ADAPTATION ENGINE                                          │
│   Decides HOW to adapt based on user model + context                │
├─────────────────────────────────────────────────────────────────────┤
│ Layer 2: USER MODELING                                              │
│   Builds and maintains user profile from interactions               │
├─────────────────────────────────────────────────────────────────────┤
│ Layer 1: INTERACTION CAPTURE                                        │
│   Records all user interactions with privacy controls               │
├─────────────────────────────────────────────────────────────────────┤
│ Layer 0: CONTEXT PROVIDERS                                          │
│   Role, task, time, device, data characteristics                    │
└─────────────────────────────────────────────────────────────────────┘
```

## Directory Structure

```
adaptive-ui-architecture/
├── README.md                      # This file
├── docs/
│   ├── 01-context-layer.md        # Context providers
│   ├── 02-interaction-layer.md    # Event capture
│   ├── 03-user-modeling.md        # Profile building
│   ├── 04-adaptation-engine.md    # Decision making
│   └── 05-adaptive-components.md  # Component patterns
├── core/
│   ├── context/                   # Context providers
│   ├── capture/                   # Interaction capture
│   ├── modeling/                  # User modeling
│   ├── adaptation/                # Adaptation engine
│   └── storage/                   # Persistence layer
└── components/
    ├── adaptive-filter/           # Example: Adaptive filter
    ├── adaptive-layout/           # Example: Adaptive layout
    └── adaptive-table/            # Example: Adaptive table
```

## Implementation Status

| Layer | Status | Description |
|-------|--------|-------------|
| Layer 0: Context | ✅ **Complete** | Role, task, device, temporal, data context |
| Layer 1: Capture | ✅ **Complete** | Interaction recording with privacy controls |
| Layer 2: Modeling | 🟡 Types Only | User profile building |
| Layer 3: Adaptation | 🟡 Basic Engine | Decision engine with default rules |
| Layer 4: Components | 🟡 Example Only | Adaptive table, filter examples |

## Phase 1 Deliverables (Complete)

### Context Provider (`core/context/`)
- `types.ts` — Full context type definitions
- `context-provider.ts` — Singleton context service
  - Device detection (screen, touch, connection, a11y preferences)
  - Temporal detection (time of day, business period)
  - Session tracking
  - User context management
  - Task mode management
  - Workflow tracking
  - Change subscriptions

### Capture Service (`core/capture/`)
- `types.ts` — Event and configuration types
- `capture-service.ts` — Full capture implementation
  - Event recording with auto-IDs and timestamps
  - Privacy controls (anonymization, exclusions)
  - Local storage persistence
  - Event filtering and querying
  - Pattern extraction (navigation, filter, table)
  - Statistics and analytics
- `capture-hooks.ts` — Framework-agnostic hooks
- `angular/capture.directive.ts` — Angular directives
- `angular/filter-capture.directive.ts` — Filter-specific directive
- `react/use-capture.ts` — React hooks

### Tests (`tests/`)
- `capture-service.test.ts` — Capture service tests
- `context-provider.test.ts` — Context provider tests

### Examples (`examples/`)
- `sac-filter-integration.ts` — Real integration example

## Quick Start

```typescript
import { contextProvider, captureService, createCaptureHooks } from './core';

// 1. Set up user context (on login)
contextProvider.setUserContext({
  userId: 'user-123',
  role: { id: 'admin', name: 'Admin', permissionLevel: 'admin', expertiseLevel: 'expert' },
  organization: 'SAP',
  locale: 'en-US',
  timezone: 'America/New_York',
});

// 2. Create capture hooks for a component
const capture = createCaptureHooks({
  componentType: 'filter',
  componentId: 'main-filter',
});

// 3. Capture interactions
capture.captureFilter('status', 'active');
capture.captureSort('date', 'desc');

// 4. Subscribe to context changes
contextProvider.subscribe((ctx) => {
  console.log('Device:', ctx.device.type);
  console.log('Task mode:', ctx.task.mode);
});

// 5. Query capture history
const recentEvents = captureService.getRecentEvents(30); // Last 30 minutes
const filterPatterns = captureService.getFilterPatterns('main-filter');
```

## License

SAP Internal — Not for external distribution.

