# Three-Mode Switcher Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Chat / Cowork / Training mode switcher to the shell bar that drives AI behavior, nav route highlighting, and context pills through a single signal in the existing @ngrx/signals store.

**Architecture:** A single `activeMode` signal in the AppStore cascades through computed properties (`aiCapabilities`, `routeRelevance`, `contextPills`, `modeThemeClass`) to the shell component. The mode switcher replaces the product switcher in the shell bar. All mode configuration lives in a pure data map. The cowork plan-and-preview flow uses a new component rendered as a discriminated chat message type.

**Tech Stack:** Angular 20, @ngrx/signals, UI5 Web Components, Vitest, SAP Fiori design tokens

**Spec:** `docs/superpowers/specs/2026-04-09-three-mode-switcher-design.md`

---

All file paths relative to: `src/generativeUI/training-webcomponents-ngx/apps/angular-shell/src/app/`

## Chunk 1: Types, Config, and Store Extension

### Task 1: Mode Types

**Files:**
- Create: `shared/utils/mode.types.ts`
- Test: `shared/utils/mode.types.spec.ts`

- [ ] **Step 1: Write the type file**

```typescript
// shared/utils/mode.types.ts
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

- [ ] **Step 2: Write a type-checking test**

```typescript
// shared/utils/mode.types.spec.ts
import { describe, it, expect } from 'vitest';
import type { AppMode, ModeConfig, CoworkPlan, CoworkPlanStep, ContextPill } from './mode.types';

describe('mode.types', () => {
  it('AppMode accepts valid values', () => {
    const modes: AppMode[] = ['chat', 'cowork', 'training'];
    expect(modes).toHaveLength(3);
  });

  it('CoworkPlan has required shape', () => {
    const plan: CoworkPlan = {
      id: 'test-1',
      steps: [{ label: 'Step 1', description: 'Do thing', status: 'pending' }],
      status: 'proposed',
    };
    expect(plan.steps).toHaveLength(1);
    expect(plan.status).toBe('proposed');
  });

  it('ContextPill target is optional', () => {
    const pill: ContextPill = { label: 'Test', icon: 'home', action: 'navigate' };
    expect(pill.target).toBeUndefined();

    const pillWithTarget: ContextPill = { label: 'Test', icon: 'home', action: 'navigate', target: '/chat' };
    expect(pillWithTarget.target).toBe('/chat');
  });
});
```

- [ ] **Step 3: Run test to verify it passes**

Run: `npx vitest run shared/utils/mode.types.spec.ts`
Expected: PASS (3 tests)

- [ ] **Step 4: Commit**

```bash
git add shared/utils/mode.types.ts shared/utils/mode.types.spec.ts
git commit -m "feat(mode): add AppMode, ModeConfig, CoworkPlan types"
```

---

### Task 2: Mode Configuration Map

**Files:**
- Create: `shared/utils/mode.config.ts`
- Test: `shared/utils/mode.config.spec.ts`
- Reference: `app.navigation.ts` (verify all routes exist in `TRAINING_ROUTE_LINKS`)

- [ ] **Step 1: Write the failing test**

```typescript
// shared/utils/mode.config.spec.ts
import { describe, it, expect } from 'vitest';
import { MODE_CONFIG, MODE_PILLS } from './mode.config';
import { TRAINING_ROUTE_LINKS } from '../../app.navigation';
import type { AppMode } from './mode.types';

describe('MODE_CONFIG', () => {
  const allRoutePaths = TRAINING_ROUTE_LINKS.map(r => r.path);

  it('defines all three modes', () => {
    expect(Object.keys(MODE_CONFIG)).toEqual(['chat', 'cowork', 'training']);
  });

  it('every suggestedRoute exists in TRAINING_ROUTE_LINKS', () => {
    for (const [mode, config] of Object.entries(MODE_CONFIG)) {
      for (const route of config.suggestedRoutes) {
        expect(allRoutePaths, `${mode} references missing route: ${route}`).toContain(route);
      }
    }
  });

  it('each mode has a non-empty systemPromptPrefix', () => {
    for (const config of Object.values(MODE_CONFIG)) {
      expect(config.systemPromptPrefix.length).toBeGreaterThan(10);
    }
  });

  it('each mode has a distinct confirmationLevel', () => {
    const levels = Object.values(MODE_CONFIG).map(c => c.confirmationLevel);
    expect(new Set(levels).size).toBe(3);
  });
});

describe('MODE_PILLS', () => {
  it('defines pills for all three modes', () => {
    const modes: AppMode[] = ['chat', 'cowork', 'training'];
    for (const mode of modes) {
      expect(MODE_PILLS[mode].length).toBeGreaterThan(0);
    }
  });

  it('each pill has label, icon, and action', () => {
    for (const pills of Object.values(MODE_PILLS)) {
      for (const pill of pills) {
        expect(pill.label).toBeTruthy();
        expect(pill.icon).toBeTruthy();
        expect(pill.action).toBeTruthy();
      }
    }
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npx vitest run shared/utils/mode.config.spec.ts`
Expected: FAIL — `mode.config` module not found

- [ ] **Step 3: Write the config file**

```typescript
// shared/utils/mode.config.ts
import type { AppMode, ModeConfig, ContextPill } from './mode.types';

export const MODE_CONFIG: Record<AppMode, ModeConfig> = {
  chat: {
    label: 'Chat',
    icon: 'discussion-2',
    confirmationLevel: 'conversational',
    suggestedRoutes: ['/dashboard', '/chat', '/semantic-search'],
    systemPromptPrefix:
      'You are a conversational assistant. Answer questions, explain concepts, and suggest next steps. Do not execute actions autonomously.',
  },
  cowork: {
    label: 'Cowork',
    icon: 'collaborate',
    confirmationLevel: 'per-action',
    suggestedRoutes: ['/rag-studio', '/analytical-dashboard', '/pal-workbench', '/sparql-explorer'],
    systemPromptPrefix:
      'Plan before acting. Present structured proposals with clear steps. Wait for user approval before executing each action.',
  },
  training: {
    label: 'Training',
    icon: 'accelerated',
    confirmationLevel: 'autonomous',
    suggestedRoutes: [
      '/pipeline', '/data-explorer', '/model-optimizer', '/deployments',
      '/vocab-search', '/data-cleaning', '/glossary-manager', '/pair-studio',
    ],
    systemPromptPrefix:
      'Execute autonomously. Run pipelines, training jobs, and data operations. Report progress and results.',
  },
};

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

- [ ] **Step 4: Run test to verify it passes**

Run: `npx vitest run shared/utils/mode.config.spec.ts`
Expected: PASS (6 tests)

- [ ] **Step 5: Commit**

```bash
git add shared/utils/mode.config.ts shared/utils/mode.config.spec.ts
git commit -m "feat(mode): add MODE_CONFIG and MODE_PILLS configuration map"
```

---

### Task 3: Mode Helper Functions

**Files:**
- Create: `shared/utils/mode.helpers.ts`
- Test: `shared/utils/mode.helpers.spec.ts`

- [ ] **Step 1: Write the failing test**

```typescript
// shared/utils/mode.helpers.spec.ts
import { describe, it, expect } from 'vitest';
import { getModeCapabilities, getRouteRelevance, getContextPills } from './mode.helpers';

describe('getModeCapabilities', () => {
  it('returns conversational confirmation for chat mode', () => {
    const caps = getModeCapabilities('chat');
    expect(caps.confirmationLevel).toBe('conversational');
    expect(caps.systemPromptPrefix).toContain('conversational');
  });

  it('returns per-action confirmation for cowork mode', () => {
    const caps = getModeCapabilities('cowork');
    expect(caps.confirmationLevel).toBe('per-action');
    expect(caps.systemPromptPrefix).toContain('Plan before acting');
  });

  it('returns autonomous confirmation for training mode', () => {
    const caps = getModeCapabilities('training');
    expect(caps.confirmationLevel).toBe('autonomous');
    expect(caps.systemPromptPrefix).toContain('autonomously');
  });
});

describe('getRouteRelevance', () => {
  it('returns suggested routes for chat mode', () => {
    const relevance = getRouteRelevance('chat');
    expect(relevance.suggested).toContain('/chat');
    expect(relevance.suggested).toContain('/dashboard');
  });

  it('returns all routes regardless of mode', () => {
    const chatRelevance = getRouteRelevance('chat');
    const trainingRelevance = getRouteRelevance('training');
    expect(chatRelevance.all).toEqual(trainingRelevance.all);
    expect(chatRelevance.all.length).toBeGreaterThan(20);
  });

  it('training mode suggests pipeline routes', () => {
    const relevance = getRouteRelevance('training');
    expect(relevance.suggested).toContain('/pipeline');
    expect(relevance.suggested).toContain('/data-explorer');
    expect(relevance.suggested).not.toContain('/chat');
  });
});

describe('getContextPills', () => {
  it('returns pills for each mode', () => {
    expect(getContextPills('chat').length).toBeGreaterThan(0);
    expect(getContextPills('cowork').length).toBeGreaterThan(0);
    expect(getContextPills('training').length).toBeGreaterThan(0);
  });

  it('chat pills include recent chats', () => {
    const pills = getContextPills('chat');
    expect(pills.some(p => p.label === 'Recent chats')).toBe(true);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npx vitest run shared/utils/mode.helpers.spec.ts`
Expected: FAIL — `mode.helpers` module not found

- [ ] **Step 3: Write the helpers**

```typescript
// shared/utils/mode.helpers.ts
import { MODE_CONFIG, MODE_PILLS } from './mode.config';
import { TRAINING_ROUTE_LINKS } from '../../app.navigation';
import type { AppMode, AiCapabilities, RouteRelevance, ContextPill } from './mode.types';

export function getModeCapabilities(mode: AppMode): AiCapabilities {
  const config = MODE_CONFIG[mode];
  return {
    systemPromptPrefix: config.systemPromptPrefix,
    confirmationLevel: config.confirmationLevel,
  };
}

export function getRouteRelevance(mode: AppMode): RouteRelevance {
  const config = MODE_CONFIG[mode];
  return {
    suggested: config.suggestedRoutes,
    all: TRAINING_ROUTE_LINKS.map(r => r.path),
  };
}

export function getContextPills(mode: AppMode): ContextPill[] {
  return MODE_PILLS[mode];
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `npx vitest run shared/utils/mode.helpers.spec.ts`
Expected: PASS (7 tests)

- [ ] **Step 5: Commit**

```bash
git add shared/utils/mode.helpers.ts shared/utils/mode.helpers.spec.ts
git commit -m "feat(mode): add getModeCapabilities, getRouteRelevance, getContextPills helpers"
```

---

### Task 4: AppStore Extension

**Files:**
- Modify: `store/app.store.ts` (lines 31-36 for state, lines 58-88 for computed, lines 89-124 for methods)
- Test: `store/app.store.spec.ts`

- [ ] **Step 1: Write the failing test**

```typescript
// store/app.store.spec.ts
import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { Injector, runInInjectionContext } from '@angular/core';
import { AppStore } from './app.store';
import { ApiService } from '../services/api.service';
import { of } from 'rxjs';

// The store uses inject(ApiService) in withMethods and calls loadDashboardData in onInit.
// We must provide a mock ApiService to avoid NullInjectorError.
const mockApiService = {
  get: () => of(null),
  post: () => of(null),
};

describe('AppStore mode extension', () => {
  beforeEach(() => {
    localStorage.removeItem('sap-ai-workbench-mode');
  });

  afterEach(() => {
    localStorage.removeItem('sap-ai-workbench-mode');
  });

  function createStore() {
    const injector = Injector.create({
      providers: [
        AppStore,
        { provide: ApiService, useValue: mockApiService },
      ],
    });
    return runInInjectionContext(injector, () => injector.get(AppStore));
  }

  it('initializes with chat mode by default', () => {
    const store = createStore();
    expect(store.activeMode()).toBe('chat');
  });

  it('setMode updates activeMode signal', () => {
    const store = createStore();
    store.setMode('training');
    expect(store.activeMode()).toBe('training');
  });

  it('setMode persists to localStorage', () => {
    const store = createStore();
    store.setMode('cowork');
    expect(localStorage.getItem('sap-ai-workbench-mode')).toBe('cowork');
  });

  it('reads persisted mode from localStorage on init', () => {
    localStorage.setItem('sap-ai-workbench-mode', 'training');
    const store = createStore();
    expect(store.activeMode()).toBe('training');
  });

  it('aiCapabilities returns correct confirmation for each mode', () => {
    const store = createStore();

    store.setMode('chat');
    expect(store.aiCapabilities().confirmationLevel).toBe('conversational');

    store.setMode('cowork');
    expect(store.aiCapabilities().confirmationLevel).toBe('per-action');

    store.setMode('training');
    expect(store.aiCapabilities().confirmationLevel).toBe('autonomous');
  });

  it('routeRelevance returns mode-specific suggested routes', () => {
    const store = createStore();

    store.setMode('chat');
    expect(store.routeRelevance().suggested).toContain('/chat');

    store.setMode('training');
    expect(store.routeRelevance().suggested).toContain('/pipeline');
  });

  it('modeThemeClass returns correct CSS class', () => {
    const store = createStore();
    store.setMode('cowork');
    expect(store.modeThemeClass()).toBe('mode-cowork');
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npx vitest run store/app.store.spec.ts`
Expected: FAIL — `activeMode` property not found on store

- [ ] **Step 3: Add mode state and computed properties to AppStore**

In `store/app.store.ts`, make these changes:

**Add imports** (top of file):
```typescript
import type { AppMode } from '../shared/utils/mode.types';
import { getModeCapabilities, getRouteRelevance, getContextPills } from '../shared/utils/mode.helpers';
```

**Extend state** (add to initial state object alongside `health`, `gpu`, etc.):
```typescript
activeMode: (localStorage.getItem('sap-ai-workbench-mode') as AppMode) ?? ('chat' as AppMode),
```

**Add computed properties** (append to existing `withComputed` block):
```typescript
aiCapabilities: computed(() => getModeCapabilities(store.activeMode())),
routeRelevance: computed(() => getRouteRelevance(store.activeMode())),
contextPills: computed(() => getContextPills(store.activeMode())),
modeThemeClass: computed(() => `mode-${store.activeMode()}`),
```

**Add method** (append to existing `withMethods` block):
```typescript
setMode(mode: AppMode) {
  patchState(store, { activeMode: mode });
  localStorage.setItem('sap-ai-workbench-mode', mode);
},
```

- [ ] **Step 4: Run test to verify it passes**

Run: `npx vitest run store/app.store.spec.ts`
Expected: PASS (7 tests)

- [ ] **Step 5: Commit**

```bash
git add store/app.store.ts store/app.store.spec.ts
git commit -m "feat(store): add activeMode signal with computed capabilities and persistence"
```

---

## Chunk 2: Mode Switcher Component and Shell Integration

### Task 5: Mode Switcher Component

**Files:**
- Create: `shared/components/mode-switcher/mode-switcher.component.ts`
- Test: `shared/components/mode-switcher/mode-switcher.component.spec.ts`

- [ ] **Step 1: Write the failing test**

```typescript
// shared/components/mode-switcher/mode-switcher.component.spec.ts
import { describe, it, expect } from 'vitest';
import { Injector, runInInjectionContext } from '@angular/core';
import { of } from 'rxjs';
import { ModeSwitcherComponent } from './mode-switcher.component';
import { AppStore } from '../../../store/app.store';
import { ApiService } from '../../../services/api.service';

const mockApiService = {
  get: () => of(null),
  post: () => of(null),
};

describe('ModeSwitcherComponent', () => {
  function setup() {
    const injector = Injector.create({
      providers: [
        AppStore,
        { provide: ApiService, useValue: mockApiService },
      ],
    });
    const store = injector.get(AppStore);
    const component = runInInjectionContext(injector, () => new ModeSwitcherComponent());
    return { component, store };
  }

  it('exposes three modes', () => {
    const { component } = setup();
    expect(component.modes).toHaveLength(3);
    expect(component.modes.map(m => m.key)).toEqual(['chat', 'cowork', 'training']);
  });

  it('reads activeMode from store', () => {
    const { component, store } = setup();
    expect(component.activeMode()).toBe('chat');
    store.setMode('training');
    expect(component.activeMode()).toBe('training');
  });

  it('selectMode calls store.setMode', () => {
    const { component, store } = setup();
    component.selectMode('cowork');
    expect(store.activeMode()).toBe('cowork');
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npx vitest run shared/components/mode-switcher/mode-switcher.component.spec.ts`
Expected: FAIL — module not found

- [ ] **Step 3: Write the component**

```typescript
// shared/components/mode-switcher/mode-switcher.component.ts
import { Component, ChangeDetectionStrategy, inject } from '@angular/core';
import { AppStore } from '../../../store/app.store';
import { MODE_CONFIG } from '../../utils/mode.config';
import type { AppMode } from '../../utils/mode.types';

@Component({
  selector: 'app-mode-switcher',
  standalone: true,
  changeDetection: ChangeDetectionStrategy.OnPush,
  template: `
    <div class="mode-switcher" role="tablist" aria-label="Interaction mode"
         (keydown)="onKeydown($event)">
      @for (mode of modes; track mode.key) {
        <button class="mode-pill"
          role="tab"
          [attr.aria-selected]="activeMode() === mode.key"
          [class.mode-pill--active]="activeMode() === mode.key"
          [attr.tabindex]="activeMode() === mode.key ? 0 : -1"
          (click)="selectMode(mode.key)">
          <ui5-icon [name]="mode.icon" class="mode-icon"></ui5-icon>
          {{ mode.label }}
        </button>
      }
    </div>
  `,
  styles: [`
    .mode-switcher {
      display: flex;
      background: var(--sapShell_Background, rgba(255, 255, 255, 0.06));
      border-radius: 0.5rem;
      padding: 0.1875rem;
      border: 1px solid var(--sapShell_BorderColor, rgba(255, 255, 255, 0.1));
      gap: 0;
    }

    .mode-pill {
      display: flex;
      align-items: center;
      gap: 0.3125rem;
      padding: 0.375rem 0.875rem;
      border-radius: 0.375rem;
      border: none;
      background: transparent;
      color: var(--sapShell_TextColor, rgba(255, 255, 255, 0.5));
      font-size: 0.75rem;
      font-weight: 500;
      cursor: pointer;
      transition: all 200ms ease;
      white-space: nowrap;
    }

    .mode-pill:hover:not(.mode-pill--active) {
      color: var(--sapShell_InteractiveTextColor, rgba(255, 255, 255, 0.8));
      background: var(--sapShell_Hover_Background, rgba(255, 255, 255, 0.04));
    }

    .mode-pill--active {
      background: var(--sapContent_Selected_Background, linear-gradient(135deg, #0a6ed1, #1a8fff));
      color: var(--sapContent_Selected_TextColor, white);
      font-weight: 600;
      box-shadow: 0 2px 8px rgba(10, 110, 209, 0.4);
    }

    .mode-icon {
      font-size: 0.8125rem;
    }
  `],
})
export class ModeSwitcherComponent {
  private readonly store = inject(AppStore);

  readonly activeMode = this.store.activeMode;

  readonly modes: { key: AppMode; label: string; icon: string }[] = [
    { key: 'chat', label: MODE_CONFIG.chat.label, icon: MODE_CONFIG.chat.icon },
    { key: 'cowork', label: MODE_CONFIG.cowork.label, icon: MODE_CONFIG.cowork.icon },
    { key: 'training', label: MODE_CONFIG.training.label, icon: MODE_CONFIG.training.icon },
  ];

  selectMode(mode: AppMode): void {
    this.store.setMode(mode);
  }

  onKeydown(event: KeyboardEvent): void {
    const currentIndex = this.modes.findIndex(m => m.key === this.activeMode());
    let nextIndex = currentIndex;

    if (event.key === 'ArrowRight' || event.key === 'ArrowDown') {
      nextIndex = (currentIndex + 1) % this.modes.length;
      event.preventDefault();
    } else if (event.key === 'ArrowLeft' || event.key === 'ArrowUp') {
      nextIndex = (currentIndex - 1 + this.modes.length) % this.modes.length;
      event.preventDefault();
    }

    if (nextIndex !== currentIndex) {
      this.selectMode(this.modes[nextIndex].key);
    }
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `npx vitest run shared/components/mode-switcher/mode-switcher.component.spec.ts`
Expected: PASS (3 tests)

- [ ] **Step 5: Commit**

```bash
git add shared/components/mode-switcher/
git commit -m "feat(mode): add ModeSwitcherComponent with keyboard navigation"
```

---

### Task 6: Shell Integration — Replace Product Switcher, Add Route Highlighting and Pill Binding

**Files:**
- Modify: `components/shell/shell.component.ts`
  - Template lines 51-64 (shell bar — add mode switcher)
  - Template lines 90-104 (nav island — add mode-suggested class)
  - Template lines 108-122 (pill bar — bind to contextPills)
  - Template lines 256-263 (product switcher popover — remove)
  - Imports (add ModeSwitcherComponent)
  - Styles (add mode-suggested and mode-pill-item styles)

- [ ] **Step 1: Add ModeSwitcherComponent import**

In the `imports` array of `@Component` decorator, add:
```typescript
import { ModeSwitcherComponent } from '../../shared/components/mode-switcher/mode-switcher.component';
```
And add `ModeSwitcherComponent` to the component's `imports` array.

- [ ] **Step 2: Replace product-switch in shell bar template**

Find the `ui5-shellbar` element (around lines 51-64). Replace the `product-switch` slot content or attribute. Add the mode switcher into the header-actions area (around line 65). Insert before the existing header buttons:

```html
<app-mode-switcher></app-mode-switcher>
```

Remove the `product-switch` attribute from `ui5-shellbar` and delete the `productPopover` template block (lines 256-263).

Remove the `productPopover` ViewChild and `onProductSwitchClick`/`switchToApp` methods if no longer needed (or keep `switchToApp` accessible elsewhere if required).

- [ ] **Step 3: Add mode-suggested class to nav island items**

In the nav island template (lines 90-104), add a class binding to each `nav-island-item`:

```html
<button class="nav-island-item"
  [class.active]="activeGroupId() === group.id"
  [class.mode-suggested]="isModeRelevantGroup(group.id)"
  (click)="navigateTo(group.defaultPath)">
```

Add the helper method to the class:

```typescript
isModeRelevantGroup(groupId: TrainingRouteGroupId): boolean {
  const suggested = this.store.routeRelevance().suggested;
  return TRAINING_ROUTE_LINKS
    .filter(link => link.group === groupId)
    .some(link => suggested.includes(link.path));
}
```

- [ ] **Step 4: Add mode-aware styling to nav island**

Add these styles:

```css
.nav-island-item {
  transition: opacity 200ms ease, border-color 200ms ease;
}

.nav-island-item:not(.active):not(.mode-suggested) {
  opacity: 0.35;
}

.nav-island-item.mode-suggested:not(.active) {
  opacity: 1;
  border-left: 3px solid var(--sapLink_Active_Color, #0a6ed1);
}
```

- [ ] **Step 5: Add mode context pills above the route pill bar**

The existing pill bar (lines 108-122) is sub-route navigation — keep it as-is. Add a **new** mode-pills row above it in the template:

```html
<!-- Mode context pills — above existing route pill bar -->
@if (store.contextPills().length > 0) {
  <div class="mode-pill-bar slideUp">
    <div class="pill-track">
      @for (pill of store.contextPills(); track pill.label) {
        <button class="pill-item pill-item--mode" (click)="onModePillClick(pill)">
          <ui5-icon [name]="pill.icon" class="pill-icon"></ui5-icon>
          {{ pill.label }}
        </button>
      }
    </div>
  </div>
}
```

Add the handler method to the class:

```typescript
onModePillClick(pill: ContextPill): void {
  if (pill.action === 'navigate' && pill.target) {
    this.navigateTo(pill.target);
  }
  // Other actions (show-pending, show-preview, show-gpu) are placeholders for future panels
}
```

Add the import for `ContextPill`:
```typescript
import type { ContextPill } from '../../shared/utils/mode.types';
```

Add style for `.mode-pill-bar` (same as `.context-pill-bar` but with slightly smaller font and a subtle left border accent):
```css
.mode-pill-bar {
  position: absolute;
  top: 3.5rem;
  left: 6rem;
  z-index: 9;
}

.pill-item--mode {
  display: flex;
  align-items: center;
  gap: 0.25rem;
  font-size: 0.6875rem;
  opacity: 0.7;
}

.pill-item--mode .pill-icon {
  font-size: 0.75rem;
}
```

- [ ] **Step 6: Bind modeThemeClass to shell**

On the outermost wrapper, use `[ngClass]` to avoid clobbering existing class bindings:

```html
<div class="app-shell" [ngClass]="store.modeThemeClass()">
```

If the element already uses `[class.rtl]` or `[class.app-shell--reduced-motion]`, keep those and add `[ngClass]` alongside — Angular supports both on the same element.

- [ ] **Step 6: Verify visually**

Run the dev server: `npx nx serve angular-shell`
- Open the app in a browser
- Verify the mode switcher appears in the shell bar where the product switcher was
- Click each mode → verify nav island highlighting changes
- Verify keyboard navigation works (arrow keys to cycle modes)

- [ ] **Step 7: Commit**

```bash
git add components/shell/shell.component.ts
git commit -m "feat(shell): integrate mode switcher, route highlighting, and mode theme class"
```

---

## Chunk 3: Route Metadata and Context Pills

### Task 7: Add modeRelevance to Route Definitions

**Files:**
- Modify: `app.navigation.ts` (lines 9-15 for interface, lines 23-60 for route data)
- Test: `app.navigation.spec.ts`

- [ ] **Step 1: Write the failing test**

```typescript
// app.navigation.spec.ts
import { describe, it, expect } from 'vitest';
import { TRAINING_ROUTE_LINKS } from './app.navigation';
import type { AppMode } from './shared/utils/mode.types';

describe('TRAINING_ROUTE_LINKS modeRelevance', () => {
  it('every route has a modeRelevance array', () => {
    for (const link of TRAINING_ROUTE_LINKS) {
      expect(link.modeRelevance, `${link.path} missing modeRelevance`).toBeDefined();
      expect(Array.isArray(link.modeRelevance)).toBe(true);
      expect(link.modeRelevance.length).toBeGreaterThan(0);
    }
  });

  it('chat mode suggests /dashboard and /chat', () => {
    const chatRoutes = TRAINING_ROUTE_LINKS.filter(r => r.modeRelevance.includes('chat'));
    const paths = chatRoutes.map(r => r.path);
    expect(paths).toContain('/dashboard');
    expect(paths).toContain('/chat');
  });

  it('training mode suggests /pipeline and /data-explorer', () => {
    const trainingRoutes = TRAINING_ROUTE_LINKS.filter(r => r.modeRelevance.includes('training'));
    const paths = trainingRoutes.map(r => r.path);
    expect(paths).toContain('/pipeline');
    expect(paths).toContain('/data-explorer');
  });

  it('modeRelevance only contains valid AppMode values', () => {
    const validModes: AppMode[] = ['chat', 'cowork', 'training'];
    for (const link of TRAINING_ROUTE_LINKS) {
      for (const mode of link.modeRelevance) {
        expect(validModes, `${link.path} has invalid mode: ${mode}`).toContain(mode);
      }
    }
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npx vitest run app.navigation.spec.ts`
Expected: FAIL — `modeRelevance` property does not exist

- [ ] **Step 3: Extend TrainingRouteLink and populate all routes**

In `app.navigation.ts`:

**Add import:**
```typescript
import type { AppMode } from './shared/utils/mode.types';
```

**Extend interface** (line 9-15):
```typescript
export interface TrainingRouteLink {
  path: string;
  labelKey: string;
  icon: string;
  group: TrainingRouteGroupId;
  tier: 'primary' | 'secondary' | 'expert';
  modeRelevance: AppMode[];
}
```

**Add modeRelevance to every route entry.** Full assignment for all 29 routes:

```
// home group
/dashboard           → ['chat', 'cowork', 'training']

// data group
/data-explorer       → ['training']
/data-cleaning       → ['training']
/schema-browser      → ['cowork', 'training']
/data-products       → ['training']
/data-quality        → ['cowork', 'training']
/lineage             → ['cowork', 'training']
/vocab-search        → ['training']

// assist group
/chat                → ['chat']
/rag-studio          → ['cowork']
/semantic-search     → ['chat']
/document-ocr        → ['chat', 'cowork']
/pal-workbench       → ['cowork']
/sparql-explorer     → ['cowork']
/analytical-dashboard → ['cowork']
/streaming           → ['chat', 'cowork', 'training']

// operations group
/pipeline            → ['training']
/deployments         → ['training']
/model-optimizer     → ['training']
/registry            → ['training']
/hana-explorer       → ['cowork', 'training']
/compare             → ['cowork', 'training']
/governance          → ['cowork', 'training']
/analytics           → ['cowork', 'training']
/pair-studio         → ['training']
/glossary-manager    → ['training']
/document-linguist   → ['cowork', 'training']
/prompts             → ['chat', 'cowork', 'training']
/workspace           → ['chat', 'cowork', 'training']
```

- [ ] **Step 4: Run test to verify it passes**

Run: `npx vitest run app.navigation.spec.ts`
Expected: PASS (4 tests)

- [ ] **Step 5: Commit**

```bash
git add app.navigation.ts app.navigation.spec.ts
git commit -m "feat(nav): add modeRelevance metadata to all route definitions"
```

---

## Chunk 4: Cowork Plan Component

### Task 8: Cowork Plan Component

**Files:**
- Create: `shared/components/cowork-plan/cowork-plan.component.ts`
- Test: `shared/components/cowork-plan/cowork-plan.component.spec.ts`

- [ ] **Step 1: Write the failing test**

```typescript
// shared/components/cowork-plan/cowork-plan.component.spec.ts
import { describe, it, expect, vi } from 'vitest';
import { Injector, runInInjectionContext } from '@angular/core';
import { CoworkPlanComponent } from './cowork-plan.component';
import type { CoworkPlan } from '../../utils/mode.types';

describe('CoworkPlanComponent', () => {
  const mockPlan: CoworkPlan = {
    id: 'plan-1',
    steps: [
      { label: 'Ingest data', description: 'Load CSV file', status: 'pending' },
      { label: 'Transform', description: 'Clean and chunk', status: 'pending' },
      { label: 'Embed', description: 'Generate embeddings', status: 'pending' },
    ],
    status: 'proposed',
  };

  it('has required plan input and output emitters', () => {
    const injector = Injector.create({ providers: [] });
    const component = runInInjectionContext(injector, () => new CoworkPlanComponent());
    // Verify the component has the expected API shape
    expect(component.plan).toBeDefined();
    expect(component.planApproved).toBeDefined();
    expect(component.planEdited).toBeDefined();
    expect(component.planRejected).toBeDefined();
  });

  it('approve() emits the plan via planApproved', () => {
    const injector = Injector.create({ providers: [] });
    const component = runInInjectionContext(injector, () => new CoworkPlanComponent());
    const spy = vi.fn();
    component.planApproved.subscribe(spy);
    component.approve(mockPlan);
    expect(spy).toHaveBeenCalledWith(mockPlan);
  });

  it('reject() emits the plan via planRejected', () => {
    const injector = Injector.create({ providers: [] });
    const component = runInInjectionContext(injector, () => new CoworkPlanComponent());
    const spy = vi.fn();
    component.planRejected.subscribe(spy);
    component.reject(mockPlan);
    expect(spy).toHaveBeenCalledWith(mockPlan);
  });

  it('edit() emits the plan via planEdited', () => {
    const injector = Injector.create({ providers: [] });
    const component = runInInjectionContext(injector, () => new CoworkPlanComponent());
    const spy = vi.fn();
    component.planEdited.subscribe(spy);
    component.edit(mockPlan);
    expect(spy).toHaveBeenCalledWith(mockPlan);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npx vitest run shared/components/cowork-plan/cowork-plan.component.spec.ts`
Expected: FAIL — module not found

- [ ] **Step 3: Write the component**

```typescript
// shared/components/cowork-plan/cowork-plan.component.ts
import { Component, ChangeDetectionStrategy, input, output } from '@angular/core';
import type { CoworkPlan } from '../../utils/mode.types';

@Component({
  selector: 'app-cowork-plan',
  standalone: true,
  changeDetection: ChangeDetectionStrategy.OnPush,
  template: `
    <div class="cowork-plan" [class]="'cowork-plan--' + plan().status">
      <div class="plan-header">
        <span class="plan-label">
          @switch (plan().status) {
            @case ('proposed') { PROPOSED PLAN }
            @case ('executing') { EXECUTING }
            @case ('completed') { COMPLETED }
            @case ('rejected') { REJECTED }
            @default { PLAN }
          }
        </span>
      </div>

      <div class="plan-steps">
        @for (step of plan().steps; track step.label; let i = $index) {
          <div class="plan-step" [class]="'plan-step--' + step.status">
            <span class="step-indicator">
              @switch (step.status) {
                @case ('completed') { <ui5-icon name="status-positive" class="step-icon step-icon--success"></ui5-icon> }
                @case ('running') { <ui5-icon name="synchronize" class="step-icon step-icon--running"></ui5-icon> }
                @case ('failed') { <ui5-icon name="status-negative" class="step-icon step-icon--failed"></ui5-icon> }
                @default { {{ i + 1 }} }
              }
            </span>
            <div class="step-content">
              <strong>{{ step.label }}</strong>
              <span class="step-desc">{{ step.description }}</span>
            </div>
          </div>
        }
      </div>

      @if (plan().status === 'proposed') {
        <div class="plan-actions">
          <button class="plan-btn plan-btn--primary" (click)="approve(plan())">Approve</button>
          <button class="plan-btn plan-btn--ghost" (click)="edit(plan())">Edit plan</button>
          <button class="plan-btn plan-btn--ghost" (click)="reject(plan())">Reject</button>
        </div>
      }
    </div>
  `,
  styles: [`
    .cowork-plan {
      border-radius: 0.75rem;
      padding: 0.875rem;
      margin: 0.5rem 0;
    }

    .cowork-plan--proposed {
      background: var(--sapInformationBackground, rgba(10, 110, 209, 0.1));
      border: 1px solid var(--sapInformationBorderColor, rgba(10, 110, 209, 0.25));
    }

    .cowork-plan--executing {
      background: var(--sapSuccessBackground, rgba(39, 174, 96, 0.1));
      border: 1px solid var(--sapSuccessBorderColor, rgba(39, 174, 96, 0.25));
    }

    .cowork-plan--completed {
      background: var(--sapSuccessBackground, rgba(39, 174, 96, 0.08));
      border: 1px solid var(--sapSuccessBorderColor, rgba(39, 174, 96, 0.15));
    }

    .cowork-plan--rejected {
      background: var(--sapNeutralBackground, rgba(255, 255, 255, 0.04));
      border: 1px solid var(--sapNeutralBorderColor, rgba(255, 255, 255, 0.1));
      opacity: 0.6;
    }

    .plan-header {
      margin-bottom: 0.5rem;
    }

    .plan-label {
      font-size: 0.75rem;
      font-weight: 600;
      letter-spacing: 0.05em;
      color: var(--sapInformativeColor, #0a6ed1);
    }

    .cowork-plan--executing .plan-label {
      color: var(--sapPositiveColor, #27ae60);
    }

    .plan-steps {
      display: flex;
      flex-direction: column;
      gap: 0.25rem;
    }

    .plan-step {
      display: flex;
      align-items: flex-start;
      gap: 0.5rem;
      padding: 0.25rem 0 0.25rem 0.75rem;
      border-left: 2px solid var(--sapInformationBorderColor, rgba(10, 110, 209, 0.3));
    }

    .step-indicator {
      min-width: 1.25rem;
      text-align: center;
      font-size: 0.8125rem;
    }

    .step-icon {
      font-size: 0.875rem;
    }

    .step-icon--success {
      color: var(--sapPositiveColor, #27ae60);
    }

    .step-icon--running {
      color: var(--sapInformativeColor, #0a6ed1);
      animation: spin 1.2s linear infinite;
    }

    .step-icon--failed {
      color: var(--sapNegativeColor, #e74c3c);
    }

    @keyframes spin { to { transform: rotate(360deg); } }

    .step-content {
      display: flex;
      flex-direction: column;
      font-size: 0.8125rem;
      color: var(--sapTextColor, #e0e0e0);
    }

    .step-desc {
      color: var(--sapContent_LabelColor, rgba(255, 255, 255, 0.5));
      font-size: 0.75rem;
    }

    .plan-actions {
      display: flex;
      gap: 0.5rem;
      margin-top: 0.75rem;
    }

    .plan-btn {
      padding: 0.375rem 1rem;
      border-radius: 0.375rem;
      font-size: 0.75rem;
      font-weight: 600;
      cursor: pointer;
      border: none;
      transition: all 150ms ease;
    }

    .plan-btn--primary {
      background: var(--sapButton_Emphasized_Background, linear-gradient(135deg, #0a6ed1, #1a8fff));
      color: var(--sapButton_Emphasized_TextColor, white);
    }

    .plan-btn--ghost {
      background: var(--sapButton_Lite_Background, rgba(255, 255, 255, 0.08));
      color: var(--sapButton_Lite_TextColor, rgba(255, 255, 255, 0.7));
      border: 1px solid var(--sapButton_Lite_BorderColor, rgba(255, 255, 255, 0.15));
    }

    .plan-btn--ghost:hover {
      background: var(--sapButton_Lite_Hover_Background, rgba(255, 255, 255, 0.12));
    }
  `],
})
export class CoworkPlanComponent {
  plan = input.required<CoworkPlan>();

  planApproved = output<CoworkPlan>();
  planEdited = output<CoworkPlan>();
  planRejected = output<CoworkPlan>();

  approve(plan: CoworkPlan): void {
    this.planApproved.emit(plan);
  }

  edit(plan: CoworkPlan): void {
    this.planEdited.emit(plan);
  }

  reject(plan: CoworkPlan): void {
    this.planRejected.emit(plan);
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `npx vitest run shared/components/cowork-plan/cowork-plan.component.spec.ts`
Expected: PASS (3 tests)

- [ ] **Step 5: Commit**

```bash
git add shared/components/cowork-plan/
git commit -m "feat(cowork): add CoworkPlanComponent with approve/edit/reject flow"
```

---

## Chunk 5: End-to-End Verification

### Task 9: Integration Verification

- [ ] **Step 1: Run all new tests together**

```bash
npx vitest run shared/utils/mode.types.spec.ts shared/utils/mode.config.spec.ts shared/utils/mode.helpers.spec.ts store/app.store.spec.ts shared/components/mode-switcher/mode-switcher.component.spec.ts shared/components/cowork-plan/cowork-plan.component.spec.ts app.navigation.spec.ts
```

Expected: All tests pass

- [ ] **Step 2: Run full project test suite**

```bash
npx nx test angular-shell
```

Expected: No regressions in existing tests

- [ ] **Step 3: Manual verification checklist**

Start dev server: `npx nx serve angular-shell`

**Mode switcher UI:**
1. Mode switcher appears in shell bar (where product switcher was)
2. Keyboard: Tab to mode switcher, press ArrowRight to cycle through modes

**Route highlighting (nav island highlights groups, not individual routes — groups are highlighted when any of their routes are mode-suggested):**
3. Click "Training" → data + operations groups highlight (contain /pipeline, /data-explorer, etc.), assist group dims
4. Click "Chat" → assist + home groups highlight (contain /chat, /dashboard), data + operations groups dim
5. Click "Cowork" → assist + operations groups highlight (contain /rag-studio, /analytical-dashboard, etc.)
6. All dimmed nav groups remain clickable (navigate works)

**Mode context pills:**
7. Mode pill bar appears above route pill bar with mode-specific quick actions
8. Chat mode shows "Recent chats" + "Help" pills; Training mode shows "Active jobs" + "GPU status" pills

**Persistence:**
9. Refresh page → mode persists (check localStorage `sap-ai-workbench-mode`)
10. Clear localStorage, refresh → defaults to Chat mode

**Shared context:**
11. Open chat, send a message, switch to Training mode → chat history still visible when navigating back to /chat

**Cowork flow:**
12. In Cowork mode, verify CoworkPlanComponent renders when a plan message appears in chat stream (requires backend integration — verify component renders standalone with mock data for now)

**AI behavior (requires backend):**
13. In Chat mode, verify requests include `conversational` confirmation level
14. In Training mode, verify requests include `autonomous` confirmation level

- [ ] **Step 4: Final commit**

```bash
git add -A
git commit -m "feat: complete three-mode switcher (Chat/Cowork/Training) integration"
```
