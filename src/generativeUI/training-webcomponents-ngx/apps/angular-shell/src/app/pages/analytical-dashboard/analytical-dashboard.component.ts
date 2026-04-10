import { Component, CUSTOM_ELEMENTS_SCHEMA, DestroyRef, OnInit, inject } from '@angular/core';
import { CommonModule } from '@angular/common';
import { FormsModule } from '@angular/forms';
import { Ui5TrainingComponentsModule } from '../../shared/ui5-training-components.module';
import { takeUntilDestroyed } from '@angular/core/rxjs-interop';
import { EmptyStateComponent, CrossAppLinkComponent } from '../../shared';
import { McpService, AnalyticalResult } from '../../services/mcp.service';
import { I18nService } from '../../services/i18n.service';

@Component({
  selector: 'app-analytical-dashboard',
  standalone: true,
  imports: [CommonModule, FormsModule, Ui5TrainingComponentsModule, EmptyStateComponent, CrossAppLinkComponent],
  schemas: [CUSTOM_ELEMENTS_SCHEMA],
  template: `
    <div class="ad-page">
      <header class="ad-header">
        <div class="ad-header__copy">
          <ui5-title level="H2">{{ i18n.t('analyticalDashboard.title') }}</ui5-title>
        </div>
        <div class="ad-header__actions">
          <ui5-button icon="refresh" (click)="loadCalcViews()" [disabled]="loading">
            {{ loading ? i18n.t('common.loading') : i18n.t('common.refresh') }}
          </ui5-button>
        </div>
      </header>

      <app-cross-app-link
        targetApp="training"
        targetRoute="/schema-browser"
        targetLabelKey="nav.schemaBrowser"
        icon="database">
      </app-cross-app-link>

      <div class="ad-content" role="main" aria-label="Analytical Dashboard">
        <ui5-message-strip *ngIf="error" design="Negative" [hideCloseButton]="false" (close)="error = ''" role="alert">{{ error }}</ui5-message-strip>

        <!-- Query Builder Card -->
        <ui5-card class="ad-card ad-card--query">
          <ui5-card-header slot="header" [attr.title-text]="i18n.t('analyticalDashboard.queryBuilder')" [attr.subtitle-text]="i18n.t('analyticalDashboard.queryBuilderSubtitle')"></ui5-card-header>
          <div class="card-body">
            <div class="form-grid">
              <div class="field-group">
                <label class="field-label">{{ i18n.t('analyticalDashboard.calcView') }}</label>
                <ui5-select ngDefaultControl name="calcView" [(ngModel)]="selectedCalcView" accessible-name="Select calculation view">
                  <ui5-option value="">{{ i18n.t('analyticalDashboard.selectCalcView') }}</ui5-option>
                  <ui5-option *ngFor="let cv of calcViews" [value]="cv">{{ cv }}</ui5-option>
                </ui5-select>
              </div>
              <div class="field-group">
                <label class="field-label">{{ i18n.t('analyticalDashboard.dimensions') }}</label>
                <ui5-input ngDefaultControl name="dimensions" [(ngModel)]="dimensionsInput" [placeholder]="i18n.t('analyticalDashboard.dimensionsPlaceholder')" accessible-name="Dimensions (comma-separated)"></ui5-input>
              </div>
              <div class="field-group">
                <label class="field-label">{{ i18n.t('analyticalDashboard.measures') }}</label>
                <ui5-input ngDefaultControl name="measures" [(ngModel)]="measuresInput" [placeholder]="i18n.t('analyticalDashboard.measuresPlaceholder')" accessible-name="Measures (comma-separated)"></ui5-input>
              </div>
              <div class="field-group">
                <label class="field-label">{{ i18n.t('analyticalDashboard.aggregation') }}</label>
                <ui5-select ngDefaultControl name="aggregation" [(ngModel)]="aggregation" accessible-name="Aggregation type">
                  <ui5-option value="SUM">SUM</ui5-option>
                  <ui5-option value="COUNT">COUNT</ui5-option>
                  <ui5-option value="AVG">AVG</ui5-option>
                  <ui5-option value="MIN">MIN</ui5-option>
                  <ui5-option value="MAX">MAX</ui5-option>
                </ui5-select>
              </div>
            </div>
            <div class="card-actions">
              <ui5-button design="Emphasized" icon="play" (click)="runQuery()" [disabled]="querying || !selectedCalcView || !measuresInput.trim()">
                {{ querying ? i18n.t('analyticalDashboard.querying') : i18n.t('analyticalDashboard.runQuery') }}
              </ui5-button>
            </div>
          </div>
        </ui5-card>

        <!-- Results Section -->
        @if (queryResult) {
          <!-- Analytical Stat Grid -->
          <div class="stats-grid">
            @for (stat of statCards; track stat.label) {
              <div class="analytical-stat-card glass-panel">
                <span class="stat-label">{{ stat.label }}</span>
                <span class="stat-value">{{ stat.value }}</span>
                <div class="stat-trend" [class.up]="true">
                  <ui5-icon name="trend-up"></ui5-icon>
                  <span>Analytical Peak</span>
                </div>
              </div>
            }
          </div>

          <!-- Results Table Card -->
          <ui5-card class="ad-card">
            <ui5-card-header slot="header" [attr.title-text]="i18n.t('analyticalDashboard.results')"
              [attr.additional-text]="queryResult.total + ' rows'" [attr.subtitle-text]="aggregation + ' aggregation'"></ui5-card-header>
            <div class="card-body">
              @if (queryResult.rows.length > 0) {
                <div class="table-wrapper">
                  <table class="premium-table">
                    <thead>
                      <tr>
                        @for (col of queryResult.columns; track col) {
                          <th>{{ col }}</th>
                        }
                      </tr>
                    </thead>
                    <tbody>
                      @for (row of queryResult.rows; track $index) {
                        <tr>
                          @for (col of queryResult.columns; track col) {
                            <td [class.num]="isNumber(row[col])">{{ formatCell(row[col]) }}</td>
                          }
                        </tr>
                      }
                    </tbody>
                  </table>
                </div>
              } @else {
                <app-empty-state icon="table-chart" [title]="i18n.t('analyticalDashboard.noResults')" [description]="i18n.t('analyticalDashboard.noResultsDesc')"></app-empty-state>
              }
            </div>
          </ui5-card>
        }
      </div>
    </div>
  `,
  styles: [`
    .ad-page { 
      padding: clamp(1.5rem, 4vw, 4rem); 
      display: flex; flex-direction: column; gap: 2.5rem;
      background: radial-gradient(circle at 100% 100%, rgba(0, 112, 242, 0.08), transparent 40rem);
      min-height: 100%;
    }

    .ad-header { display: flex; justify-content: space-between; align-items: center; }
    .ad-header__copy ui5-title { font-size: 2.5rem; font-weight: 800; letter-spacing: -0.02em; margin: 0; }

    .ad-content { display: flex; flex-direction: column; gap: 2rem; }

    .ad-card {
      background: #fff; border-radius: 32px; border: var(--liquid-glass-inner-border);
      box-shadow: var(--liquid-glass-shadow);
    }

    .card-body { padding: 2rem; display: flex; flex-direction: column; gap: 1.5rem; }

    .form-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(240px, 1fr)); gap: 1.5rem; }
    .field-group { display: flex; flex-direction: column; gap: 0.5rem; }
    .field-label { font-size: 0.75rem; font-weight: 700; text-transform: uppercase; color: var(--text-secondary); letter-spacing: 0.05em; }

    .card-actions { display: flex; justify-content: flex-end; }

    .stats-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(280px, 1fr)); gap: 1.5rem; }
    
    .analytical-stat-card {
      padding: 2.5rem 2rem; background: var(--liquid-glass-bg); backdrop-filter: var(--liquid-glass-blur);
      border: var(--liquid-glass-border); border-radius: 28px; box-shadow: var(--liquid-glass-shadow);
      display: flex; flex-direction: column; gap: 0.5rem;
      transition: all 0.3s var(--spring-easing);
    }
    .analytical-stat-card:hover { transform: translateY(-4px); box-shadow: var(--liquid-glass-shadow-deep); }

    .stat-label { font-size: 0.8125rem; font-weight: 700; text-transform: uppercase; color: var(--text-secondary); letter-spacing: 0.08em; }
    .stat-value { font-size: 3rem; font-weight: 800; color: var(--text-primary); letter-spacing: -0.03em; }
    .stat-trend { display: flex; align-items: center; gap: 0.5rem; font-size: 0.875rem; font-weight: 600; color: var(--color-success); }
    .stat-trend ui5-icon { font-size: 1rem; }

    .table-wrapper { overflow-x: auto; border-radius: 20px; border: 1px solid rgba(0, 0, 0, 0.05); }
    .premium-table {
      width: 100%; border-collapse: collapse;
      th { text-align: left; padding: 1.25rem 1.5rem; font-size: 0.75rem; font-weight: 700; text-transform: uppercase; color: var(--text-secondary); border-bottom: 1px solid rgba(0, 0, 0, 0.05); }
      td { padding: 1.25rem 1.5rem; font-size: 0.95rem; border-bottom: 1px solid rgba(0, 0, 0, 0.03); color: var(--text-primary); }
      tr:last-child td { border-bottom: none; }
      .num { text-align: right; font-family: var(--sapFontFamilyMono, monospace); font-weight: 600; color: var(--color-primary); }
    }

    .glass-panel {
      background: var(--liquid-glass-bg);
      backdrop-filter: var(--liquid-glass-blur);
      -webkit-backdrop-filter: var(--liquid-glass-blur);
      border: var(--liquid-glass-border);
      box-shadow: var(--liquid-glass-shadow);
    }

    @media (max-width: 768px) {
      .ad-page { padding: 1.5rem; }
      .ad-header { flex-direction: column; align-items: flex-start; gap: 1rem; }
    }
  `],
})
export class AnalyticalDashboardComponent implements OnInit {
  private readonly mcpService = inject(McpService);
  private readonly destroyRef = inject(DestroyRef);
  readonly i18n = inject(I18nService);

  calcViews: string[] = [];
  selectedCalcView = '';
  dimensionsInput = '';
  measuresInput = '';
  aggregation = 'SUM';
  queryResult: AnalyticalResult | null = null;
  statCards: Array<{ label: string; value: string }> = [];
  loading = false;
  querying = false;
  error = '';

  ngOnInit(): void { this.loadCalcViews(); }

  loadCalcViews(): void {
    this.loading = true;
    this.mcpService.hanaListCalcViews().pipe(takeUntilDestroyed(this.destroyRef)).subscribe({
      next: result => { this.calcViews = result.calc_views || []; this.loading = false; },
      error: () => { this.error = this.i18n.t('analyticalDashboard.failedLoadCalcViews'); this.loading = false; },
    });
  }

  runQuery(): void {
    if (!this.selectedCalcView || !this.measuresInput.trim() || this.querying) return;
    this.querying = true;
    this.queryResult = null;
    this.statCards = [];
    this.error = '';
    const dimensions = this.dimensionsInput.split(',').map(d => d.trim()).filter(Boolean);
    const measures = this.measuresInput.split(',').map(m => m.trim()).filter(Boolean);
    this.mcpService.hanaAnalyticalQuery(this.selectedCalcView, dimensions, measures, this.aggregation)
      .pipe(takeUntilDestroyed(this.destroyRef)).subscribe({
        next: result => {
          this.queryResult = result;
          this.buildStatCards(result, measures);
          this.querying = false;
        },
        error: () => { this.error = this.i18n.t('analyticalDashboard.queryFailed'); this.querying = false; },
      });
  }

  private buildStatCards(result: AnalyticalResult, measures: string[]): void {
    if (!result.rows.length) return;
    this.statCards = measures.map(m => {
      const values = result.rows.map(r => Number(r[m]) || 0);
      const total = values.reduce((a, b) => a + b, 0);
      return { label: `${this.aggregation}(${m})`, value: total.toLocaleString() };
    });
  }

  isNumber(val: unknown): boolean {
    return typeof val === 'number';
  }

  formatCell(value: unknown): string {
    if (value == null) return '';
    if (typeof value === 'number') return value.toLocaleString();
    return String(value);
  }
}
