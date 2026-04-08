import { Component, CUSTOM_ELEMENTS_SCHEMA, DestroyRef, OnInit, inject } from '@angular/core';
import { CommonModule } from '@angular/common';
import { FormsModule } from '@angular/forms';
import { Ui5TrainingComponentsModule } from '../../shared/ui5-training-components.module';
import { takeUntilDestroyed } from '@angular/core/rxjs-interop';
import { EmptyStateComponent, CrossAppLinkComponent } from '../../shared';
import { McpService, SchemaTable, SchemaColumn } from '../../services/mcp.service';
import { I18nService } from '../../services/i18n.service';

@Component({
  selector: 'app-schema-browser',
  standalone: true,
  imports: [CommonModule, FormsModule, Ui5TrainingComponentsModule, EmptyStateComponent, CrossAppLinkComponent],
  schemas: [CUSTOM_ELEMENTS_SCHEMA],
  template: `
    <ui5-page background-design="Solid">
      <ui5-bar slot="header" design="Header">
        <ui5-title slot="startContent" level="H3">{{ i18n.t('schemaBrowser.title') }}</ui5-title>
        <ui5-button slot="endContent" icon="refresh" (click)="loadTables()" [disabled]="loading">
          {{ loading ? i18n.t('common.loading') : i18n.t('common.refresh') }}
        </ui5-button>
      </ui5-bar>

      <app-cross-app-link
        targetApp="training"
        targetRoute="/data-quality"
        targetLabelKey="nav.dataQuality"
        icon="quality-issue">
      </app-cross-app-link>

      <div class="sb-content" role="main" aria-label="Schema Browser">
        <ui5-message-strip *ngIf="error" design="Negative" [hideCloseButton]="false" (close)="error = ''" role="alert">{{ error }}</ui5-message-strip>

        <div class="columns">
          <!-- Table List -->
          <ui5-card class="tables-card">
            <ui5-card-header slot="header" title-text="{{ i18n.t('schemaBrowser.tables') }}" [additionalText]="tableNames.length + ''"></ui5-card-header>
            <ui5-list *ngIf="tableNames.length > 0; else noTables" mode="SingleSelect" (item-click)="onTableSelect($event)" aria-label="HANA tables">
              <ui5-li *ngFor="let table of tableNames; trackBy: trackByTable" [selected]="table === selectedTableName">
                {{ table }}
              </ui5-li>
            </ui5-list>
            <ng-template #noTables>
              <app-empty-state icon="database" [title]="i18n.t('schemaBrowser.noTables')" [description]="i18n.t('schemaBrowser.noTablesDesc')"></app-empty-state>
            </ng-template>
          </ui5-card>

          <!-- Column Details -->
          <div class="detail-col">
            @if (selectedSchema) {
              <ui5-card>
                <ui5-card-header slot="header" [titleText]="selectedSchema.name" subtitle-text="{{ i18n.t('schemaBrowser.columnDetails') }}"
                  [additionalText]="selectedSchema.columns.length + ' columns'"></ui5-card-header>
                <div class="card-content">
                  <div class="actions-row">
                    <ui5-button design="Emphasized" icon="generate-shortcut" (click)="generateAnnotations()" [disabled]="generating">
                      {{ generating ? i18n.t('schemaBrowser.generating') : i18n.t('schemaBrowser.generateAnnotations') }}
                    </ui5-button>
                    @if (generatedAnnotations) {
                      <ui5-button design="Positive" icon="accept" (click)="validateAnnotations()" [disabled]="validating">
                        {{ validating ? i18n.t('schemaBrowser.validating') : i18n.t('schemaBrowser.validate') }}
                      </ui5-button>
                    }
                  </div>

                  <ui5-table aria-label="Table columns">
                    <ui5-table-header-cell><span>{{ i18n.t('schemaBrowser.column') }}</span></ui5-table-header-cell>
                    <ui5-table-header-cell><span>{{ i18n.t('schemaBrowser.sqlType') }}</span></ui5-table-header-cell>
                    <ui5-table-header-cell><span>{{ i18n.t('schemaBrowser.nullable') }}</span></ui5-table-header-cell>
                    <ui5-table-header-cell><span>{{ i18n.t('schemaBrowser.annotations') }}</span></ui5-table-header-cell>
                    @for (col of selectedSchema.columns; track col.name) {
                      <ui5-table-row>
                        <ui5-table-cell><strong>{{ col.name }}</strong></ui5-table-cell>
                        <ui5-table-cell><code>{{ col.sql_type }}</code></ui5-table-cell>
                        <ui5-table-cell>{{ col.nullable ? i18n.t('schemaBrowser.yes') : i18n.t('schemaBrowser.no') }}</ui5-table-cell>
                        <ui5-table-cell>
                          <div class="badge-row">
                            @if (hasAnnotation(col, 'Analytics.Dimension')) {
                              <ui5-badge color-scheme="6">Dimension</ui5-badge>
                            }
                            @if (hasAnnotation(col, 'Analytics.Measure')) {
                              <ui5-badge color-scheme="8">Measure</ui5-badge>
                            }
                            @if (hasAnnotation(col, 'PersonalData.IsPotentiallyPersonal')) {
                              <ui5-badge color-scheme="2">Personal</ui5-badge>
                            }
                            @if (hasAnnotation(col, 'PersonalData.IsPotentiallySensitive')) {
                              <ui5-badge color-scheme="1">Sensitive</ui5-badge>
                            }
                            @if (hasAnnotation(col, 'Common.Label')) {
                              <ui5-badge color-scheme="5">{{ getAnnotation(col, 'Common.Label') }}</ui5-badge>
                            }
                          </div>
                        </ui5-table-cell>
                      </ui5-table-row>
                    }
                  </ui5-table>
                </div>
              </ui5-card>

              @if (generatedAnnotations) {
                <ui5-card>
                  <ui5-card-header slot="header" title-text="{{ i18n.t('schemaBrowser.generatedAnnotations') }}"></ui5-card-header>
                  <div class="card-content">
                    @if (validationResult) {
                      <ui5-message-strip [design]="validationResult.valid ? 'Positive' : 'Negative'">
                        {{ validationResult.valid ? i18n.t('schemaBrowser.validAnnotations') : i18n.t('schemaBrowser.invalidAnnotations') }}
                      </ui5-message-strip>
                    }
                    <pre>{{ generatedAnnotations }}</pre>
                  </div>
                </ui5-card>
              }
            } @else {
              <app-empty-state icon="table-view" [title]="i18n.t('schemaBrowser.selectTable')" [description]="i18n.t('schemaBrowser.selectTableDesc')"></app-empty-state>
            }
          </div>
        </div>
      </div>
    </ui5-page>
  `,
  styles: [`
    .sb-content { padding: 1rem; max-width: 1400px; margin: 0 auto; display: flex; flex-direction: column; gap: 1rem; }
    .columns { display: grid; gap: 1rem; grid-template-columns: minmax(240px, 300px) minmax(0, 1fr); }
    .detail-col { display: flex; flex-direction: column; gap: 1rem; }
    .card-content { padding: 1rem; display: grid; gap: 1rem; }
    .actions-row { display: flex; gap: 0.5rem; flex-wrap: wrap; }
    .badge-row { display: flex; gap: 0.25rem; flex-wrap: wrap; }
    pre { margin: 0; white-space: pre-wrap; word-break: break-word; background: var(--sapShell_Background); padding: 0.75rem; border-radius: 0.5rem; border: 1px solid var(--sapList_BorderColor); font-size: var(--sapFontSmallSize); }
    ui5-message-strip { margin-bottom: 0.25rem; }
    @media (max-width: 960px) { .columns { grid-template-columns: 1fr; } }
  `],
})
export class SchemaBrowserComponent implements OnInit {
  private readonly mcpService = inject(McpService);
  private readonly destroyRef = inject(DestroyRef);
  readonly i18n = inject(I18nService);

  tableNames: string[] = [];
  selectedTableName = '';
  selectedSchema: SchemaTable | null = null;
  generatedAnnotations: string | null = null;
  validationResult: { valid: boolean; errors?: string[] } | null = null;
  loading = false;
  loadingSchema = false;
  generating = false;
  validating = false;
  error = '';

  ngOnInit(): void { this.loadTables(); }

  loadTables(): void {
    this.loading = true;
    this.mcpService.hanaListTables().pipe(takeUntilDestroyed(this.destroyRef)).subscribe({
      next: tables => { this.tableNames = tables || []; this.loading = false; },
      error: () => { this.error = this.i18n.t('schemaBrowser.failedLoadTables'); this.loading = false; },
    });
  }

  onTableSelect(event: Event & { detail?: { item?: Element } }): void {
    const text = event.detail?.item?.textContent?.trim();
    if (!text || text === this.selectedTableName) return;
    this.selectedTableName = text;
    this.generatedAnnotations = null;
    this.validationResult = null;
    this.loadingSchema = true;
    this.mcpService.hanaGetTableSchema(text).pipe(takeUntilDestroyed(this.destroyRef)).subscribe({
      next: schema => { this.selectedSchema = schema; this.loadingSchema = false; },
      error: () => { this.error = this.i18n.t('schemaBrowser.failedLoadSchema'); this.loadingSchema = false; },
    });
  }

  generateAnnotations(): void {
    if (!this.selectedSchema || this.generating) return;
    this.generating = true;
    this.validationResult = null;
    const props = this.selectedSchema.columns.map(c => c.name);
    this.mcpService.generateAnnotations(this.selectedSchema.name, props).pipe(takeUntilDestroyed(this.destroyRef)).subscribe({
      next: result => { this.generatedAnnotations = result.annotations; this.generating = false; },
      error: () => { this.error = this.i18n.t('schemaBrowser.failedGenerate'); this.generating = false; },
    });
  }

  validateAnnotations(): void {
    if (!this.generatedAnnotations || this.validating) return;
    this.validating = true;
    this.mcpService.validateAnnotations(this.generatedAnnotations).pipe(takeUntilDestroyed(this.destroyRef)).subscribe({
      next: result => { this.validationResult = result; this.validating = false; },
      error: () => { this.error = this.i18n.t('schemaBrowser.failedValidate'); this.validating = false; },
    });
  }

  hasAnnotation(col: SchemaColumn, key: string): boolean {
    return !!col.annotations?.[key];
  }

  getAnnotation(col: SchemaColumn, key: string): string {
    const val = col.annotations?.[key];
    return typeof val === 'string' ? val : JSON.stringify(val);
  }

  trackByTable(index: number, table: string): string { return table; }
}
