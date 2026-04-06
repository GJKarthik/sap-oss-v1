import {
  Component, ChangeDetectionStrategy, inject, signal, OnInit, OnDestroy,
  CUSTOM_ELEMENTS_SCHEMA,
} from '@angular/core';
import { CommonModule } from '@angular/common';
import { FormsModule } from '@angular/forms';
import { Subject, takeUntil } from 'rxjs';
import { I18nService } from '../../services/i18n.service';
import { ApiService } from '../../services/api.service';
import { ToastService } from '../../services/toast.service';
import { LocaleNumberPipe } from '../../shared/pipes/locale-number.pipe';

interface AnalyticsRow {
  source: string;
  date: string;
  revenue: number;
  profit: number;
}

interface AnalyticsResponse {
  total_revenue: number;
  total_profit: number;
  doc_count: number;
  rows: AnalyticsRow[];
}

@Component({
  selector: 'app-analytics',
  standalone: true,
  imports: [CommonModule, FormsModule, LocaleNumberPipe],
  schemas: [CUSTOM_ELEMENTS_SCHEMA],
  changeDetection: ChangeDetectionStrategy.OnPush,
  template: `
    <div class="page-container" [class.rtl]="i18n.isRtl()">
      <header class="page-header">
        <div class="header-row">
          <div>
            <h1 class="page-title">{{ i18n.t('analytics.title') }}</h1>
            <p class="page-subtitle">{{ i18n.t('analytics.subtitle') }}</p>
          </div>
          <div class="header-actions">
            <select class="store-select" [(ngModel)]="selectedStore" (ngModelChange)="loadData()">
              @for (s of stores; track s) {
                <option [value]="s">{{ s }}</option>
              }
            </select>
            <button class="btn-refresh" (click)="loadData()" [disabled]="loading()">
              {{ i18n.t('analytics.refresh') }}
            </button>
          </div>
        </div>
      </header>

      @if (loading()) {
        <div class="loading-state">
          <ui5-busy-indicator active size="Medium"></ui5-busy-indicator>
          <p>{{ i18n.t('analytics.loading') }}</p>
        </div>
      }

      @if (!loading() && data()) {
        <div class="kpi-row">
          <div class="kpi-card">
            <div class="kpi-label">{{ i18n.t('analytics.totalRevenue') }}</div>
            <div class="kpi-value">{{ data()!.total_revenue | localeNumber:'1.0-0' }}</div>
          </div>
          <div class="kpi-card">
            <div class="kpi-label">{{ i18n.t('analytics.totalProfit') }}</div>
            <div class="kpi-value">{{ data()!.total_profit | localeNumber:'1.0-0' }}</div>
          </div>
          <div class="kpi-card">
            <div class="kpi-label">{{ i18n.t('analytics.docCount') }}</div>
            <div class="kpi-value">{{ data()!.doc_count }}</div>
          </div>
        </div>

        <div class="table-section">
          <h2 class="section-title">{{ i18n.t('analytics.trendsTitle') }}</h2>
          <table class="data-table">
            <thead>
              <tr>
                <th>{{ i18n.t('analytics.col.source') }}</th>
                <th>{{ i18n.t('analytics.col.date') }}</th>
                <th>{{ i18n.t('analytics.col.revenue') }}</th>
                <th>{{ i18n.t('analytics.col.profit') }}</th>
              </tr>
            </thead>
            <tbody>
              @for (row of data()!.rows; track row.source) {
                <tr>
                  <td>{{ row.source }}</td>
                  <td>{{ row.date }}</td>
                  <td>{{ row.revenue | localeNumber:'1.0-0' }}</td>
                  <td>{{ row.profit | localeNumber:'1.0-0' }}</td>
                </tr>
              }
            </tbody>
          </table>
        </div>
      }
    </div>
  `,
  styles: [`
    :host { display: block; height: 100%; overflow-y: auto; }

    .page-container { padding: 1.5rem; max-width: 1100px; margin: 0 auto; }

    .page-header { margin-bottom: 1.5rem; }
    .header-row { display: flex; justify-content: space-between; align-items: flex-start; flex-wrap: wrap; gap: 1rem; }
    .header-actions { display: flex; gap: 0.5rem; align-items: center; }

    .page-title {
      font-size: 1.25rem; font-weight: 600; margin: 0;
      color: var(--sapTextColor, #32363a);
    }
    .page-subtitle {
      font-size: 0.8125rem; margin: 0.25rem 0 0;
      color: var(--sapContent_LabelColor, #6a6d70);
    }

    .store-select {
      padding: 0.375rem 0.5rem; border: 1px solid var(--sapField_BorderColor, #89919a);
      border-radius: 0.25rem; font-size: 0.8125rem;
      background: var(--sapField_Background, #fff);
      color: var(--sapTextColor, #32363a);
    }

    .btn-refresh {
      padding: 0.375rem 0.75rem;
      background: var(--sapBrandColor, #0854a0); color: #fff;
      border: none; border-radius: 0.25rem; cursor: pointer; font-size: 0.8125rem;
      &:disabled { opacity: 0.5; }
      &:hover:not(:disabled) { background: var(--sapButton_Hover_Background, #0a6ed1); }
    }

    .loading-state {
      display: flex; flex-direction: column; align-items: center;
      padding: 3rem; gap: 0.75rem;
      color: var(--sapContent_LabelColor, #6a6d70);
    }

    .kpi-row { display: flex; gap: 1rem; margin-bottom: 1.5rem; flex-wrap: wrap; }

    .kpi-card {
      flex: 1; min-width: 180px;
      padding: 1rem 1.25rem;
      background: var(--sapBaseColor, #fff);
      border: 1px solid var(--sapTile_BorderColor, #e4e4e4);
      border-radius: 0.5rem;
    }
    .kpi-label {
      font-size: 0.75rem; font-weight: 600; text-transform: uppercase;
      color: var(--sapContent_LabelColor, #6a6d70); letter-spacing: 0.04em;
    }
    .kpi-value {
      font-size: 1.5rem; font-weight: 700; margin-top: 0.25rem;
      color: var(--sapTextColor, #32363a);
    }

    .section-title {
      font-size: 0.9375rem; font-weight: 600; margin: 0 0 0.75rem;
      color: var(--sapTextColor, #32363a);
    }

    .data-table {
      width: 100%; border-collapse: collapse;
      font-size: 0.8125rem;
    }
    .data-table th {
      text-align: start; font-weight: 600; padding: 0.5rem 0.75rem;
      border-bottom: 2px solid var(--sapGroup_TitleBorderColor, #d9d9d9);
      color: var(--sapContent_LabelColor, #6a6d70);
    }
    .data-table td {
      padding: 0.5rem 0.75rem;
      border-bottom: 1px solid var(--sapGroup_TitleBorderColor, #d9d9d9);
      color: var(--sapTextColor, #32363a);
    }
    .data-table tbody tr:hover {
      background: var(--sapList_Hover_Background, #f5f5f5);
    }
  `],
})
export class AnalyticsComponent implements OnInit, OnDestroy {
  readonly i18n = inject(I18nService);
  private readonly api = inject(ApiService);
  private readonly toast = inject(ToastService);
  private readonly destroy$ = new Subject<void>();

  readonly loading = signal(false);
  readonly data = signal<AnalyticsResponse | null>(null);

  selectedStore = 'default';
  stores = ['default', 'financial_reports', 'regulatory_docs'];

  ngOnInit(): void {
    this.loadData();
  }

  ngOnDestroy(): void {
    this.destroy$.next();
    this.destroy$.complete();
  }

  loadData(): void {
    this.loading.set(true);
    this.api.post<AnalyticsResponse>('/rag/analytics', { store: this.selectedStore })
      .pipe(takeUntil(this.destroy$))
      .subscribe({
        next: (resp) => {
          this.data.set(resp);
          this.loading.set(false);
        },
        error: () => {
          this.toast.error(this.i18n.t('analytics.error.loadFailed'));
          this.loading.set(false);
        },
      });
  }
}
