import { Component, CUSTOM_ELEMENTS_SCHEMA, DestroyRef, inject } from '@angular/core';
import { CommonModule } from '@angular/common';
import { FormsModule } from '@angular/forms';
import { Ui5TrainingComponentsModule } from '../../shared/ui5-training-components.module';
import { takeUntilDestroyed } from '@angular/core/rxjs-interop';
import { McpService, SparqlResult } from '../../services/mcp.service';
import { I18nService } from '../../services/i18n.service';
import { EmptyStateComponent } from '../../shared';
import { CrossAppLinkComponent } from '../../shared/cross-app-link.component';

@Component({
  selector: 'app-sparql-explorer',
  standalone: true,
  imports: [CommonModule, FormsModule, Ui5TrainingComponentsModule, EmptyStateComponent, CrossAppLinkComponent],
  schemas: [CUSTOM_ELEMENTS_SCHEMA],
  template: `
    <ui5-page background-design="Solid">
      <ui5-bar slot="header" design="Header">
        <ui5-title slot="startContent" level="H3">{{ i18n.t('sparql.title') }}</ui5-title>
      </ui5-bar>

      <app-cross-app-link
        targetApp="training"
        targetRoute="/analytical-dashboard"
        targetLabelKey="nav.analyticalDashboard"
        icon="chart-table-view">
      </app-cross-app-link>

      <div class="sparql-content" role="main" [attr.aria-label]="i18n.t('sparql.title')">
        <ui5-message-strip *ngIf="error" design="Negative" [hideCloseButton]="false" (close)="error = ''" role="alert">{{ error }}</ui5-message-strip>

        <ui5-card>
          <ui5-card-header slot="header" title-text="{{ i18n.t('sparql.queryInterface') }}" subtitle-text="{{ i18n.t('sparql.querySubtitle') }}"></ui5-card-header>
          <div class="card-content">
            <div class="field-group">
              <label class="field-label">{{ i18n.t('sparql.query') }}</label>
              <ui5-textarea ngDefaultControl name="sparqlQuery" [(ngModel)]="sparqlQuery" [rows]="6" placeholder="SELECT ?s ?p ?o WHERE { ?s ?p ?o } LIMIT 10" accessible-name="SPARQL query"></ui5-textarea>
            </div>
            <div class="actions">
              <ui5-button design="Emphasized" icon="play" (click)="executeQuery()" [disabled]="querying || !sparqlQuery.trim()">
                {{ querying ? i18n.t('sparql.running') : i18n.t('sparql.execute') }}
              </ui5-button>
              <ui5-button design="Transparent" (click)="setPreset('allTriples')">{{ i18n.t('sparql.presetAllTriples') }}</ui5-button>
              <ui5-button design="Transparent" (click)="setPreset('classes')">{{ i18n.t('sparql.presetClasses') }}</ui5-button>
              <ui5-button design="Transparent" (click)="setPreset('properties')">{{ i18n.t('sparql.presetProperties') }}</ui5-button>
            </div>

            @if (querying) {
              <div class="loading-container" role="status" aria-live="polite">
                <ui5-busy-indicator active size="M"></ui5-busy-indicator>
              </div>
            }

            @if (queryResult) {
              <div class="result-block">
                <h4>{{ i18n.t('sparql.results') }} ({{ queryResult.total }} {{ i18n.t('sparql.bindings') }})</h4>
                @if (queryResult.columns.length > 0 && queryResult.bindings.length > 0) {
                  <div class="table-wrapper">
                    <ui5-table aria-label="SPARQL results">
                      @for (col of queryResult.columns; track col) {
                        <ui5-table-header-cell><span>{{ col }}</span></ui5-table-header-cell>
                      }
                      @for (row of queryResult.bindings; track $index) {
                        <ui5-table-row>
                          @for (col of queryResult.columns; track col) {
                            <ui5-table-cell>{{ formatCell(row[col]) }}</ui5-table-cell>
                          }
                        </ui5-table-row>
                      }
                    </ui5-table>
                  </div>
                } @else {
                  <pre>{{ prettyPrint(queryResult.bindings) }}</pre>
                }
              </div>
            }
          </div>

          @if (!queryResult && !querying && !error) {
            <app-empty-state
              icon="syntax"
              [title]="i18n.t('sparql.emptyTitle')"
              [description]="i18n.t('sparql.emptyDesc')">
            </app-empty-state>
          }
        </ui5-card>
      </div>
    </ui5-page>
  `,
  styles: [`
    .sparql-content { padding: 1rem; max-width: 1200px; margin: 0 auto; display: flex; flex-direction: column; gap: 1rem; }
    .card-content { padding: 1rem; display: grid; gap: 1rem; }
    .field-group { display: grid; gap: 0.5rem; }
    .field-label { color: var(--sapContent_LabelColor); font-weight: 600; }
    .actions { display: flex; gap: 0.5rem; flex-wrap: wrap; }
    .result-block { display: grid; gap: 0.5rem; }
    .result-block h4 { margin: 0; }
    .table-wrapper { overflow-x: auto; }
    pre { margin: 0; white-space: pre-wrap; word-break: break-word; background: var(--sapShell_Background); padding: 0.75rem; border-radius: 0.5rem; border: 1px solid var(--sapList_BorderColor); font-size: var(--sapFontSmallSize); }
    ui5-message-strip { margin-bottom: 0.25rem; }

    .loading-container { display: flex; justify-content: center; padding: 2rem; }
    @media (max-width: 768px) {
      .sparql-content { padding: 0.75rem; }
    }
  `],
})
export class SparqlExplorerComponent {
  private readonly mcpService = inject(McpService);
  private readonly destroyRef = inject(DestroyRef);
  readonly i18n = inject(I18nService);

  sparqlQuery = 'SELECT ?s ?p ?o WHERE { ?s ?p ?o } LIMIT 10';
  queryResult: SparqlResult | null = null;
  querying = false;
  error = '';

  private readonly presets: Record<string, string> = {
    allTriples: 'SELECT ?s ?p ?o WHERE { ?s ?p ?o } LIMIT 10',
    classes: 'SELECT DISTINCT ?class WHERE { ?s a ?class } ORDER BY ?class LIMIT 50',
    properties: 'SELECT DISTINCT ?prop WHERE { ?s ?prop ?o } ORDER BY ?prop LIMIT 50',
  };

  setPreset(key: string): void {
    this.sparqlQuery = this.presets[key] || this.sparqlQuery;
  }

  executeQuery(): void {
    if (!this.sparqlQuery.trim() || this.querying) return;
    this.querying = true;
    this.queryResult = null;
    this.error = '';
    this.mcpService.hanaSparqlQuery(this.sparqlQuery).pipe(takeUntilDestroyed(this.destroyRef)).subscribe({
      next: result => { this.queryResult = result; this.querying = false; },
      error: () => { this.error = this.i18n.t('sparql.queryFailed'); this.querying = false; },
    });
  }

  formatCell(value: unknown): string {
    if (value == null) return '';
    if (typeof value === 'object') return JSON.stringify(value);
    return String(value);
  }

  prettyPrint(value: unknown): string {
    try { return JSON.stringify(value, null, 2); } catch { return String(value); }
  }
}
