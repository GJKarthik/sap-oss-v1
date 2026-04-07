import { CommonModule } from '@angular/common';
import { Component, CUSTOM_ELEMENTS_SCHEMA, DestroyRef, inject } from '@angular/core';
import { takeUntilDestroyed } from '@angular/core/rxjs-interop';

import { MoonshotStoredRun } from '../../core/models/moonshot.model';
import { MoonshotApiService } from '../../core/services/moonshot-api.service';

@Component({
  selector: 'app-history',
  standalone: true,
  imports: [CommonModule],
  schemas: [CUSTOM_ELEMENTS_SCHEMA],
  template: `
    <section class="page">
      <div class="header-row">
        <div>
          <ui5-title level="H2">Run History</ui5-title>
          <p class="subtitle">Data from /api/moonshot/runs (OData-backed with fallback mode).</p>
        </div>
        <ui5-button design="Emphasized" icon="refresh" (click)="refresh()" [disabled]="loading">
          {{ loading ? 'Loading...' : 'Refresh' }}
        </ui5-button>
      </div>

      <ui5-card>
        <ui5-card-header slot="header" title-text="Runs"></ui5-card-header>
        <div class="card-content">
          <ui5-table>
            <ui5-table-column slot="columns"><span>Run ID</span></ui5-table-column>
            <ui5-table-column slot="columns"><span>Test Config</span></ui5-table-column>
            <ui5-table-column slot="columns"><span>Connector</span></ui5-table-column>
            <ui5-table-column slot="columns"><span>Status</span></ui5-table-column>
            <ui5-table-column slot="columns"><span>Duration (s)</span></ui5-table-column>
            <ui5-table-column slot="columns"><span>Finished</span></ui5-table-column>
            <ui5-table-column slot="columns"><span>Actions</span></ui5-table-column>

            <ui5-table-row *ngFor="let run of runs">
              <ui5-table-cell>{{ run.run_id }}</ui5-table-cell>
              <ui5-table-cell>{{ run.test_config_id }}</ui5-table-cell>
              <ui5-table-cell>{{ run.connector }}</ui5-table-cell>
              <ui5-table-cell>{{ run.status }}</ui5-table-cell>
              <ui5-table-cell>{{ run.duration_seconds }}</ui5-table-cell>
              <ui5-table-cell>{{ formatUnix(run.end_time_unix) }}</ui5-table-cell>
              <ui5-table-cell>
                <ui5-button design="Transparent" icon="inspect" (click)="selectRun(run)">View</ui5-button>
              </ui5-table-cell>
            </ui5-table-row>
          </ui5-table>

          <p class="empty" *ngIf="runs.length === 0">No runs found.</p>
        </div>
      </ui5-card>

      <ui5-card *ngIf="selectedRun">
        <ui5-card-header slot="header" title-text="Run Detail"></ui5-card-header>
        <div class="card-content">
          <div class="row"><span>run_id</span><strong>{{ selectedRun.run_id }}</strong></div>
          <div class="row"><span>test_config_id</span><strong>{{ selectedRun.test_config_id }}</strong></div>
          <div class="row"><span>connector</span><strong>{{ selectedRun.connector }}</strong></div>
          <div class="row"><span>status</span><strong>{{ selectedRun.status }}</strong></div>
          <div class="row"><span>result_path</span><code>{{ selectedRun.result_path }}</code></div>
          <div class="row"><span>start_time</span><span>{{ formatUnix(selectedRun.start_time_unix) }}</span></div>
          <div class="row"><span>end_time</span><span>{{ formatUnix(selectedRun.end_time_unix) }}</span></div>
          <div class="row"><span>dry_run_prompts</span><span>{{ selectedRun.dry_run_prompts }}</span></div>
        </div>
      </ui5-card>
    </section>
  `,
  styles: [
    `
      .page {
        display: grid;
        gap: 1rem;
      }

      .header-row {
        display: flex;
        justify-content: space-between;
        gap: 1rem;
        align-items: center;
      }

      .subtitle {
        margin: 0.4rem 0 0;
        color: var(--sapContent_LabelColor);
      }

      .card-content {
        padding: 0.9rem;
      }

      .row {
        display: flex;
        justify-content: space-between;
        gap: 1rem;
        margin-bottom: 0.5rem;
      }

      .empty {
        color: var(--sapContent_LabelColor);
        font-style: italic;
      }

      @media (max-width: 760px) {
        .header-row {
          flex-direction: column;
          align-items: flex-start;
        }
      }
    `,
  ],
})
export class HistoryComponent {
  private readonly destroyRef = inject(DestroyRef);
  private readonly moonshot = inject(MoonshotApiService);

  loading = false;
  runs: MoonshotStoredRun[] = [];
  selectedRun: MoonshotStoredRun | null = null;

  constructor() {
    this.refresh();
  }

  refresh(): void {
    this.loading = true;
    this.moonshot
      .listRuns()
      .pipe(takeUntilDestroyed(this.destroyRef))
      .subscribe({
        next: (result) => {
          this.runs = result.runs ?? [];
          this.loading = false;
        },
        error: () => {
          this.loading = false;
        },
      });
  }

  selectRun(run: MoonshotStoredRun): void {
    this.moonshot
      .getRun(run.run_id)
      .pipe(takeUntilDestroyed(this.destroyRef))
      .subscribe((result) => {
        this.selectedRun = result.run ?? run;
      });
  }

  formatUnix(timestamp: number): string {
    if (!timestamp) {
      return '-';
    }
    return new Date(timestamp * 1000).toLocaleString();
  }
}
