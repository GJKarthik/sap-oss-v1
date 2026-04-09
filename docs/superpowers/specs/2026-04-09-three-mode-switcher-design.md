# Three-Mode Switcher: Chat / Cowork / Training

## Context

The SAP AI Workbench currently treats all user interactions uniformly — the AI assistant behaves the same regardless of whether the user is asking a question, collaborating on a plan, or launching autonomous training jobs. Inspired by Claude's three interaction modes (chat, cowork, code), this design introduces a mode switcher that changes how the AI behaves and what the UI emphasizes, while sharing a single session context.

The goal: let users signal their intent (exploring, collaborating, or executing) and have the entire UI adapt accordingly.

## Modes

### Chat
Conversational Q&A. The AI answers questions, explains concepts, and suggests next steps. No autonomous actions. Suggested routes: Dashboard, Chat, Semantic Search.

### Cowork
Plan-and-preview collaboration. The AI proposes structured action plans before executing anything. Each action requires explicit user approval (approve / edit / reject). Suggested routes: RAG Studio, Analytical Dashboard, PAL Workbench, SPARQL Explorer.

### Training
Autonomous execution. The AI runs pipelines, fine-tuning jobs, data ingestion, glossary training, and RAG builds with minimal user intervention. Suggested routes: Pipeline, Data Explorer, Model Optimizer, Deployments, Vocab Search, Data Cleaning, Glossary Manager, Pair Studio.

## Architecture: Signal-Driven Mode State

A single `activeMode` signal in the existing `@ngrx/signals` AppStore drives all mode-aware behavior through computed properties. No new services.

### Signal Flow

```
activeMode signal ('chat' | 'cowork' | 'training')
        │
        ├── aiCapabilities()    → system prompt prefix + confirmation level
        ├── routeRelevance()    → suggested vs dimmed routes per mode
        ├── contextPills()      → mode-specific quick actions for pill bar
        └── modeThemeClass()    → CSS class for subtle mode theming
                │
                ├── ShellComponent         (reads: activeMode for switcher state)
                ├── Shell template nav-island (reads: routeRelevance for highlighting)
                ├── Shell template pill-bar   (reads: contextPills for actions)
                └── Chat/AI Services          (reads: aiCapabilities for behavior)
```

### Persistence

`activeMode` is persisted to `localStorage` under key `sap-ai-workbench-mode`. On app init, the store reads this value (defaulting to `'chat'` if absent). The `setMode()` method writes to both the signal and localStorage.

### AppStore Extension

Add to the existing `signalStore()` in `store/app.store.ts`:

```typescript
// State
activeMode: (localStorage.getItem('sap-ai-workbench-mode') as AppMode) ?? 'chat',

// Computed
withComputed(store => ({
  aiCapabilities: computed(() => getModeCapabilities(store.activeMode())),
  routeRelevance: computed(() => getRouteRelevance(store.activeMode())),
  contextPills:   computed(() => getContextPills(store.activeMode())),
  modeThemeClass: computed(() => `mode-${store.activeMode()}`),
}))

// Methods
withMethods(store => ({
  setMode(mode: AppMode) {
    patchState(store, { activeMode: mode });
    localStorage.setItem('sap-ai-workbench-mode', mode);
  }
}))
```

### Helper Functions

These pure functions live in `shared/utils/mode.helpers.ts`. They look up from `MODE_CONFIG` and return typed results.

```typescript
// mode.helpers.ts

/** Returns AI behavior config for the active mode */
export function getModeCapabilities(mode: AppMode): AiCapabilities {
  const config = MODE_CONFIG[mode];
  return {
    systemPromptPrefix: config.systemPromptPrefix,
    confirmationLevel: config.confirmationLevel,
  };
}

/** Returns which routes to highlight vs dim */
export function getRouteRelevance(mode: AppMode): RouteRelevance {
  const config = MODE_CONFIG[mode];
  return {
    suggested: config.suggestedRoutes,
    all: TRAINING_ROUTE_LINKS.map(r => r.path),
  };
}

/** Returns context pill definitions for the active mode */
export function getContextPills(mode: AppMode): ContextPill[] {
  return MODE_PILLS[mode];  // static pill definitions per mode, see below
}

export const MODE_PILLS: Record<AppMode, ContextPill[]> = {
  chat: [
    { label: 'Recent chats', icon: 'history', action: 'navigate', target: '/chat' },
    { label: 'Help', icon: 'sys-help', action: 'navigate', target: '/chat?help=true' },
  ],
  cowork: [
    { label: 'Pending plans', icon: 'task', action: 'show-pending' },
    { label: 'Preview', icon: 'inspect', action: 'show-preview' },
  ],
  training: [
    { label: 'Active jobs', icon: 'process', action: 'navigate', target: '/pipeline' },
    { label: 'GPU status', icon: 'machine', action: 'show-gpu' },
  ],
};
```

### Mode Configuration Map

A pure data file defines each mode's behavior. All suggested routes reference existing paths in `TRAINING_ROUTE_LINKS`.

```typescript
// mode.config.ts
export const MODE_CONFIG: Record<AppMode, ModeConfig> = {
  chat: {
    label: 'Chat',
    icon: 'discussion-2',
    confirmationLevel: 'conversational',
    suggestedRoutes: ['/dashboard', '/chat', '/semantic-search'],
    systemPromptPrefix: 'You are a conversational assistant. Answer questions, explain concepts, and suggest next steps. Do not execute actions autonomously.',
  },
  cowork: {
    label: 'Cowork',
    icon: 'collaborate',
    confirmationLevel: 'per-action',
    suggestedRoutes: ['/rag-studio', '/analytical-dashboard', '/pal-workbench', '/sparql-explorer'],
    systemPromptPrefix: 'Plan before acting. Present structured proposals with clear steps. Wait for user approval before executing each action.',
  },
  training: {
    label: 'Training',
    icon: 'accelerated',
    confirmationLevel: 'autonomous',
    suggestedRoutes: ['/pipeline', '/data-explorer', '/model-optimizer', '/deployments', '/vocab-search', '/data-cleaning', '/glossary-manager', '/pair-studio'],
    systemPromptPrefix: 'Execute autonomously. Run pipelines, training jobs, and data operations. Report progress and results.',
  },
};
```

## UI Components

### Mode Switcher (Shell Bar)

Replaces the product switcher in the shell bar. A segmented control with three pills: Chat, Cowork, Training. The active mode gets a filled blue gradient background; inactive modes are ghost-styled.

- Standalone Angular component with OnPush change detection
- Injects AppStore, reads `activeMode`, calls `setMode()` on click
- Emits no outputs — state change flows through the store
- Keyboard accessible: arrow keys to cycle, Enter to select
- SAP Fiori design tokens for colors: `var(--sapShell_InteractiveTextColor)`, `var(--sapContent_Selected_Background)`

### Nav Island: Route Highlighting (inline in ShellComponent)

The nav island is inline markup within `shell.component.ts`, not a separate component. The shell component's template will bind route styling based on `routeRelevance()`:

- Each `nav-island-item` gets a `[class.mode-suggested]` binding: `routeRelevance().suggested.includes(link.path)`
- **Suggested routes**: Full opacity, blue left-border accent (`var(--sapLink_Active_Color)`)
- **Other routes**: Dimmed to 35% opacity, no accent — but still clickable
- Routes are never hidden; mode changes emphasis, not availability
- Transition: 200ms opacity + border fade via CSS transition on the `.nav-island-item` class

### Context Pill Bar (inline in ShellComponent)

The context pill bar is also inline markup within `shell.component.ts`. It will iterate over `contextPills()` instead of a static list:

- Each pill rendered with `@for (pill of store.contextPills(); track pill.label)`
- Pills have a `label`, `icon`, and `action` (navigate or show-panel)
- Clicking a pill dispatches its action via the existing intent system

### Cowork Plan Component

New component for the cowork approval flow. Renders inside the chat message stream as a custom message type.

**Data Model:**

```typescript
export interface CoworkPlan {
  id: string;
  steps: CoworkPlanStep[];
  status: 'proposed' | 'approved' | 'executing' | 'completed' | 'rejected';
}

export interface CoworkPlanStep {
  label: string;
  description: string;
  status: 'pending' | 'running' | 'completed' | 'failed';
}
```

**Component API:**

```typescript
@Component({ selector: 'app-cowork-plan', standalone: true, changeDetection: ChangeDetectionStrategy.OnPush })
export class CoworkPlanComponent {
  plan = input.required<CoworkPlan>();
  planApproved = output<CoworkPlan>();
  planEdited = output<CoworkPlan>();
  planRejected = output<CoworkPlan>();
}
```

**Integration with chat:** The chat message stream uses a discriminated union for message types. Add a `'cowork-plan'` variant:

```typescript
type ChatMessage =
  | { type: 'user'; content: string }
  | { type: 'assistant'; content: string }
  | { type: 'cowork-plan'; plan: CoworkPlan };
```

The chat component renders `<app-cowork-plan>` when it encounters a `cowork-plan` message.

**Behavior:**
- On Approve: emits `planApproved`, AI begins execution, component transitions to live progress view with per-step status (spinner → checkmark)
- On Edit: opens inline editor for the plan steps, user modifies, then approves
- On Reject: emits `planRejected`, AI acknowledges and asks for revised instructions

## Types

```typescript
// mode.types.ts
export type AppMode = 'chat' | 'cowork' | 'training';
export type ConfirmationLevel = 'conversational' | 'per-action' | 'autonomous';

export interface ModeConfig {
  label: string;
  icon: string;
  confirmationLevel: ConfirmationLevel;
  suggestedRoutes: string[];
  systemPromptPrefix: string;
}

export interface AiCapabilities {
  systemPromptPrefix: string;
  confirmationLevel: ConfirmationLevel;
}

export interface RouteRelevance {
  suggested: string[];
  all: string[];
}

export interface ContextPill {
  label: string;
  icon: string;
  action: string;
  target?: string;
}
```

## Route Metadata Extension

Add `modeRelevance` to existing `TrainingRouteLink` in `app.navigation.ts`:

```typescript
interface TrainingRouteLink {
  // ... existing fields (path, labelKey, icon, group, tier)
  modeRelevance: AppMode[];  // which modes suggest this route
}
```

Example entries:
```typescript
{ path: '/chat', ..., modeRelevance: ['chat'] },
{ path: '/rag-studio', ..., modeRelevance: ['cowork'] },
{ path: '/pipeline', ..., modeRelevance: ['training'] },
{ path: '/dashboard', ..., modeRelevance: ['chat', 'cowork', 'training'] },
```

The `getRouteRelevance()` function filters routes where `modeRelevance` includes the active mode. This replaces the hardcoded `suggestedRoutes` arrays in `MODE_CONFIG` at build time — the config serves as the source of truth during development, and once `modeRelevance` is on all routes, the computed can read directly from `TRAINING_ROUTE_LINKS`.

## File Manifest

All paths relative to `src/generativeUI/training-webcomponents-ngx/apps/angular-shell/src/app/`.

| Action | File | Purpose |
|--------|------|---------|
| NEW | `shared/utils/mode.types.ts` | AppMode, ModeConfig, AiCapabilities, RouteRelevance, ContextPill, CoworkPlan types |
| NEW | `shared/utils/mode.config.ts` | MODE_CONFIG map + MODE_PILLS — pure data |
| NEW | `shared/utils/mode.helpers.ts` | getModeCapabilities, getRouteRelevance, getContextPills pure functions |
| NEW | `shared/components/mode-switcher/mode-switcher.component.ts` | Segmented control for shell bar |
| NEW | `shared/components/cowork-plan/cowork-plan.component.ts` | Plan preview card with approve/edit/reject |
| EDIT | `store/app.store.ts` | Add activeMode state + 4 computed properties + setMode method |
| EDIT | `components/shell/shell.component.ts` | Replace product switcher with mode-switcher, add mode-suggested class bindings to nav-island items, bind contextPills to pill bar |
| EDIT | `app.navigation.ts` | Add modeRelevance field to TrainingRouteLink + populate on all 27 routes |

## Verification

1. **Mode switching**: Click each mode in shell bar → verify `activeMode` signal updates, nav highlights change, context pills refresh
2. **Persistence**: Switch to Training mode, refresh the page → verify Training mode is restored from localStorage
3. **Default**: Clear localStorage, reload → verify Chat mode is the default
4. **Shared context**: Switch modes mid-conversation → verify chat history and session state persist
5. **Cowork flow**: In cowork mode, send a request → verify plan card renders with approve/edit/reject buttons → approve → verify execution progress renders
6. **AI behavior**: In Chat mode, verify AI responds conversationally. In Cowork mode, verify AI proposes a plan before acting. In Training mode, verify AI executes without asking for approval
7. **Route highlighting**: In each mode, verify correct routes are highlighted and dimmed routes remain clickable
8. **Keyboard**: Tab to mode switcher, arrow between modes, Enter to select
9. **Tests**: Unit tests using Vitest with `Injector.create()` + `runInInjectionContext()` (project convention — no TestBed) for: mode.helpers.ts pure functions, AppStore computed properties, mode-switcher component, cowork-plan component
