import {
  Component, ChangeDetectionStrategy, inject, signal, OnInit, OnDestroy,
  } from '@angular/core';
import { CommonModule } from '@angular/common';
import { Ui5TrainingComponentsModule } from '../../shared/ui5-training-components.module';
import { FormsModule } from '@angular/forms';
import { Subject, takeUntil } from 'rxjs';
import { I18nService } from '../../services/i18n.service';
import { ApiService } from '../../services/api.service';
import { ToastService } from '../../services/toast.service';
import { LocaleNumberPipe } from '../../shared/pipes/locale-number.pipe';
import { CrossAppLinkComponent } from '../../shared';

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
  imports: [CommonModule, Ui5TrainingComponentsModule, FormsModule, LocaleNumberPipe, CrossAppLinkComponent],
  changeDetection: ChangeDetectionStrategy.OnPush,
  template: `
    <div class="page-container" [class.rtl]="i18n.isRtl()">
      <ui5-breadcrumbs>
        <ui5-breadcrumbs-item href="/dashboard" text="Home"></ui5-breadcrumbs-item>
        <ui5-breadcrumbs-item text="Analytics"></ui5-breadcrumbs-item>
      </ui5-breadcrumbs>
      <header class="page-header">
        <div class="header-row">
          <div>
            <ui5-title level="H3">{{ i18n.t('analytics.title') }}</ui5-title>
            <p class="page-subtitle">{{ i18n.t('analytics.subtitle') }}</p>
          </div>
          <div class="header-actions">
            <ui5-select (change)="onStoreChange($event)">
              @for (s of stores; track s) {
                <ui5-option [value]="s" [attr.selected]="selectedStore === s ? true : null">{{ s }}</ui5-option>
              }
            </ui5-select>
            <ui5-button design="Default" (click)="loadData()" [disabled]="loading()">
              {{ i18n.t('analytics.refresh') }}
            </ui5-button>
          </div>
        </div>
      </header>

      <app-cross-app-link
        targetApp="training"
        targetRoute="/data-explorer"
        targetLabelKey="nav.dataExplorer"
        icon="database">
      </app-cross-app-link>

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

        <!-- Bar Chart -->
        <div class="chart-section">
          <div class="chart-header">
            <ui5-title level="H4">{{ i18n.t('analytics.trendsTitle') }}</ui5-title>
            <ui5-button design="Transparent" icon="download" (click)="exportCsv()">CSV</ui5-button>
          </div>
          <div class="chart-container">
            <svg class="bar-chart" viewBox="0 0 600 200" preserveAspectRatio="xMidYMid meet">
              @for (bar of chartBars(); track bar.label; let i = $index) {
                <g [attr.transform]="'translate(' + (i * barWidth()) + ', 0)'">
                  <rect class="bar bar--revenue" [attr.x]="2" [attr.y]="200 - bar.revenueH" [attr.width]="barWidth() / 2 - 3" [attr.height]="bar.revenueH" rx="2"></rect>
                  <rect class="bar bar--profit" [attr.x]="barWidth() / 2 + 1" [attr.y]="200 - bar.profitH" [attr.width]="barWidth() / 2 - 3" [attr.height]="bar.profitH" rx="2"></rect>
                  <text class="bar-label" [attr.x]="barWidth() / 2" y="198" text-anchor="middle">{{ bar.label }}</text>
                </g>
              }
            </svg>
            <div class="chart-legend">
              <span class="legend-item"><span class="legend-dot legend-dot--revenue"></span> {{ i18n.t('analytics.col.revenue') }}</span>
              <span class="legend-item"><span class="legend-dot legend-dot--profit"></span> {{ i18n.t('analytics.col.profit') }}</span>
            </div>
          </div>
        </div>

        <div class="table-section">
          <ui5-toolbar>
            <ui5-title level="H5">{{ i18n.t('analytics.trendsTitle') }}</ui5-title>
            <ui5-toolbar-spacer></ui5-toolbar-spacer>
            <ui5-input [placeholder]="i18n.t('analytics.filterBySource')" [value]="sourceFilter" (input)="sourceFilter = $any($event).target.value" icon="search"></ui5-input>
            <ui5-toolbar-separator></ui5-toolbar-separator>
            <ui5-toolbar-button icon="download" text="CSV" (click)="exportCsv()"></ui5-toolbar-button>
          </ui5-toolbar>
          <ui5-table accessible-name="Analytics data" overflow-mode="Popin">
            <ui5-table-header-row slot="headerRow">
              <ui5-table-header-cell (click)="toggleSort('source')" style="cursor:pointer">{{ i18n.t('analytics.col.source') }} {{ sortIcon('source') }}</ui5-table-header-cell>
              <ui5-table-header-cell (click)="toggleSort('date')" style="cursor:pointer">{{ i18n.t('analytics.col.date') }} {{ sortIcon('date') }}</ui5-table-header-cell>
              <ui5-table-header-cell (click)="toggleSort('revenue')" style="cursor:pointer">{{ i18n.t('analytics.col.revenue') }} {{ sortIcon('revenue') }}</ui5-table-header-cell>
              <ui5-table-header-cell (click)="toggleSort('profit')" style="cursor:pointer">{{ i18n.t('analytics.col.profit') }} {{ sortIcon('profit') }}</ui5-table-header-cell>
            </ui5-table-header-row>
            @for (row of filteredRows(); track row.source + row.date) {
              <ui5-table-row>
                <ui5-table-cell>{{ row.source }}</ui5-table-cell>
                <ui5-table-cell>{{ row.date }}</ui5-table-cell>
                <ui5-table-cell>{{ row.revenue | localeNumber:'1.0-0' }}</ui5-table-cell>
                <ui5-table-cell>{{ row.profit | localeNumber:'1.0-0' }}</ui5-table-cell>
              </ui5-table-row>
            }
            @if (filteredRows().length === 0) {
              <ui5-table-row><ui5-table-cell colspan="4">{{ i18n.t('analytics.noDataMatchingFilter') }}</ui5-table-cell></ui5-table-row>
            }
          </ui5-table>
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

    .chart-section { margin-bottom: 1.5rem; }
    .chart-header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 0.75rem; }
    .chart-container { background: var(--sapBaseColor, #fff); border: 1px solid var(--sapTile_BorderColor, #e4e4e4); border-radius: 0.5rem; padding: 1rem; }
    .bar-chart { width: 100%; height: auto; max-height: 220px; }
    .bar--revenue { fill: var(--sapBrandColor, #0854a0); opacity: 0.85; }
    .bar--profit { fill: var(--sapPositiveColor, #107e3e); opacity: 0.85; }
    .bar-label { font-size: 8px; fill: var(--sapContent_LabelColor, #6a6d70); }
    .chart-legend { display: flex; gap: 1rem; margin-top: 0.5rem; font-size: 0.75rem; color: var(--sapContent_LabelColor); }
    .legend-item { display: flex; align-items: center; gap: 0.25rem; }
    .legend-dot { width: 10px; height: 10px; border-radius: 2px; }
    .legend-dot--revenue { background: var(--sapBrandColor, #0854a0); }
    .legend-dot--profit { background: var(--sapPositiveColor, #107e3e); }
    .sortable { cursor: pointer; user-select: none; }
    .sortable:hover { color: var(--sapBrandColor); }
    .filter-row { display: flex; gap: 0.5rem; }
    .filter-input { padding: 0.375rem 0.5rem; border: 1px solid var(--sapField_BorderColor, #89919a); border-radius: 0.25rem; font-size: 0.8125rem; background: var(--sapField_Background, #fff); color: var(--sapTextColor); }
    .empty-cell { text-align: center; color: var(--sapContent_LabelColor); padding: 1.5rem; }

    @media (max-width: 768px) {
      .kpi-row { flex-direction: column; }
      .chart-container { overflow-x: auto; }
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
  sourceFilter = '';
  sortCol: keyof AnalyticsRow = 'date';
  sortDir: 'asc' | 'desc' = 'asc';

  ngOnInit(): void {
    this.loadData();
  }

  ngOnDestroy(): void {
    this.destroy$.next();
    this.destroy$.complete();
  }

  onStoreChange(event: any): void {
    this.selectedStore = event.detail?.selectedOption?.value ?? 'default';
    this.loadData();
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

  filteredRows(): AnalyticsRow[] {
    const rows = this.data()?.rows ?? [];
    let result = rows;
    if (this.sourceFilter) {
      const q = this.sourceFilter.toLowerCase();
      result = result.filter(r => r.source.toLowerCase().includes(q));
    }
    const col = this.sortCol;
    const dir = this.sortDir === 'asc' ? 1 : -1;
    return [...result].sort((a, b) => {
      const va = a[col]; const vb = b[col];
      if (typeof va === 'number' && typeof vb === 'number') return (va - vb) * dir;
      return String(va).localeCompare(String(vb)) * dir;
    });
  }

  chartBars(): { label: string; revenueH: number; profitH: number }[] {
    const rows = this.data()?.rows ?? [];
    if (rows.length === 0) return [];
    const maxVal = Math.max(...rows.map(r => Math.max(r.revenue, r.profit)), 1);
    return rows.map(r => ({
      label: r.source.substring(0, 8),
      revenueH: (r.revenue / maxVal) * 180,
      profitH: (r.profit / maxVal) * 180,
    }));
  }

  barWidth(): number {
    const bars = this.data()?.rows?.length || 1;
    return Math.min(600 / bars, 120);
  }

  toggleSort(col: keyof AnalyticsRow): void {
    if (this.sortCol === col) this.sortDir = this.sortDir === 'asc' ? 'desc' : 'asc';
    else { this.sortCol = col; this.sortDir = 'asc'; }
  }

  sortIcon(col: string): string {
    if (this.sortCol !== col) return '';
    return this.sortDir === 'asc' ? '↑' : '↓';
  }

  exportCsv(): void {
    const rows = this.filteredRows();
    if (rows.length === 0) return;
    const header = 'Source,Date,Revenue,Profit\n';
    const body = rows.map(r => `${r.source},${r.date},${r.revenue},${r.profit}`).join('\n');
    const blob = new Blob([header + body], { type: 'text/csv' });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a'); a.href = url; a.download = 'analytics.csv'; a.click();
    URL.revokeObjectURL(url);
  }
}
