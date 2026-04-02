# @sap-oss/sac-webcomponents-ngx

Angular libraries and SAC custom-widget assets for SAP Analytics Cloud integrations.

The package publishes a single public namespace with secondary entry points under `@sap-oss/sac-webcomponents-ngx/*`. It also ships the TypeScript SDK bundle and the packaged SAC AI widget descriptor.

## Package Contract

Install the package once:

```bash
npm install @sap-oss/sac-webcomponents-ngx
```

Published entry points:

| Entry point | Purpose |
| --- | --- |
| `@sap-oss/sac-webcomponents-ngx/sdk` | Standalone TypeScript REST client |
| `@sap-oss/sac-webcomponents-ngx/core` | Core config, auth, events, and shared SAC types |
| `@sap-oss/sac-webcomponents-ngx/chart` | Chart components |
| `@sap-oss/sac-webcomponents-ngx/table` | Table components |
| `@sap-oss/sac-webcomponents-ngx/input` | Input components |
| `@sap-oss/sac-webcomponents-ngx/planning` | Planning services and components |
| `@sap-oss/sac-webcomponents-ngx/datasource` | Datasource services |
| `@sap-oss/sac-webcomponents-ngx/widgets` | Container and layout widgets |
| `@sap-oss/sac-webcomponents-ngx/advanced` | KPI, forecast, geomap, and advanced widgets |
| `@sap-oss/sac-webcomponents-ngx/builtins` | Built-in utility services |
| `@sap-oss/sac-webcomponents-ngx/calendar` | Calendar services |

No legacy `@nucleus/*` or `@sap-oss/sac-ngx*` import paths are supported.

## Angular Quick Start

Register the SAC core module once at the application root:

```typescript
import { NgModule } from '@angular/core';
import { BrowserModule } from '@angular/platform-browser';
import { SacCoreModule } from '@sap-oss/sac-webcomponents-ngx/core';

@NgModule({
  imports: [
    BrowserModule,
    SacCoreModule.forRoot({
      apiUrl: 'https://tenant.sapanalytics.cloud',
      authToken: 'bearer-token',
      tenant: 'my-tenant'
    })
  ]
})
export class AppModule {}
```

Use any secondary entry point directly:

```typescript
import { Component } from '@angular/core';
import { SacChartModule } from '@sap-oss/sac-webcomponents-ngx/chart';
import { ChartType } from '@sap-oss/sac-webcomponents-ngx/core';
import { SacDataSourceService } from '@sap-oss/sac-webcomponents-ngx/datasource';

@Component({
  selector: 'app-dashboard',
  standalone: true,
  imports: [SacChartModule],
  template: `
    <sac-chart
      [chartType]="ChartType.Bar"
      [dataSource]="dataSource">
    </sac-chart>
  `
})
export class DashboardComponent {
  readonly ChartType = ChartType;
  readonly dataSource = this.dataSources.create('MODEL_ID');

  constructor(private readonly dataSources: SacDataSourceService) {}
}
```

The datasource wrapper and Angular services now share one transport layer for auth propagation, timeout handling, retry rules, and success/error parsing.

## SDK Usage

The SDK is available as a direct package export:

```typescript
import { SACRestAPIClient } from '@sap-oss/sac-webcomponents-ngx/sdk';

const client = new SACRestAPIClient({
  baseUrl: 'https://tenant.sapanalytics.cloud',
  authToken: 'bearer-token'
});
```

The client supports dynamic auth updates, configurable API base paths, and correct handling for empty-body responses such as `204 No Content`.

## SAC AI Widget

The repository also builds a SAC custom widget bundle for Designer import. The widget renders chart, table, and KPI states and keeps one shared AI session thread between the chat panel and the data widget.

Build and package commands:

```bash
npm run build:widget
npm run verify:widget-harness
npm run package
```

Generated artifacts:

| Artifact | Path |
| --- | --- |
| Widget bundle | `dist/sac-ai-widget/widget.js` |
| Widget descriptor copy | `dist/sac-ai-widget/widget.json` |
| Uploadable SAC package | `dist/releases/widget.zip` |

Import `dist/releases/widget.zip` in SAC Designer through `Custom Widget > Import`.

Widget properties from [`widget.json`](./widget.json):

| Property | Purpose |
| --- | --- |
| `capBackendUrl` | CAP LLM Plugin backend URL |
| `tenantUrl` | SAC tenant URL |
| `modelId` | Default datasource model ID |
| `widgetType` | Initial mode: `chart`, `table`, or `kpi` |
| `sacBearerToken` | SAC session bearer token |

When live table or KPI bindings are incomplete, the widget falls back to a labeled preview state instead of rendering an empty shell.

## Build And Verification

Local commands:

```bash
npm run build
npm run build:widget
npm run lint
npm test
npm run verify:pack
npm run release:check
```

What each command does:

| Command | Purpose |
| --- | --- |
| `npm run build` | Builds the SDK plus all Angular secondary entry points |
| `npm run build:widget` | Builds the SAC AI widget bundle |
| `npm run verify:widget-harness` | Runs the Playwright browser smoke harness against the built widget bundle |
| `npm run lint` | Runs the ESLint gate |
| `npm test` | Runs the Vitest suite |
| `npm run verify:pack` | Verifies exported entry points and runs `npm pack --dry-run` |
| `npm run package` | Creates `dist/releases/widget.zip` |
| `npm run release:check` | Runs lint, tests, pack verification, and widget packaging |

CI uses the same gates in [`.github/workflows/ci-sac-ai-widget.yml`](../../../.github/workflows/ci-sac-ai-widget.yml).

## Release Notes

Maintainer release steps are documented in [RELEASE.md](./RELEASE.md).

The npm tarball intentionally includes only:

- `dist/**`
- `README.md`
- `widget.json`

Source libraries, Angular cache directories, and local build residue are excluded from the published package.

## Repository Layout

```text
sac-webcomponents-ngx/
├── libs/
│   ├── sac-sdk/
│   ├── sac-core/
│   ├── sac-chart/
│   ├── sac-table/
│   ├── sac-input/
│   ├── sac-planning/
│   ├── sac-datasource/
│   ├── sac-widgets/
│   ├── sac-advanced/
│   ├── sac-builtins/
│   ├── sac-calendar/
│   └── sac-ai-widget/
├── dist/
├── scripts/
├── widget.json
└── package.json
```

## License

MIT
