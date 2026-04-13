# Workspace App

Angular 20 developer workspace and sample shell for the UI5 Web Components for Angular library.

## Overview

This app demonstrates the full UI5 Angular wrapper library in a production-style shell with:
- **Side navigation** (ui5-side-navigation) with dynamic nav links from workspace settings
- **Spotlight search** (Cmd/K) with pinning, recent pages, and ranked search
- **Learn-path onboarding** across generative, Joule, components, and MCP routes
- **i18n** for 7 languages (en, de, fr, zh, ko, ar, id)
- **Theming** with Horizon and Horizon Dark
- **Lazy-loaded feature modules** for forms, Joule, collaboration, generative UI, model catalog, MCP tools, OCR, readiness, and workspace settings

## Development

```bash
# From the monorepo root
yarn start:workspace   # http://localhost:4200
```

The dev server proxies `/ag-ui/*` and other backend routes via `proxy.conf.js`.

## Architecture

- **Bootstrap**: Standalone `bootstrapApplication` via `app.config.ts`
- **Shell**: `AppComponent` (standalone) hosts shellbar, sidebar, router-outlet, and spotlight
- **Home**: `MainComponent` (standalone) with configurable widget grid
- **Features**: Lazy-loaded NgModules under `modules/`
- **Core services**: WorkspaceService, QuickAccessService, LearnPathService, ExperienceHealthService

## Testing

```bash
yarn nx test workspace
```
