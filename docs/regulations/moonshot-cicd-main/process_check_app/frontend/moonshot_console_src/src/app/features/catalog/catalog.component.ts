import { CommonModule } from '@angular/common';
import { Component, CUSTOM_ELEMENTS_SCHEMA, DestroyRef, inject } from '@angular/core';
import { takeUntilDestroyed } from '@angular/core/rxjs-interop';

import { MoonshotConfigSummaryResponse, MoonshotTestConfigsResponse } from '../../core/models/moonshot.model';
import { MoonshotApiService } from '../../core/services/moonshot-api.service';

@Component({
  selector: 'app-catalog',
  standalone: true,
  imports: [CommonModule],
  schemas: [CUSTOM_ELEMENTS_SCHEMA],
  template: `
    <section class="page">
      <div class="header-row">
        <div>
          <ui5-title level="H2">Available Tests + Connectors</ui5-title>
          <p class="subtitle">Backed by Moonshot config and test-config exports.</p>
        </div>
        <ui5-button icon="refresh" design="Transparent" (click)="refresh()">Reload</ui5-button>
      </div>

      <div class="grid">
        <ui5-card>
          <ui5-card-header slot="header" title-text="Connectors"></ui5-card-header>
          <div class="card-content">
            <ui5-list *ngIf="summary?.connectors?.length; else noConnectors">
              <ui5-li *ngFor="let connector of summary?.connectors" icon="machine">{{ connector }}</ui5-li>
            </ui5-list>
          </div>
        </ui5-card>

        <ui5-card>
          <ui5-card-header slot="header" title-text="Metrics"></ui5-card-header>
          <div class="card-content">
            <ui5-list *ngIf="summary?.metrics?.length; else noMetrics">
              <ui5-li *ngFor="let metric of summary?.metrics" icon="accept">{{ metric }}</ui5-li>
            </ui5-list>
          </div>
        </ui5-card>

        <ui5-card>
          <ui5-card-header slot="header" title-text="Attack Modules"></ui5-card-header>
          <div class="card-content">
            <ui5-list *ngIf="summary?.attack_modules?.length; else noModules">
              <ui5-li *ngFor="let module of summary?.attack_modules" icon="warning">{{ module }}</ui5-li>
            </ui5-list>
          </div>
        </ui5-card>
      </div>

      <ui5-card>
        <ui5-card-header
          slot="header"
          title-text="Test Config IDs"
          subtitle-text="From /api/moonshot/test-configs"
        ></ui5-card-header>
        <div class="card-content">
          <ui5-table>
            <ui5-table-column slot="columns"><span>Test Config ID</span></ui5-table-column>
            <ui5-table-column slot="columns"><span>Definition Type</span></ui5-table-column>

            <ui5-table-row *ngFor="let testId of testConfigIds">
              <ui5-table-cell>{{ testId }}</ui5-table-cell>
              <ui5-table-cell>{{ describeTestConfig(testId) }}</ui5-table-cell>
            </ui5-table-row>
          </ui5-table>

          <p *ngIf="testConfigIds.length === 0" class="empty">No test config IDs found.</p>
        </div>
      </ui5-card>

      <ng-template #noConnectors><p class="empty">No connectors available.</p></ng-template>
      <ng-template #noMetrics><p class="empty">No metrics available.</p></ng-template>
      <ng-template #noModules><p class="empty">No attack modules available.</p></ng-template>
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

      .grid {
        display: grid;
        grid-template-columns: repeat(auto-fit, minmax(260px, 1fr));
        gap: 1rem;
      }

      .card-content {
        padding: 0.9rem;
      }

      .empty {
        font-style: italic;
        color: var(--sapContent_LabelColor);
      }

      @media (max-width: 760px) {
        .header-row {
          align-items: flex-start;
          flex-direction: column;
        }
      }
    `,
  ],
})
export class CatalogComponent {
  private readonly destroyRef = inject(DestroyRef);
  private readonly moonshot = inject(MoonshotApiService);

  summary: MoonshotConfigSummaryResponse | null = null;
  tests: MoonshotTestConfigsResponse | null = null;
  testConfigIds: string[] = [];

  constructor() {
    this.refresh();
  }

  refresh(): void {
    this.moonshot
      .getConfigSummary()
      .pipe(takeUntilDestroyed(this.destroyRef))
      .subscribe((summary) => {
        this.summary = summary;
      });

    this.moonshot
      .getTestConfigs()
      .pipe(takeUntilDestroyed(this.destroyRef))
      .subscribe((tests) => {
        this.tests = tests;
        this.testConfigIds = tests.test_config_ids ?? [];
      });
  }

  describeTestConfig(testId: string): string {
    if (!this.tests) {
      return 'unknown';
    }

    const entry = this.tests.test_configs[testId];
    if (Array.isArray(entry)) {
      return `${entry.length} test entry(s)`;
    }
    if (entry && typeof entry === 'object') {
      return 'single test object';
    }
    return typeof entry;
  }
}
