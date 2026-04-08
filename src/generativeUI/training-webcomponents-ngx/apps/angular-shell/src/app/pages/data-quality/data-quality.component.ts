import { Component, CUSTOM_ELEMENTS_SCHEMA, DestroyRef, OnInit, inject } from '@angular/core';
import { CommonModule } from '@angular/common';
import { FormsModule } from '@angular/forms';
import { Ui5TrainingComponentsModule } from '../../shared/ui5-training-components.module';
import { takeUntilDestroyed } from '@angular/core/rxjs-interop';
import { EmptyStateComponent, CrossAppLinkComponent } from '../../shared';
import { McpService, PendingApproval, SchemaTable } from '../../services/mcp.service';
import { I18nService } from '../../services/i18n.service';
import { ApiService } from '../../services/api.service';
import { ToastService } from '../../services/toast.service';

@Component({
  selector: 'app-data-quality',
  standalone: true,
  imports: [CommonModule, FormsModule, Ui5TrainingComponentsModule, EmptyStateComponent, CrossAppLinkComponent],
  schemas: [CUSTOM_ELEMENTS_SCHEMA],
  template: `
    <ui5-page background-design="Solid" class="dq-aura-bg">
      <ui5-bar slot="header" design="Header">
        <ui5-title slot="startContent" level="H3">{{ i18n.t('dataQuality.title') }}</ui5-title>
        <div slot="endContent" style="display: flex; gap: 0.5rem; align-items: center;">
          <ui5-tag design="Information">{{ i18n.t('dataQuality.hanaTag') }}</ui5-tag>
        </div>
      </ui5-bar>

      <app-cross-app-link
        targetApp="training"
        targetRoute="/schema-browser"
        targetLabelKey="nav.schemaBrowser"
        icon="database">
      </app-cross-app-link>

      <div class="dq-studio-container" role="main">
        <!-- Hero Section -->
        <section class="glass-card hero-cinematic">
          <div class="hero-content">
            <span class="eyebrow-chip">{{ i18n.t('dataQuality.coreWorkflow') }}</span>
            <ui5-title level="H2">{{ i18n.t('dataQuality.heroTitle') }}</ui5-title>
            <p class="text-muted">{{ i18n.t('dataQuality.heroDescription') }}</p>
          </div>
          <div class="hero-visual">
            <ui5-icon name="quality-issue" class="hero-glow-icon"></ui5-icon>
          </div>
        </section>

        <ui5-tabcontainer fixed (tab-select)="onTabSelect($event)" style="margin-top: 1rem;">
          <ui5-tab text="{{ i18n.t('dataQuality.validation') }}" icon="validate" selected></ui5-tab>
          <ui5-tab text="{{ i18n.t('dataQuality.profiling') }}" icon="pie-chart"></ui5-tab>
          <ui5-tab text="{{ i18n.t('dataQuality.anomalies') }}" icon="alert"></ui5-tab>
          <ui5-tab text="{{ i18n.t('dataQuality.approvals') }}" icon="accept"></ui5-tab>
        </ui5-tabcontainer>

        <div class="tab-content-area">
          @if (error) {
            <ui5-message-strip design="Negative" (close)="error = ''" class="mb-1">{{ error }}</ui5-message-strip>
          }

          <!-- Dynamic Tab Panes -->
          <div class="glass-card main-panel">
            <!-- Validation -->
            @if (activeTab === 0) {
              <div class="studio-pane">
                <div class="pane-toolbar">
                  <ui5-title level="H4">{{ i18n.t('dataQuality.validation') }}</ui5-title>
                  <div class="toolbar-actions">
                    <ui5-select ngDefaultControl name="vTable" [(ngModel)]="selectedTable" class="table-select">
                      @for (t of tables; track t) { <ui5-option [value]="t">{{ t }}</ui5-option> }
                    </ui5-select>
                    <ui5-button design="Emphasized" (click)="runValidation()" [disabled]="validating || !selectedTable">
                      {{ validating ? i18n.t('dataQuality.runningValidation') : i18n.t('dataQuality.runValidation') }}
                    </ui5-button>
                  </div>
                </div>

                @if (validationResult) {
                  <div class="results-grid fadeIn">
                    <div class="code-block-container">
                      <div class="block-header">
                        <span>{{ i18n.t('dataQuality.validationResults') }}</span>
                        <ui5-button design="Attention" icon="ai" (click)="requestMagicFix(0)" [disabled]="magicFixLoading[0]">
                          {{ magicFixLoading[0] ? i18n.t('dataQuality.magicFix.analyzing') : i18n.t('dataQuality.magicFix.aiButton') }}
                        </ui5-button>
                      </div>
                      <pre class="terminal-code">{{ prettyPrint(validationResult) }}</pre>
                    </div>

                    @if (magicFixResult[0]) {
                      <div class="ai-suggestion-card slideIn">
                        <div class="ai-header"><ui5-icon name="ai"></ui5-icon> {{ i18n.t('dataQuality.magicFix.remediationTitle') }}</div>
                        <pre class="ai-code">{{ magicFixResult[0] }}</pre>
                        <div class="ai-footer">
                          <ui5-button design="Positive" (click)="applyMagicFix(0)">{{ i18n.t('dataQuality.magicFix.applyCorrection') }}</ui5-button>
                          <ui5-button design="Transparent" (click)="dismissMagicFix(0)">{{ i18n.t('dataQuality.magicFix.dismiss') }}</ui5-button>
                        </div>
                      </div>
                    }
                  </div>
                } @else {
                  <app-empty-state icon="validate" [title]="i18n.t('dataQuality.noValidation')" [description]="i18n.t('dataQuality.noValidationDesc')"></app-empty-state>
                }
              </div>
            }

            <!-- Profiling -->
            @if (activeTab === 1) {
              <div class="studio-pane">
                <div class="pane-toolbar">
                  <ui5-title level="H4">{{ i18n.t('dataQuality.dataProfiling') }}</ui5-title>
                  <div class="toolbar-actions">
                    <ui5-select ngDefaultControl name="pTable" [(ngModel)]="selectedTable">
                      @for (t of tables; track t) { <ui5-option [value]="t">{{ t }}</ui5-option> }
                    </ui5-select>
                    <ui5-input ngDefaultControl name="sSize" [(ngModel)]="sampleSize" type="Number" style="width: 100px;"></ui5-input>
                    <ui5-button design="Emphasized" (click)="runProfiling()" [disabled]="profiling">{{ i18n.t('dataQuality.analyzeStats') }}</ui5-button>
                  </div>
                </div>
                @if (profilingResult) {
                  <pre class="terminal-code fadeIn">{{ prettyPrint(profilingResult) }}</pre>
                }
              </div>
            }

            <!-- Anomalies -->
            @if (activeTab === 2) {
              <div class="studio-pane">
                <div class="pane-toolbar">
                  <ui5-title level="H4">{{ i18n.t('dataQuality.anomalyDetection') }}</ui5-title>
                  <div class="toolbar-actions">
                    <ui5-select ngDefaultControl name="aTable" [(ngModel)]="selectedTable">
                      @for (t of tables; track t) { <ui5-option [value]="t">{{ t }}</ui5-option> }
                    </ui5-select>
                    <ui5-input ngDefaultControl name="aCol" [(ngModel)]="anomalyColumn" placeholder="Column Name"></ui5-input>
                    <ui5-button design="Emphasized" (click)="detectAnomalies()" [disabled]="detecting">{{ i18n.t('dataQuality.detectPatterns') }}</ui5-button>
                  </div>
                </div>
                @if (anomalyResult) {
                  <pre class="terminal-code fadeIn">{{ prettyPrint(anomalyResult) }}</pre>
                }
              </div>
            }

            <!-- Approvals -->
            @if (activeTab === 3) {
              <div class="studio-pane">
                <ui5-title level="H4" style="margin-bottom: 1rem;">{{ i18n.t('dataQuality.humanApprovals') }}</ui5-title>
                @if (pendingApprovals.length > 0) {
                  <ui5-table aria-label="Pending approvals">
                    <ui5-table-header-cell><span>ID</span></ui5-table-header-cell>
                    <ui5-table-header-cell><span>{{ i18n.t('dataQuality.origin') }}</span></ui5-table-header-cell>
                    <ui5-table-header-cell><span>{{ i18n.t('dataQuality.table') }}</span></ui5-table-header-cell>
                    <ui5-table-header-cell><span>{{ i18n.t('dataQuality.impact') }}</span></ui5-table-header-cell>
                    <ui5-table-header-cell><span>{{ i18n.t('dataQuality.action') }}</span></ui5-table-header-cell>
                    @for (a of pendingApprovals; track a.id) {
                      <ui5-table-row>
                        <ui5-table-cell><code>{{ a.id | slice:0:8 }}</code></ui5-table-cell>
                        <ui5-table-cell><ui5-tag design="Information">{{ a.tool }}</ui5-tag></ui5-table-cell>
                        <ui5-table-cell><strong>{{ a.table_name }}</strong></ui5-table-cell>
                        <ui5-table-cell>{{ a.estimated_rows }} {{ i18n.t('dataQuality.rows') }}</ui5-table-cell>
                        <ui5-table-cell>
                          <div style="display: flex; gap: 0.25rem;">
                            <ui5-button design="Positive" icon="accept" (click)="approveQuery(a)"></ui5-button>
                            <ui5-button design="Negative" icon="decline" (click)="rejectQuery(a)"></ui5-button>
                          </div>
                        </ui5-table-cell>
                      </ui5-table-row>
                    }
                  </ui5-table>
                } @else {
                  <app-empty-state icon="accept" [title]="i18n.t('dataQuality.queueClear')" [description]="i18n.t('dataQuality.queueClearDesc')"></app-empty-state>
                }
              </div>
            }
          </div>
        </div>
      </div>
    </ui5-page>
  `,
  styles: [`
    .dq-aura-bg {
      background: radial-gradient(circle at 0% 0%, rgba(0, 143, 211, 0.06) 0%, transparent 30%),
                  radial-gradient(circle at 100% 100%, rgba(8, 130, 95, 0.04) 0%, transparent 30%),
                  var(--sapBackgroundColor);
    }
    .dq-studio-container { padding: 1.5rem; max-width: 1400px; margin: 0 auto; display: flex; flex-direction: column; gap: 1rem; }
    
    .glass-card {
      background: rgba(255, 255, 255, 0.72);
      backdrop-filter: blur(12px);
      border: 1px solid rgba(255, 255, 255, 0.4);
      border-radius: 1rem;
      box-shadow: 0 8px 32px rgba(0, 0, 0, 0.04);
    }

    .hero-cinematic { padding: 2rem; display: flex; justify-content: space-between; align-items: center; overflow: hidden; }
    .hero-content { flex: 1; display: grid; gap: 0.5rem; }
    .eyebrow-chip { width: fit-content; padding: 0.25rem 0.75rem; border-radius: 99px; background: var(--sapBrandColor); color: #fff; font-size: 0.7rem; font-weight: 700; text-transform: uppercase; }
    .hero-glow-icon { font-size: 5rem; color: var(--sapBrandColor); opacity: 0.15; filter: drop-shadow(0 0 12px var(--sapBrandColor)); }

    .tab-content-area { animation: fadeIn 0.4s ease-out; }
    .main-panel { padding: 1.5rem; min-height: 500px; }
    
    .studio-pane { display: flex; flex-direction: column; gap: 1.5rem; }
    .pane-toolbar { display: flex; justify-content: space-between; align-items: center; flex-wrap: wrap; gap: 1rem; padding-bottom: 1rem; border-bottom: 1px solid var(--sapList_BorderColor); }
    .toolbar-actions { display: flex; gap: 0.5rem; align-items: center; }
    .table-select { width: 250px; }

    .results-grid { display: grid; grid-template-columns: 1fr; gap: 1.5rem; }
    @media (min-width: 1200px) { .results-grid { grid-template-columns: 1fr 400px; } }

    .terminal-code { 
      background: #1e1e1e; color: #9cdcfe; padding: 1.5rem; border-radius: 0.75rem; 
      font-family: monospace; font-size: 0.8125rem; line-height: 1.6; max-height: 600px; overflow-y: auto;
      box-shadow: inset 0 2px 10px rgba(0,0,0,0.2);
    }

    .ai-suggestion-card { 
      background: linear-gradient(135deg, #fff, #f0f7ff); border: 1px solid var(--sapBrandColor); 
      border-radius: 1rem; padding: 1.25rem; display: flex; flex-direction: column; gap: 1rem;
      box-shadow: 0 10px 20px rgba(8, 84, 160, 0.1);
    }
    .ai-header { display: flex; align-items: center; gap: 0.5rem; font-weight: bold; color: var(--sapBrandColor); }
    .ai-code { background: #fff; padding: 1rem; border-radius: 0.5rem; border: 1px dashed var(--sapBrandColor); font-size: 0.75rem; max-height: 300px; overflow-y: auto; }
    .ai-footer { display: flex; justify-content: flex-end; gap: 0.5rem; }

    .fadeIn { animation: fadeIn 0.5s ease-out; }
    .slideIn { animation: slideIn 0.4s ease-out; }
    @keyframes fadeIn { from { opacity: 0; } to { opacity: 1; } }
    @keyframes slideIn { from { opacity: 0; transform: translateX(20px); } to { opacity: 1; transform: translateX(0); } }
    .mb-1 { margin-bottom: 1rem; }
  `],
})
export class DataQualityComponent implements OnInit {
  private readonly mcpService = inject(McpService);
  private readonly apiService = inject(ApiService);
  private readonly destroyRef = inject(DestroyRef);
  readonly i18n = inject(I18nService);
  private readonly toast = inject(ToastService);

  tables: string[] = [];
  selectedTable = '';
  activeTab = 0;
  error = '';

  validating = false;
  validationResult: unknown = null;
  profiling = false;
  profilingResult: unknown = null;
  sampleSize = '1000';
  detecting = false;
  anomalyResult: unknown = null;
  anomalyColumn = '';
  anomalyMethod = 'zscore';
  pendingApprovals: PendingApproval[] = [];
  mutating = false;
  schemaPreview: SchemaTable | null = null;
  magicFixLoading: Record<number, boolean> = {};
  magicFixResult: Record<number, string | null> = {};
  magicFixError: Record<number, string> = {};

  ngOnInit(): void { this.loadTables(); }

  onTabSelect(event: CustomEvent): void {
    const tabs = ['validation', 'profiling', 'anomalies', 'approvals'];
    const text = event.detail?.tab?.getAttribute('text')?.toLowerCase() ?? '';
    const idx = tabs.findIndex(t => text.includes(t));
    this.activeTab = idx >= 0 ? idx : 0;
    if (this.activeTab === 3) this.loadApprovals();
  }

  loadTables(): void {
    this.mcpService.hanaListTables().pipe(takeUntilDestroyed(this.destroyRef)).subscribe({
      next: ts => { this.tables = ts || []; if (ts.length > 0 && !this.selectedTable) { this.selectedTable = ts[0]; this.loadSchemaPreview(ts[0]); } },
      error: () => { this.error = this.i18n.t('dataQuality.failedLoadTables'); }
    });
  }

  loadSchemaPreview(t: string): void { this.mcpService.hanaGetTableSchema(t).pipe(takeUntilDestroyed(this.destroyRef)).subscribe(s => this.schemaPreview = s); }
  loadApprovals(): void { this.mcpService.fetchPendingApprovals().pipe(takeUntilDestroyed(this.destroyRef)).subscribe(as => this.pendingApprovals = as); }

  runValidation(): void {
    if (!this.selectedTable || this.validating) return;
    this.validating = true; this.validationResult = null;
    this.mcpService.runDataQualityValidation(this.selectedTable).pipe(takeUntilDestroyed(this.destroyRef)).subscribe({
      next: r => { this.validationResult = r; this.validating = false; },
      error: () => { this.error = this.i18n.t('dataQuality.failedValidation'); this.validating = false; }
    });
  }

  runProfiling(): void {
    if (!this.selectedTable || this.profiling) return;
    this.profiling = true; this.profilingResult = null;
    this.mcpService.runDataProfiling(this.selectedTable, parseInt(this.sampleSize, 10) || 1000).pipe(takeUntilDestroyed(this.destroyRef)).subscribe({
      next: r => { this.profilingResult = r; this.profiling = false; },
      error: () => { this.error = this.i18n.t('dataQuality.failedProfiling'); this.profiling = false; }
    });
  }

  detectAnomalies(): void {
    if (!this.selectedTable || !this.anomalyColumn || this.detecting) return;
    this.detecting = true; this.anomalyResult = null;
    this.mcpService.detectAnomalies(this.selectedTable, this.anomalyColumn, this.anomalyMethod).pipe(takeUntilDestroyed(this.destroyRef)).subscribe({
      next: r => { this.anomalyResult = r; this.detecting = false; },
      error: () => { this.error = this.i18n.t('dataQuality.failedAnomalyDetection'); this.detecting = false; }
    });
  }

  approveQuery(a: PendingApproval): void {
    this.mutating = true;
    this.mcpService.approveQuery(a.id).pipe(takeUntilDestroyed(this.destroyRef)).subscribe({
      next: () => { this.pendingApprovals = this.pendingApprovals.filter(x => x.id !== a.id); this.mutating = false; },
      error: () => { this.toast.error(this.i18n.t('dataQuality.operationFailed')); this.mutating = false; }
    });
  }

  rejectQuery(a: PendingApproval): void {
    this.mutating = true;
    this.mcpService.rejectQuery(a.id).pipe(takeUntilDestroyed(this.destroyRef)).subscribe({
      next: () => { this.pendingApprovals = this.pendingApprovals.filter(x => x.id !== a.id); this.mutating = false; },
      error: () => { this.toast.error(this.i18n.t('dataQuality.operationFailed')); this.mutating = false; }
    });
  }

  requestMagicFix(tab: number): void {
    const results = [this.validationResult, this.profilingResult, this.anomalyResult];
    const result = results[tab]; if (!result) return;
    this.magicFixLoading[tab] = true; this.magicFixResult[tab] = null;
    this.apiService.post<any>('/v1/chat/completions', {
      model: 'default',
      messages: [{ role: 'system', content: 'Suggest SQL fix for DQ issue.' }, { role: 'user', content: JSON.stringify(result) }]
    }).pipe(takeUntilDestroyed(this.destroyRef)).subscribe({
      next: r => { this.magicFixResult[tab] = r.choices?.[0]?.message?.content; this.magicFixLoading[tab] = false; },
      error: () => { this.toast.error(this.i18n.t('dataQuality.operationFailed')); this.magicFixLoading[tab] = false; }
    });
  }

  applyMagicFix(tab: number): void {
    const sql = this.magicFixResult[tab] || '';
    this.mcpService.submitApproval({ tool: 'magic-fix', table_name: this.selectedTable, sql, estimated_rows: 0 }).subscribe({
      next: () => { this.dismissMagicFix(tab); this.loadApprovals(); },
      error: () => { this.toast.error(this.i18n.t('dataQuality.operationFailed')); }
    });
  }

  dismissMagicFix(tab: number): void { this.magicFixResult[tab] = null; this.magicFixLoading[tab] = false; }
  prettyPrint(v: unknown): string { return JSON.stringify(v, null, 2); }
}
