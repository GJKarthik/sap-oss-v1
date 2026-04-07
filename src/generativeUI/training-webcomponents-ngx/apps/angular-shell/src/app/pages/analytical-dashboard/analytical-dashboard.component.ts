import { Component, CUSTOM_ELEMENTS_SCHEMA, DestroyRef, OnInit, inject } from '@angular/core';
import { CommonModule } from '@angular/common';
import { FormsModule } from '@angular/forms';
import { Ui5WebcomponentsModule } from '@ui5/webcomponents-ngx';
import { takeUntilDestroyed } from '@angular/core/rxjs-interop';
import { EmptyStateComponent, CrossAppLinkComponent } from '../../shared';
import { McpService, AnalyticalResult } from '../../services/mcp.service';
import { I18nService } from '../../services/i18n.service';

@Component({
  selector: 'app-analytical-dashboard',
  standalone: true,
  imports: [CommonModule, FormsModule, Ui5WebcomponentsModule, EmptyStateComponent, CrossAppLinkComponent],
  schemas: [CUSTOM_ELEMENTS_SCHEMA],
  template: `
    <ui5-page background-design="Solid">
      <ui5-bar slot="header" design="Header">
        <ui5-title slot="startContent" level="H3">{{ i18n.t('analyticalDashboard.title') }}</ui5-title>
        <ui5-button slot="endContent" icon="refresh" (click)="loadCalcViews()" [disabled]="loading">
          {{ loading ? i18n.t('common.loading') : i18n.t('common.refresh') }}
        </ui5-button>
      </ui5-bar>

      <app-cross-app-link
        targetApp="training"
        targetRoute="/schema-browser"
        targetLabel="Schema Browser"
        icon="database"
        relationLabel="Related:">
      </app-cross-app-link>

      <div class="ad-content" role="main" aria-label="Analytical Dashboard">
        <ui5-message-strip *ngIf="error" design="Negative" [hideCloseButton]="false" (close)="error = ''" role="alert">{{ error }}</ui5-message-strip>

        <!-- Query Builder -->
        <ui5-card>
          <ui5-card-header slot="header" title-text="{{ i18n.t('analyticalDashboard.queryBuilder') }}" subtitle-text="{{ i18n.t('analyticalDashboard.queryBuilderSubtitle') }}"></ui5-card-header>
          <div class="card-content">
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
                <ui5-input ngDefaultControl name="dimensions" [(ngModel)]="dimensionsInput" placeholder="{{ i18n.t('analyticalDashboard.dimensionsPlaceholder') }}" accessible-name="Dimensions (comma-separated)"></ui5-input>
              </div>
              <div class="field-group">
                <label class="field-label">{{ i18n.t('analyticalDashboard.measures') }}</label>
                <ui5-input ngDefaultControl name="measures" [(ngModel)]="measuresInput" placeholder="{{ i18n.t('analyticalDashboard.measuresPlaceholder') }}" accessible-name="Measures (comma-separated)"></ui5-input>
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
            <ui5-button design="Emphasized" icon="play" (click)="runQuery()" [disabled]="querying || !selectedCalcView || !measuresInput.trim()">
              {{ querying ? i18n.t('analyticalDashboard.querying') : i18n.t('analyticalDashboard.runQuery') }}
            </ui5-button>
          </div>
        </ui5-card>

        <!-- Results -->
        @if (queryResult) {
          <!-- Stat Cards -->
          @if (statCards.length > 0) {
            <div class="stats-row">
              @for (stat of statCards; track stat.label) {
                <div class="stat-card">
                  <span class="stat-value">{{ stat.value }}</span>
                  <span class="stat-label">{{ stat.label }}</span>
                </div>
              }
            </div>
          }

          <!-- Results Table -->
          <ui5-card>
            <ui5-card-header slot="header" title-text="{{ i18n.t('analyticalDashboard.results') }}"
              [additionalText]="queryResult.total + ' rows'" [subtitleText]="aggregation + ' aggregation'"></ui5-card-header>
            @if (queryResult.rows.length > 0) {
              <div class="table-wrapper">
                <ui5-table aria-label="Analytical results">
                  @for (col of queryResult.columns; track col) {
                    <ui5-table-header-cell><span>{{ col }}</span></ui5-table-header-cell>
                  }
                  @for (row of queryResult.rows; track $index) {
                    <ui5-table-row>
                      @for (col of queryResult.columns; track col) {
                        <ui5-table-cell>{{ formatCell(row[col]) }}</ui5-table-cell>
                      }
                    </ui5-table-row>
                  }
                </ui5-table>
              </div>
            } @else {
              <app-empty-state icon="table-chart" [title]="i18n.t('analyticalDashboard.noResults')" [description]="i18n.t('analyticalDashboard.noResultsDesc')"></app-empty-state>
            }
          </ui5-card>
        }
      </div>
    </ui5-page>
  `,
  styles: [`
    .ad-content { padding: 1rem; max-width: 1400px; margin: 0 auto; display: flex; flex-direction: column; gap: 1rem; }
    .card-content { padding: 1rem; display: grid; gap: 1rem; }
    .form-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(220px, 1fr)); gap: 1rem; }
    .field-group { display: grid; gap: 0.5rem; }
    .field-label { color: var(--sapContent_LabelColor); font-weight: 600; }
    .stats-row { display: grid; grid-template-columns: repeat(auto-fit, minmax(180px, 1fr)); gap: 1rem; }
    .stat-card { text-align: center; padding: 1.25rem; background: var(--sapBackgroundColor); border-radius: 0.75rem; border: 1px solid var(--sapList_BorderColor); }
    .stat-value { display: block; font-size: 1.75rem; font-weight: 700; color: var(--sapBrandColor); }
    .stat-label { font-size: 0.875rem; color: var(--sapContent_LabelColor); }
    .table-wrapper { overflow-x: auto; }
    ui5-message-strip { margin-bottom: 0.25rem; }
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

  formatCell(value: unknown): string {
    if (value == null) return '';
    if (typeof value === 'number') return value.toLocaleString();
    return String(value);
  }
}
