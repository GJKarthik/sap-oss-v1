# Three-Mode Switcher — Design Spec

**Date**: 2026-04-09
**Codebase**: training-webcomponents-ngx
**Status**: Implemented

## Problem

The SAP AI Workbench treats every interaction identically. Whether a user wants to ask a question, collaborate on a data pipeline, or kick off autonomous training, the AI uses the same system prompt, the same navigation layout, and the same confirmation behavior. This forces users to constantly re-explain their intent.

## Solution

A **three-mode switcher** (Chat / Cowork / Training) that lets users signal their intent. A single `activeMode` signal cascades through the entire UI:

- **Chat**: Conversational. AI explains, answers, guides. Full confirmation required.
- **Cowork**: Collaborative. AI proposes structured plans, user approves/edits/rejects. Confirms destructive actions only.
- **Training**: Autonomous. AI runs pipelines end-to-end, reports results. No confirmation prompts.

## Scope

### In scope
- Segmented mode switcher in shell bar (replaces product switcher)
- Route relevance highlighting (nav groups dim/brighten based on mode)
- Per-route relevance overrides (14 of 29 routes have custom scores)
- Mode-specific context pills (quick actions above content area)
- Cowork plan card with approve/edit/reject flow
- Mode-specific system prompt prefix and confirmation level
- localStorage persistence, defaults to `chat`
- Keyboard navigation (Arrow keys cycle modes)

### Out of scope
- Backend AI behavior changes (system prompt is client-only metadata for now)
- Mode-aware chat history partitioning (shared session across modes)
- Mode analytics/telemetry


---

## Architecture

### Signal Flow

```
User clicks mode tab
  → store.setMode('cowork')
    → patchState({ activeMode: 'cowork' })
    → localStorage.setItem('sap-ai-mode', 'cowork')
    → Computed signals auto-update:
        modeConfig()            → full ModeConfig object
        modePills()             → [proposePlan, reviewChanges, debugIssue]
        modeSystemPrompt()      → "You are a collaborative AI partner…"
        modeConfirmationLevel() → 'destructive-only'
    → Shell template re-renders:
        Nav group opacities recalculate
        Per-route opacities recalculate (14 routes have overrides)
        Context pills bar updates above router-outlet
```

### Data Model

```typescript
type AppMode = 'chat' | 'cowork' | 'training';

interface ModeConfig {
  id: AppMode;
  labelKey: string;
  icon: string;
  descriptionKey: string;
  systemPromptPrefix: string;
  confirmationLevel: 'always' | 'destructive-only' | 'never';
  groupRelevance: Record<string, number>;  // 0.0–1.0 per nav group
}

type ModeRelevance = Partial<Record<AppMode, number>>;
```

### Mode Configuration

| Mode | Icon | Confirmation | Home | Assist | Data | Ops |
|------|------|-------------|------|--------|------|-----|
| Chat | `discussion-2` | `always` | 1.0 | 1.0 | 0.6 | 0.4 |
| Cowork | `collaborate` | `destructive-only` | 0.8 | 0.8 | 1.0 | 1.0 |
| Training | `process` | `never` | 0.4 | 0.6 | 0.8 | 1.0 |

### Context Pills

| Pill | Icon | Modes |
|------|------|-------|
| Ask a Question | `question-mark` | Chat |
| Explain This | `hint` | Chat |
| Propose Plan | `task` | Cowork |
| Review Changes | `compare` | Cowork |
| Run Pipeline | `process` | Training |
| Show Metrics | `chart-table-view` | Training |
| Debug Issue | `wrench` | Cowork + Training |

### Route Relevance Overrides (14/29 routes)

| Route | Chat | Cowork | Training |
|-------|------|--------|----------|
| `/chat` | 1.0 | 0.9 | 0.5 |
| `/rag-studio` | — | 1.0 | 0.8 |
| `/semantic-search` | 1.0 | — | — |
| `/pipeline` | — | 0.9 | 1.0 |
| `/deployments` | — | — | 1.0 |
| `/model-optimizer` | — | 1.0 | 1.0 |
| `/data-cleaning` | — | 1.0 | 0.9 |
| `/data-products` | — | 1.0 | 1.0 |
| `/data-quality` | — | — | 1.0 |
| `/pal-workbench` | — | 0.9 | 1.0 |
| `/analytical-dashboard` | — | — | 0.9 |
| `/streaming` | — | — | 1.0 |
| `/compare` | — | 1.0 | — |
| `/prompts` | 1.0 | 0.8 | — |

---

## Components

### ModeSwitcherComponent

Segmented control in shellbar `startContent` slot. Glass indicator slides with spring easing. ARIA `role="tablist"`, keyboard Arrow key cycling.

### CoworkPlanComponent

Plan card with numbered steps, status-colored left border (blue→green→orange), Approve/Edit/Reject buttons when `status === 'proposed'`.

---

## Files

| Action | Path (relative to `apps/angular-shell/src/app/`) |
|--------|--------------------------------------------------|
| NEW | `shared/utils/mode.types.ts` |
| NEW | `shared/utils/mode.config.ts` |
| NEW | `shared/utils/mode.helpers.ts` |
| NEW | `shared/components/mode-switcher/mode-switcher.component.ts` |
| NEW | `shared/components/cowork-plan/cowork-plan.component.ts` |
| EDIT | `store/app.store.ts` |
| EDIT | `components/shell/shell.component.ts` |
| EDIT | `app.navigation.ts` |
| EDIT | `assets/i18n/en.json` |

---

## Verification

- [x] Mode switching updates signal, nav highlights, and context pills
- [x] Persistence survives page refresh; defaults to `chat`
- [x] Cowork plan card renders with approve/edit/reject flow
- [x] AI behavior metadata changes per mode
- [x] Keyboard accessible (arrow keys cycle modes)
- [x] Build: `nx build angular-shell` ✅
- [x] Tests: 32 suites, 374 tests ✅