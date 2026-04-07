import { CommonModule } from '@angular/common';
import { Component, CUSTOM_ELEMENTS_SCHEMA, DestroyRef, inject } from '@angular/core';
import { takeUntilDestroyed } from '@angular/core/rxjs-interop';

import { MoonshotConfigSummaryResponse, MoonshotHealthResponse } from '../../core/models/moonshot.model';
import { MoonshotApiService } from '../../core/services/moonshot-api.service';

@Component({
  selector: 'app-overview',
  standalone: true,
  imports: [CommonModule],
  schemas: [CUSTOM_ELEMENTS_SCHEMA],
  template: `
    <section class="page">
      <div class="header-row">
        <div>
          <ui5-title level="H2">Moonshot Runtime Overview</ui5-title>
          <p class="subtitle">Native Zig execution, connector inventory, and persistence health.</p>
        </div>
        <ui5-button design="Emphasized" icon="refresh" (click)="refresh()" [disabled]="loading">
          {{ loading ? 'Refreshing...' : 'Refresh' }}
        </ui5-button>
      </div>

      <div class="grid">
        <ui5-card>
          <ui5-card-header slot="header" title-text="Gateway Health" subtitle-text="/api/moonshot/health">
            <ui5-icon slot="avatar" name="status-positive"></ui5-icon>
          </ui5-card-header>
          <div class="card-content" *ngIf="health; else healthMissing">
            <div class="row"><span>Status</span><ui5-badge color-scheme="8">{{ health.status }}</ui5-badge></div>
            <div class="row"><span>Binary</span><span>{{ health.binary_exists ? 'Found' : 'Missing' }}</span></div>
            <div class="row"><span>OData</span><span>{{ health.odata_reachable ? 'Reachable' : 'Not reachable' }}</span></div>
            <div class="key">Moonshot Root</div>
            <pre>{{ health.moonshot_root }}</pre>
            <div class="key">Moonshot Binary</div>
            <pre>{{ health.moonshot_binary }}</pre>
          </div>
        </ui5-card>

        <ui5-card>
          <ui5-card-header slot="header" title-text="Config Summary" subtitle-text="/api/moonshot/config/summary">
            <ui5-icon slot="avatar" name="action-settings"></ui5-icon>
          </ui5-card-header>
          <div class="card-content" *ngIf="summary; else summaryMissing">
            <div class="row"><span>Connectors</span><strong>{{ summary.connector_count }}</strong></div>
            <div class="row"><span>Metrics</span><strong>{{ summary.metric_count }}</strong></div>
            <div class="row"><span>Attack Modules</span><strong>{{ summary.attack_module_count }}</strong></div>
            <div class="row"><span>Max Concurrency</span><strong>{{ summary.common.max_concurrency }}</strong></div>
            <div class="row"><span>Calls/Minute</span><strong>{{ summary.common.max_calls_per_minute }}</strong></div>
            <div class="row"><span>Max Attempts</span><strong>{{ summary.common.max_attempts }}</strong></div>
          </div>
        </ui5-card>

        <ui5-card>
          <ui5-card-header slot="header" title-text="Connector Snapshot" subtitle-text="Top configured connectors">
            <ui5-icon slot="avatar" name="chain-link"></ui5-icon>
          </ui5-card-header>
          <div class="card-content">
            <ui5-list *ngIf="summary?.connectors?.length; else connectorsMissing">
              <ui5-li *ngFor="let connector of summary?.connectors" icon="machine">{{ connector }}</ui5-li>
            </ui5-list>
          </div>
        </ui5-card>
      </div>

      <ng-template #healthMissing>
        <div class="card-content empty">No health data yet.</div>
      </ng-template>

      <ng-template #summaryMissing>
        <div class="card-content empty">No summary data yet.</div>
      </ng-template>

      <ng-template #connectorsMissing>
        <p class="empty">No connector data available.</p>
      </ng-template>
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
        align-items: flex-start;
      }

      .subtitle {
        margin: 0.35rem 0 0;
        color: var(--sapContent_LabelColor);
      }

      .grid {
        display: grid;
        grid-template-columns: repeat(auto-fit, minmax(300px, 1fr));
        gap: 1rem;
      }

      .card-content {
        padding: 1rem;
      }

      .row {
        display: flex;
        justify-content: space-between;
        gap: 1rem;
        margin-bottom: 0.5rem;
      }

      .key {
        font-size: 0.75rem;
        color: var(--sapContent_LabelColor);
        margin-top: 0.75rem;
      }

      pre {
        margin: 0.25rem 0 0;
        white-space: pre-wrap;
        word-break: break-all;
        font-size: 0.78rem;
        background: rgba(8, 53, 97, 0.05);
        border-radius: 6px;
        padding: 0.45rem 0.55rem;
      }

      .empty {
        color: var(--sapContent_LabelColor);
        font-style: italic;
      }

      @media (max-width: 760px) {
        .header-row {
          flex-direction: column;
        }
      }
    `,
  ],
})
export class OverviewComponent {
  private readonly destroyRef = inject(DestroyRef);
  private readonly moonshot = inject(MoonshotApiService);

  loading = false;
  health: MoonshotHealthResponse | null = null;
  summary: MoonshotConfigSummaryResponse | null = null;

  constructor() {
    this.refresh();
  }

  refresh(): void {
    this.loading = true;

    this.moonshot
      .checkHealth()
      .pipe(takeUntilDestroyed(this.destroyRef))
      .subscribe({
        next: (health) => {
          this.health = health;
        },
      });

    this.moonshot
      .getConfigSummary()
      .pipe(takeUntilDestroyed(this.destroyRef))
      .subscribe({
        next: (summary) => {
          this.summary = summary;
          this.loading = false;
        },
        error: () => {
          this.loading = false;
        },
      });
  }
}
