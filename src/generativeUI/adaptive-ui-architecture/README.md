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
| Layer 2: Modeling | ✅ **Complete** | User profile building with inference |
| Layer 3: Adaptation | ✅ **Complete** | Decision engine with coordinator |
| Layer 4: Components | ✅ **Complete** | Adaptive table, filter, layout |
| Layer 5: Feedback | ✅ **Complete** | Feedback collection & model refinement |

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
import {
  contextProvider,
  captureService,
  createCaptureHooks,
  modelingService,
  autoModeler
} from './core';

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

// 3. Capture interactions (auto-modeler updates user profile automatically)
capture.captureFilter('status', 'active');
capture.captureSort('date', 'desc');

// 4. Get learned user preferences
const userModel = modelingService.getModel('user-123');
console.log('Expertise:', userModel?.expertise.level);
console.log('Frequent filters:', userModel?.filters.frequentFilters);
console.log('Default sort:', userModel?.tables.defaultSort);

// 5. Subscribe to model updates
modelingService.subscribe('user-123', (model) => {
  console.log('Model confidence:', model.confidence);
  console.log('Layout density:', model.layout.density);
});

// 6. Query capture history for custom analysis
const recentEvents = captureService.getRecentEvents(30);
const filterPatterns = captureService.getFilterPatterns('main-filter');
```

## Phase 2 Deliverables (Complete)

### Modeling Service (`core/modeling/`)
- `types.ts` — Complete user model types
- `modeling-service.ts` — Full implementation
  - User profile management
  - Preference inference
  - Model persistence to localStorage
  - Cross-device model merging
  - Confidence calculation
  - Subscription API
- `auto-modeler.ts` — Automatic capture-to-model pipeline
  - Batched event processing
  - Configurable update intervals
  - Privacy-respecting processing

### Inference Modules (`core/modeling/inference/`)
- `expertise-inference.ts` — Multi-signal expertise detection
  - Keyboard shortcut usage
  - Advanced feature usage
  - Task velocity
  - Exploration depth
  - Error recovery patterns
  - Filter complexity
- `preference-inference.ts` — UI preference extraction
  - Layout density from expand/collapse patterns
  - Table sort preferences
  - Column visibility tracking
  - Page size preferences
  - Filter frequency analysis
  - Auto-apply detection

### Tests
- `modeling-service.test.ts` — Service tests
- `expertise-inference.test.ts` — Inference tests

## Phase 3 Deliverables (Complete)

### Adaptation Coordinator (`core/adaptation/coordinator.ts`)
- Connects Context + Model → Engine → UI
- Real-time CSS variable generation
- User override management
- Debounced change handling
- SSR-compatible variable export

### Extended Rules (`core/adaptation/rules/`)
- `accessibility-rules.ts` — WCAG compliance (non-overridable)
  - Reduced motion
  - High contrast
  - Keyboard-only navigation
  - Touch target sizing
  - Screen reader optimization
- `data-rules.ts` — Data-based adaptation
  - Large dataset optimization
  - Empty state handling
  - Sensitive data protection
  - Real-time data display
- `temporal-rules.ts` — Time-based adaptation
  - Evening mode
  - Long session comfort
  - End of day workflows
  - Weekend mode

### Framework Integrations
- `react/use-adaptation.ts` — React hooks
  - `useAdaptation()` — Full decision
  - `useAdaptiveLayout()` — CSS-ready values
  - `useAdaptiveInteraction()` — Animation styles
  - `useAdaptationOverrides()` — Override management
- `angular/adaptation.service.ts` — Angular service
  - RxJS observables
  - CSS helpers
  - Override management

### CSS Variables Generated
```css
--adaptive-spacing-unit: 8px;
--adaptive-spacing-xs: 4px;
--adaptive-spacing-sm: 8px;
--adaptive-spacing-md: 16px;
--adaptive-spacing-lg: 24px;
--adaptive-spacing-xl: 32px;
--adaptive-grid-columns: 12;
--adaptive-density-scale: 1;
--adaptive-touch-target-min: 44px;
--adaptive-animation-duration: 150ms;
--adaptive-transition-duration: 200ms;
--adaptive-hover-delay: 200ms;
--adaptive-tooltip-delay: 500ms;
--adaptive-sidebar-width: 280px;
```

### Tests
- `adaptation-coordinator.test.ts` — Coordinator tests
- `rules.test.ts` — Rule priority and condition tests

## Phase 4 Deliverables (Complete)

### React Components (`components/react/`)

#### AdaptiveTable
- Learns column preferences from user behavior
- Adapts density based on device/preference
- Shows suggested filters from capture patterns
- Keyboard navigation (Arrow keys, Enter to sort)
- WCAG AA compliant (aria-sort, scope="col", focus states)

#### AdaptiveFilter
- Shows frequently used filters first
- Suggests filter values from learned patterns
- Auto-apply based on user preference
- Collapsible with proper ARIA states
- Touch-friendly targets

#### AdaptiveLayout
- Responsive grid with adaptive columns
- Collapsible sidebar with learned state
- Ordered panels based on user preferences
- Proper landmarks (main, aside, nav)

#### AdaptiveGrid & AdaptiveCard
- Density-aware spacing
- Collapsible cards with ARIA
- CSS variable integration

### CSS Architecture
- Uses CSS custom properties from Coordinator
- 8px grid spacing system
- Density variants (compact/comfortable/spacious)
- Reduced motion support
- High contrast support
- Mobile-first responsive

### Tests
- `adaptive-table.test.tsx` — Table accessibility and interaction tests

## Phase 5 Deliverables (Complete)

### Feedback Service (`core/feedback/`)

#### Types (`types.ts`)
- `FeedbackEvent` — Structured feedback records
- `FeedbackPrompt` — Configurable feedback triggers
- `RefinementSuggestion` — Model improvement suggestions

#### Feedback Service (`feedback-service.ts`)
- Records user feedback (thumbs, rating, choice, correction)
- Tracks prompt display frequency (prevent fatigue)
- Aggregates feedback by setting
- LocalStorage persistence
- Subscription API

#### Model Refinement (`model-refinement.ts`)
- Analyzes feedback patterns
- Suggests model improvements
- Auto-applies high-confidence refinements
- Tracks correction preferences

### React Components

#### FeedbackWidget
- Thumbs up/down feedback
- Accessible (ARIA roles, focus states)
- Toast/popover/inline variants

#### RatingFeedback
- 1-5 star rating
- Keyboard navigable
- Visual hover states

#### ChoiceFeedback
- A/B choice between options
- Marks current value
- Records preferred alternatives

### Default Prompts
- Layout density satisfaction
- Filter suggestion usefulness
- Page size preference
- Low-confidence overall rating

### Continuous Learning Loop

```
User Action → Capture → Model → Decisions → Components
     ↑                                        ↓
     │                                   Feedback ←── NEW!
     │                                        ↓
     └──────────── Model Refinement ──────────┘
```

## License

SAP Internal — Not for external distribution.

