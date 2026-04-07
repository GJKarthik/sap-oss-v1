import { CommonModule } from '@angular/common';
import { Component, CUSTOM_ELEMENTS_SCHEMA, DestroyRef, inject } from '@angular/core';
import { takeUntilDestroyed } from '@angular/core/rxjs-interop';

import { MoonshotRunResponse } from '../../core/models/moonshot.model';
import { MoonshotApiService } from '../../core/services/moonshot-api.service';

@Component({
  selector: 'app-runs',
  standalone: true,
  imports: [CommonModule],
  schemas: [CUSTOM_ELEMENTS_SCHEMA],
  template: `
    <section class="page">
      <div>
        <ui5-title level="H2">Trigger Moonshot Run</ui5-title>
        <p class="subtitle">Calls POST /api/moonshot/runs and persists run metadata through OData.</p>
      </div>

      <ui5-card>
        <ui5-card-header slot="header" title-text="Run Request"></ui5-card-header>
        <div class="card-content form-grid">
          <label class="field">
            <span>run_id</span>
            <ui5-input [value]="runId" (input)="runId = valueFromEvent($event)" placeholder="run id"></ui5-input>
          </label>

          <label class="field">
            <span>test_config_id</span>
            <ui5-select [value]="testConfigId" (change)="testConfigId = valueFromEvent($event)">
              <ui5-option *ngFor="let id of testConfigIds" [value]="id">{{ id }}</ui5-option>
            </ui5-select>
          </label>

          <label class="field">
            <span>connector</span>
            <ui5-select [value]="connector" (change)="connector = valueFromEvent($event)">
              <ui5-option *ngFor="let c of connectors" [value]="c">{{ c }}</ui5-option>
            </ui5-select>
          </label>

          <label class="field inline">
            <span>dry_run</span>
            <ui5-checkbox [checked]="dryRun" (change)="dryRun = checkedFromEvent($event)">Enable dry run</ui5-checkbox>
          </label>
        </div>
        <div class="actions">
          <ui5-button design="Emphasized" icon="media-play" (click)="triggerRun()" [disabled]="submitting">
            {{ submitting ? 'Running...' : 'Run Moonshot Test' }}
          </ui5-button>
          <ui5-button design="Transparent" icon="refresh" (click)="reloadCatalog()">Reload Options</ui5-button>
        </div>
      </ui5-card>

      <ui5-message-strip *ngIf="errorMessage" design="Negative">{{ errorMessage }}</ui5-message-strip>

      <ui5-card *ngIf="runResponse">
        <ui5-card-header slot="header" title-text="Run Result"></ui5-card-header>
        <div class="card-content" *ngIf="runResponse.status === 'success' && runResponse.run as run; else failedRun">
          <div class="result-row"><span>run_id</span><strong>{{ run.run_id }}</strong></div>
          <div class="result-row"><span>test_config_id</span><strong>{{ run.test_config_id }}</strong></div>
          <div class="result-row"><span>connector</span><strong>{{ run.connector }}</strong></div>
          <div class="result-row"><span>result_path</span><code>{{ run.result_path }}</code></div>
          <div class="result-row"><span>tests_executed</span><strong>{{ run.tests_executed }}</strong></div>
          <div class="result-row"><span>dry_run_prompts</span><strong>{{ run.dry_run_prompts }}</strong></div>
          <div class="result-row"><span>duration_seconds</span><strong>{{ run.duration_seconds }}</strong></div>
          <div class="result-row"><span>persisted_to_odata</span><strong>{{ runResponse.persisted_to_odata ? 'yes' : 'no' }}</strong></div>
        </div>
        <ng-template #failedRun>
          <div class="card-content">
            <p>Run failed.</p>
            <pre>{{ runResponse | json }}</pre>
          </div>
        </ng-template>
      </ui5-card>
    </section>
  `,
  styles: [
    `
      .page {
        display: grid;
        gap: 1rem;
      }

      .subtitle {
        margin: 0.4rem 0 0;
        color: var(--sapContent_LabelColor);
      }

      .card-content {
        padding: 1rem;
      }

      .form-grid {
        display: grid;
        grid-template-columns: repeat(auto-fit, minmax(220px, 1fr));
        gap: 0.9rem;
      }

      .field {
        display: grid;
        gap: 0.35rem;
      }

      .field span {
        font-size: 0.78rem;
        color: var(--sapContent_LabelColor);
      }

      .inline {
        align-items: end;
      }

      .actions {
        padding: 0 1rem 1rem;
        display: flex;
        gap: 0.6rem;
      }

      .result-row {
        display: flex;
        justify-content: space-between;
        gap: 1rem;
        margin-bottom: 0.45rem;
      }

      pre {
        margin: 0;
        white-space: pre-wrap;
        word-break: break-word;
      }
    `,
  ],
})
export class RunsComponent {
  private readonly destroyRef = inject(DestroyRef);
  private readonly moonshot = inject(MoonshotApiService);

  runId = this.defaultRunId();
  testConfigId = '';
  connector = '';
  dryRun = true;

  testConfigIds: string[] = [];
  connectors: string[] = [];

  submitting = false;
  errorMessage = '';
  runResponse: MoonshotRunResponse | null = null;

  constructor() {
    this.reloadCatalog();
  }

  reloadCatalog(): void {
    this.moonshot
      .getTestConfigs()
      .pipe(takeUntilDestroyed(this.destroyRef))
      .subscribe((tests) => {
        this.testConfigIds = tests.test_config_ids ?? [];
        if (!this.testConfigId && this.testConfigIds.length > 0) {
          this.testConfigId = this.testConfigIds[0];
        }
      });

    this.moonshot
      .getConfigSummary()
      .pipe(takeUntilDestroyed(this.destroyRef))
      .subscribe((summary) => {
        this.connectors = summary.connectors ?? [];
        if (!this.connector && this.connectors.length > 0) {
          this.connector = this.connectors[0];
        }
      });
  }

  triggerRun(): void {
    this.errorMessage = '';
    this.runResponse = null;

    if (!this.runId || !this.testConfigId || !this.connector) {
      this.errorMessage = 'run_id, test_config_id, and connector are required.';
      return;
    }

    this.submitting = true;
    this.moonshot
      .triggerRun({
        run_id: this.runId,
        test_config_id: this.testConfigId,
        connector: this.connector,
        dry_run: this.dryRun,
      })
      .pipe(takeUntilDestroyed(this.destroyRef))
      .subscribe({
        next: (response) => {
          this.runResponse = response;
          this.submitting = false;
        },
        error: (error: Error) => {
          this.errorMessage = error.message;
          this.submitting = false;
        },
      });
  }

  valueFromEvent(event: Event): string {
    const target = event.target as { value?: string };
    return target.value ?? '';
  }

  checkedFromEvent(event: Event): boolean {
    const target = event.target as { checked?: boolean };
    return !!target.checked;
  }

  private defaultRunId(): string {
    const now = new Date();
    const stamp = `${now.getFullYear()}${String(now.getMonth() + 1).padStart(2, '0')}${String(now.getDate()).padStart(2, '0')}-${String(now.getHours()).padStart(2, '0')}${String(now.getMinutes()).padStart(2, '0')}${String(now.getSeconds()).padStart(2, '0')}`;
    return `run-${stamp}`;
  }
}
