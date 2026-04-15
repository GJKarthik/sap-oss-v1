import {
  Component, ChangeDetectionStrategy, inject, signal, OnDestroy, OnInit,
  CUSTOM_ELEMENTS_SCHEMA,
} from '@angular/core';
import { CommonModule } from '@angular/common';
import { FormsModule } from '@angular/forms';
import { Subject, forkJoin, takeUntil } from 'rxjs';
import { I18nService } from '../../services/i18n.service';
import { ToastService } from '../../services/toast.service';
import {
  TrainingGovernanceService,
  type TrainingMetricsOverview,
  type TrainingMetricsTrends,
} from '../../services/training-governance.service';
import { CrossAppLinkComponent } from '../../shared';

@Component({
  selector: 'app-analytics',
  standalone: true,
  imports: [CommonModule, FormsModule, CrossAppLinkComponent],
  schemas: [CUSTOM_ELEMENTS_SCHEMA],
  changeDetection: ChangeDetectionStrategy.OnPush,
  template: `
    <div class="page-container" [class.rtl]="i18n.isRtl()">
      <header class="page-header">
        <div class="header-row">
          <div>
            <h1 class="page-title">{{ i18n.t('analytics.title') }}</h1>
            <p class="page-subtitle">Training safety metrics for approval latency, blocked runs, gate pass rate, runtime success, and evaluation completeness.</p>
          </div>
          <div class="header-actions">
            <select class="filter-select" [(ngModel)]="workflowType">
              <option value="">All workflows</option>
              <option value="pipeline">Pipeline</option>
              <option value="optimization">Optimization</option>
              <option value="deployment">Deployment</option>
            </select>
            <input class="filter-input" [(ngModel)]="teamFilter" placeholder="Team filter" />
            <select class="filter-select" [(ngModel)]="windowDays">
              <option [ngValue]="7">7 days</option>
              <option [ngValue]="30">30 days</option>
              <option [ngValue]="90">90 days</option>
            </select>
            <ui5-button design="Emphasized" (click)="loadData()" [disabled]="loading()">
              {{ i18n.t('analytics.refresh') }}
            </ui5-button>
          </div>
        </div>
      </header>

      <app-cross-app-link
        targetApp="training"
        targetRoute="/governance"
        targetLabelKey="nav.governance"
        icon="shield">
      </app-cross-app-link>

      @if (loading()) {
        <div class="loading-state">
          <ui5-busy-indicator active size="Medium"></ui5-busy-indicator>
          <p>Loading governance metrics…</p>
        </div>
      }

      @if (!loading() && overview()) {
        <div class="kpi-row">
          <div class="kpi-card">
            <div class="kpi-label">Gate pass rate</div>
            <div class="kpi-value">{{ overview()!.gate_pass_rate.toFixed(1) }}%</div>
          </div>
          <div class="kpi-card">
            <div class="kpi-label">Approval latency</div>
            <div class="kpi-value">{{ formatSeconds(overview()!.approval_latency_sec_avg) }}</div>
          </div>
          <div class="kpi-card">
            <div class="kpi-label">Blocked runs</div>
            <div class="kpi-value">{{ overview()!.blocked_run_count }}</div>
          </div>
          <div class="kpi-card">
            <div class="kpi-label">Run success rate</div>
            <div class="kpi-value">{{ overview()!.run_success_rate.toFixed(1) }}%</div>
          </div>
          <div class="kpi-card">
            <div class="kpi-label">Evaluation completeness</div>
            <div class="kpi-value">{{ overview()!.evaluation_completeness_rate.toFixed(1) }}%</div>
          </div>
        </div>

        <div class="chart-section">
          <div class="chart-header">
            <h2 class="section-title">Trend view</h2>
            <span class="meta">{{ overview()!.total_runs }} runs in window</span>
          </div>
          <div class="chart-container">
            <svg class="bar-chart" viewBox="0 0 700 220" preserveAspectRatio="xMidYMid meet">
              @for (bar of chartBars(); track bar.label; let i = $index) {
                <g [attr.transform]="'translate(' + (i * barWidth()) + ', 0)'">
                  <rect class="bar bar--gate" [attr.x]="4" [attr.y]="200 - bar.gateH" [attr.width]="barWidth() / 2 - 6" [attr.height]="bar.gateH" rx="3"></rect>
                  <rect class="bar bar--success" [attr.x]="barWidth() / 2 + 2" [attr.y]="200 - bar.successH" [attr.width]="barWidth() / 2 - 6" [attr.height]="bar.successH" rx="3"></rect>
                  <text class="bar-label" [attr.x]="barWidth() / 2" y="214" text-anchor="middle">{{ bar.label }}</text>
                </g>
              }
            </svg>
            <div class="chart-legend">
              <span class="legend-item"><span class="legend-dot legend-dot--gate"></span> Gate pass rate</span>
              <span class="legend-item"><span class="legend-dot legend-dot--success"></span> Run success rate</span>
            </div>
          </div>
        </div>

        <div class="table-section">
          <div class="chart-header">
            <h2 class="section-title">Daily metrics</h2>
          </div>
          <table class="data-table">
            <thead>
              <tr>
                <th>Date</th>
                <th>Runs</th>
                <th>Blocked</th>
                <th>Pending approvals</th>
                <th>Gate pass rate</th>
                <th>Run success rate</th>
              </tr>
            </thead>
            <tbody>
              @for (row of trends()?.rows || []; track row.date) {
                <tr>
                  <td>{{ row.date }}</td>
                  <td>{{ row.runs }}</td>
                  <td>{{ row.blocked_runs }}</td>
                  <td>{{ row.pending_approvals }}</td>
                  <td>{{ row.gate_pass_rate.toFixed(1) }}%</td>
                  <td>{{ row.run_success_rate.toFixed(1) }}%</td>
                </tr>
              }
              @if ((trends()?.rows || []).length === 0) {
                <tr><td colspan="6" class="empty-cell">No governance trend data is available for this filter set.</td></tr>
              }
            </tbody>
          </table>
        </div>
      }
    </div>
  `,
  styles: [`
    :host { display: block; height: 100%; overflow-y: auto; }
    .page-container { padding: 1.5rem; max-width: 1200px; margin: 0 auto; }
    .page-header { margin-bottom: 1.5rem; }
    .header-row { display: flex; justify-content: space-between; align-items: flex-start; flex-wrap: wrap; gap: 1rem; }
    .header-actions { display: flex; gap: 0.5rem; align-items: center; flex-wrap: wrap; }
    .page-title { font-size: 1.25rem; font-weight: 600; margin: 0; color: var(--sapTextColor, #32363a); }
    .page-subtitle, .meta { font-size: 0.8125rem; margin: 0.25rem 0 0; color: var(--sapContent_LabelColor, #6a6d70); }
    .filter-select, .filter-input { padding: 0.375rem 0.5rem; border: 1px solid var(--sapField_BorderColor, #89919a); border-radius: 0.25rem; font-size: 0.8125rem; background: var(--sapField_Background, #fff); color: var(--sapTextColor, #32363a); }
    .loading-state { display: flex; flex-direction: column; align-items: center; padding: 3rem; gap: 0.75rem; color: var(--sapContent_LabelColor, #6a6d70); }
    .kpi-row { display: grid; grid-template-columns: repeat(5, 1fr); gap: 1rem; margin-bottom: 1.5rem; }
    .kpi-card { padding: 1rem 1.25rem; background: var(--sapBaseColor, #fff); border: 1px solid var(--sapTile_BorderColor, #e4e4e4); border-radius: 0.5rem; }
    .kpi-label { font-size: 0.75rem; font-weight: 600; text-transform: uppercase; color: var(--sapContent_LabelColor, #6a6d70); letter-spacing: 0.04em; }
    .kpi-value { font-size: 1.5rem; font-weight: 700; margin-top: 0.25rem; color: var(--sapTextColor, #32363a); }
    .section-title { font-size: 0.9375rem; font-weight: 600; margin: 0 0 0.75rem; color: var(--sapTextColor, #32363a); }
    .chart-section, .table-section { margin-bottom: 1.5rem; }
    .chart-header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 0.75rem; }
    .chart-container { background: var(--sapBaseColor, #fff); border: 1px solid var(--sapTile_BorderColor, #e4e4e4); border-radius: 0.5rem; padding: 1rem; }
    .bar-chart { width: 100%; height: auto; max-height: 240px; }
    .bar--gate { fill: var(--sapBrandColor, #0854a0); opacity: 0.9; }
    .bar--success { fill: var(--sapPositiveColor, #107e3e); opacity: 0.85; }
    .bar-label { font-size: 8px; fill: var(--sapContent_LabelColor, #6a6d70); }
    .chart-legend { display: flex; gap: 1rem; margin-top: 0.5rem; font-size: 0.75rem; color: var(--sapContent_LabelColor); }
    .legend-item { display: flex; align-items: center; gap: 0.25rem; }
    .legend-dot { width: 10px; height: 10px; border-radius: 2px; }
    .legend-dot--gate { background: var(--sapBrandColor, #0854a0); }
    .legend-dot--success { background: var(--sapPositiveColor, #107e3e); }
    .data-table { width: 100%; border-collapse: collapse; font-size: 0.8125rem; }
    .data-table th { text-align: start; font-weight: 600; padding: 0.5rem 0.75rem; border-bottom: 2px solid var(--sapGroup_TitleBorderColor, #d9d9d9); color: var(--sapContent_LabelColor, #6a6d70); }
    .data-table td { padding: 0.5rem 0.75rem; border-bottom: 1px solid var(--sapGroup_TitleBorderColor, #d9d9d9); color: var(--sapTextColor, #32363a); }
    .empty-cell { text-align: center; color: var(--sapContent_LabelColor); padding: 1.5rem; }
    @media (max-width: 960px) {
      .kpi-row { grid-template-columns: 1fr 1fr; }
    }
  `],
})
export class AnalyticsComponent implements OnInit, OnDestroy {
  readonly i18n = inject(I18nService);
  private readonly governance = inject(TrainingGovernanceService);
  private readonly toast = inject(ToastService);
  private readonly destroy$ = new Subject<void>();

  readonly loading = signal(false);
  readonly overview = signal<TrainingMetricsOverview | null>(null);
  readonly trends = signal<TrainingMetricsTrends | null>(null);

  workflowType = '';
  teamFilter = '';
  windowDays = 30;

  ngOnInit(): void {
    this.loadData();
  }

  ngOnDestroy(): void {
    this.destroy$.next();
    this.destroy$.complete();
  }

  loadData(): void {
    this.loading.set(true);
    forkJoin({
      overview: this.governance.getMetricsOverview({
        window: this.windowDays,
        workflow_type: this.workflowType,
        team: this.teamFilter,
      }),
      trends: this.governance.getMetricsTrends({
        window: this.windowDays,
        workflow_type: this.workflowType,
        team: this.teamFilter,
      }),
    }).pipe(takeUntil(this.destroy$)).subscribe({
      next: (response) => {
        this.overview.set(response.overview);
        this.trends.set(response.trends);
        this.loading.set(false);
      },
      error: () => {
        this.loading.set(false);
        this.toast.error(this.i18n.t('analytics.error.loadFailed'));
      },
    });
  }

  chartBars(): { label: string; gateH: number; successH: number }[] {
    const rows = this.trends()?.rows ?? [];
    return rows.map((row) => ({
      label: row.date.slice(5),
      gateH: (row.gate_pass_rate / 100) * 180,
      successH: (row.run_success_rate / 100) * 180,
    }));
  }

  barWidth(): number {
    const bars = this.trends()?.rows?.length || 1;
    return Math.min(700 / bars, 120);
  }

  formatSeconds(value: number): string {
    if (!value) return '0s';
    if (value >= 3600) return `${(value / 3600).toFixed(1)}h`;
    if (value >= 60) return `${(value / 60).toFixed(1)}m`;
    return `${value.toFixed(0)}s`;
  }
}
