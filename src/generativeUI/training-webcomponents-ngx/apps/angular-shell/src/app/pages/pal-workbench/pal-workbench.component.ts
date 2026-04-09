import { Component, DestroyRef, OnInit, inject } from '@angular/core';
import { CommonModule } from '@angular/common';
import { FormsModule } from '@angular/forms';
import { Ui5TrainingComponentsModule } from '../../shared/ui5-training-components.module';
import { takeUntilDestroyed } from '@angular/core/rxjs-interop';
import { EmptyStateComponent, CrossAppLinkComponent } from '../../shared';
import { MCPToolDefinition, McpService } from '../../services/mcp.service';
import { I18nService } from '../../services/i18n.service';
import { TranslatePipe } from '../../shared/pipes/translate.pipe';

type InvocationState = 'success' | 'error';

interface InvocationEntry {
  toolName: string;
  args: string;
  result: string;
  state: InvocationState;
  timestamp: Date;
}

@Component({
  selector: 'app-pal-workbench',
  standalone: true,
  imports: [CommonModule, FormsModule, Ui5TrainingComponentsModule, EmptyStateComponent, TranslatePipe, CrossAppLinkComponent],
  template: `
    <ui5-page background-design="Solid">
      <ui5-breadcrumbs>
        <ui5-breadcrumbs-item href="/dashboard" text="Home"></ui5-breadcrumbs-item>
        <ui5-breadcrumbs-item text="PAL Workbench"></ui5-breadcrumbs-item>
      </ui5-breadcrumbs>
      <ui5-bar slot="header" design="Header">
        <ui5-title slot="startContent" level="H3">{{ 'palWorkbench.title' | translate }}</ui5-title>

        <app-cross-app-link
          targetApp="training"
          targetRoute="/analytical-dashboard"
          targetLabelKey="nav.analyticalDashboard"
          icon="chart-table-view">
        </app-cross-app-link>

        <ui5-button
          slot="endContent"
          icon="refresh"
          design="Transparent"
          (click)="loadTools()"
          [disabled]="loading">
          {{ loading ? ('common.loading' | translate) : ('palWorkbench.refreshTools' | translate) }}
        </ui5-button>
      </ui5-bar>

      <div class="workbench-container" role="main" [attr.aria-label]="'palWorkbench.title' | translate">
        <ui5-message-strip
          *ngIf="error"
          design="Negative"
          [hideCloseButton]="false"
          (close)="error = ''">
          {{ error }}
        </ui5-message-strip>
        <ui5-message-strip
          *ngIf="success"
          design="Positive"
          [hideCloseButton]="false"
          (close)="success = ''">
          {{ success }}
        </ui5-message-strip>

        <div class="columns">
          <ui5-card class="tool-card">
            <ui5-card-header
              slot="header"
              [titleText]="'palWorkbench.toolInvocation' | translate"
              [subtitleText]="'palWorkbench.toolInvocationSubtitle' | translate">
            </ui5-card-header>

            <div class="card-content">
              <div class="field-group">
                <label for="pal-tool-select" class="field-label">{{ 'palWorkbench.tool' | translate }}</label>
                <ui5-select
                  id="pal-tool-select"
                  ngDefaultControl
                  [(ngModel)]="selectedToolName"
                  name="palTool"
                  (change)="onToolSelectionChange()"
                  accessible-name="PAL tool selector">
                  <ui5-option *ngFor="let tool of palTools" [value]="tool.name">
                    {{ tool.name }}
                  </ui5-option>
                </ui5-select>
              </div>

              <div class="tool-description" *ngIf="selectedTool">
                <strong>{{ selectedTool.name }}</strong>
                <span>{{ selectedTool.description || ('palWorkbench.noDescription' | translate) }}</span>
                <div class="tool-schema-hint" *ngIf="selectedToolFields.length > 0">
                  <span class="tool-schema-label">Schema:</span>
                  <span *ngFor="let f of selectedToolFields" class="tool-field-chip" [class.required]="f.required" [title]="f.name + ' (' + f.type + ')' + (f.required ? ' — required' : '')">
                    {{ f.name }}<span class="tool-field-type">{{ f.type }}</span>
                  </span>
                </div>
              </div>

              <div class="field-group">
                <label for="pal-tool-args" class="field-label">{{ 'palWorkbench.argumentsJson' | translate }}</label>
                <ui5-textarea
                  id="pal-tool-args"
                  ngDefaultControl
                  [(ngModel)]="argumentsText"
                  (input)="validateArgs()"
                  [rows]="12"
                  growing
                  placeholder='{"table_name":"SALES_HISTORY","value_column":"REVENUE"}'
                  accessible-name="PAL tool arguments JSON"
                  [attr.value-state]="argsValidationState">
                </ui5-textarea>
                <span class="validation-hint" *ngIf="argsValidationMessage" [class.valid]="argsValid" [class.invalid]="!argsValid">
                  {{ argsValidationMessage }}
                </span>
              </div>

              <div class="actions">
                <ui5-button
                  design="Emphasized"
                  icon="play"
                  (click)="runTool()"
                  [disabled]="running || !selectedToolName">
                  {{ running ? ('palWorkbench.running' | translate) : ('palWorkbench.runTool' | translate) }}
                </ui5-button>
                <ui5-button
                  design="Transparent"
                  icon="write-new-document"
                  (click)="applyToolTemplate()"
                  [disabled]="!selectedTool">
                  {{ 'palWorkbench.loadTemplate' | translate }}
                </ui5-button>
                <ui5-button
                  design="Transparent"
                  icon="clear-all"
                  (click)="clearResults()"
                  [disabled]="invocations.length === 0">
                  {{ 'palWorkbench.clearResults' | translate }}
                </ui5-button>
              </div>
            </div>
          </ui5-card>

          <ui5-card class="result-card">
            <ui5-card-header
              slot="header"
              [titleText]="'palWorkbench.invocationHistory' | translate"
              [subtitleText]="'palWorkbench.latestOutput' | translate">
            </ui5-card-header>

            <div *ngIf="invocations.length > 0; else emptyState" class="history-list" role="log" aria-label="Tool invocation history" aria-live="polite">
              <div *ngFor="let invocation of invocations; trackBy: trackByInvocation" class="history-entry">
                <div class="history-header">
                  <div>
                    <strong>{{ invocation.toolName }}</strong>
                    <div class="history-meta">{{ invocation.timestamp | date: 'short' }}</div>
                  </div>
                  <ui5-tag [design]="invocation.state === 'success' ? 'Positive' : 'Negative'">
                    {{ invocation.state }}
                  </ui5-tag>
                </div>
                <div class="history-block">
                  <div class="history-label">{{ 'palWorkbench.arguments' | translate }}</div>
                  <pre>{{ invocation.args }}</pre>
                </div>
                <div class="history-block">
                  <div class="history-label">{{ 'palWorkbench.result' | translate }}</div>
                  <pre>{{ invocation.result }}</pre>
                </div>
              </div>
            </div>

            <ng-template #emptyState>
              <app-empty-state
                icon="lab"
                [title]="'palWorkbench.noExecutions' | translate"
                [description]="'palWorkbench.noExecutionsDesc' | translate">
              </app-empty-state>
            </ng-template>
          </ui5-card>
        </div>
      </div>
    </ui5-page>
  `,
  styles: [`
    .workbench-container {
      padding: 1rem;
      display: flex;
      flex-direction: column;
      gap: 1rem;
      max-width: 1400px;
      margin: 0 auto;
    }

    .columns {
      display: grid;
      gap: 1rem;
      grid-template-columns: minmax(320px, 420px) minmax(0, 1fr);
    }

    .card-content {
      padding: 1rem;
      display: grid;
      gap: 1rem;
    }

    .field-group {
      display: grid;
      gap: 0.5rem;
    }

    .field-label {
      color: var(--sapContent_LabelColor);
      font-weight: 600;
    }

    .tool-description {
      display: grid;
      gap: 0.35rem;
      padding: 0.75rem;
      border-radius: 0.75rem;
      background: var(--sapList_Background);
      border: 1px solid var(--sapList_BorderColor);
    }

    .tool-schema-hint {
      display: flex;
      flex-wrap: wrap;
      gap: 0.35rem;
      align-items: center;
      margin-top: 0.25rem;
    }

    .tool-schema-label {
      font-size: var(--sapFontSmallSize);
      color: var(--sapContent_LabelColor);
      font-weight: 600;
    }

    .tool-field-chip {
      display: inline-flex;
      align-items: center;
      gap: 0.2rem;
      padding: 0.15rem 0.45rem;
      border-radius: 999px;
      font-size: 0.7rem;
      font-weight: 600;
      background: var(--sapList_Background, #f5f5f5);
      border: 1px solid var(--sapList_BorderColor);
      color: var(--sapTextColor);
      cursor: help;
    }

    .tool-field-chip.required {
      border-color: var(--sapBrandColor, #0854a0);
      background: color-mix(in srgb, var(--sapBrandColor) 8%, white);
    }

    .tool-field-type {
      color: var(--sapContent_LabelColor);
      font-weight: 400;
      font-size: 0.6rem;
      margin-left: 0.15rem;
    }

    .validation-hint {
      font-size: var(--sapFontSmallSize);
      font-weight: 600;
    }

    .validation-hint.valid {
      color: var(--sapPositiveColor, #107e3e);
    }

    .validation-hint.invalid {
      color: var(--sapNegativeColor, #b00);
    }

    .actions {
      display: flex;
      gap: 0.5rem;
      flex-wrap: wrap;
    }

    .history-list {
      padding: 1rem;
      display: grid;
      gap: 1rem;
    }

    .history-entry {
      border: 1px solid var(--sapList_BorderColor);
      border-radius: 0.75rem;
      padding: 1rem;
      display: grid;
      gap: 0.75rem;
      background: var(--sapList_Background);
    }

    .history-header {
      display: flex;
      justify-content: space-between;
      gap: 1rem;
      align-items: flex-start;
    }

    .history-meta {
      color: var(--sapContent_LabelColor);
      font-size: var(--sapFontSmallSize);
      margin-top: 0.25rem;
    }

    .history-block {
      display: grid;
      gap: 0.25rem;
    }

    .history-label {
      color: var(--sapContent_LabelColor);
      font-size: var(--sapFontSmallSize);
      font-weight: 600;
    }

    pre {
      margin: 0;
      white-space: pre-wrap;
      word-break: break-word;
      background: var(--sapShell_Background);
      padding: 0.75rem;
      border-radius: 0.5rem;
      border: 1px solid var(--sapList_BorderColor);
      font-size: var(--sapFontSmallSize);
    }

    ui5-message-strip {
      margin-bottom: 0.25rem;
    }

    @media (max-width: 960px) {
      .columns {
        grid-template-columns: 1fr;
      }

      .workbench-container {
        padding: 0.75rem;
      }
    }
  `],
})
export class PalWorkbenchComponent implements OnInit {
  private readonly mcpService = inject(McpService);
  private readonly destroyRef = inject(DestroyRef);
  readonly i18n = inject(I18nService);

  palTools: MCPToolDefinition[] = [];
  selectedToolName = '';
  argumentsText = '{}';
  invocations: InvocationEntry[] = [];
  loading = false;
  running = false;
  error = '';
  success = '';
  argsValid = true;
  argsValidationMessage = '';
  argsValidationState: 'None' | 'Positive' | 'Negative' = 'None';

  get selectedTool(): MCPToolDefinition | undefined {
    return this.palTools.find(tool => tool.name === this.selectedToolName);
  }

  get selectedToolFields(): { name: string; type: string; required: boolean }[] {
    const properties = this.selectedTool?.inputSchema?.['properties'];
    const required = Array.isArray(this.selectedTool?.inputSchema?.['required'])
      ? (this.selectedTool?.inputSchema?.['required'] as string[])
      : [];
    if (!properties || typeof properties !== 'object') return [];
    return Object.entries(properties as Record<string, Record<string, unknown>>).map(([name, def]) => ({
      name,
      type: typeof def?.['type'] === 'string' ? def['type'] : 'unknown',
      required: required.includes(name),
    }));
  }

  ngOnInit(): void {
    this.loadTools();
  }

  loadTools(): void {
    this.loading = true;
    this.error = '';
    this.mcpService.fetchPalTools()
      .pipe(takeUntilDestroyed(this.destroyRef))
      .subscribe({
        next: tools => {
          this.palTools = tools;
          if (!this.selectedToolName && tools.length > 0) {
            this.selectedToolName = tools[0].name;
            this.applyToolTemplate();
          }
          this.loading = false;
        },
        error: () => {
          this.error = this.i18n.t('palWorkbench.loadFailed');
          this.loading = false;
        },
      });
  }

  onToolSelectionChange(): void {
    this.success = '';
    this.error = '';
    this.applyToolTemplate();
  }

  applyToolTemplate(): void {
    if (!this.selectedTool) {
      this.argumentsText = '{}';
      return;
    }
    this.argumentsText = JSON.stringify(this.buildTemplateForTool(this.selectedTool), null, 2);
  }

  runTool(): void {
    if (!this.selectedToolName || this.running) {
      return;
    }

    let parsedArguments: Record<string, unknown>;
    try {
      parsedArguments = JSON.parse(this.argumentsText || '{}') as Record<string, unknown>;
    } catch {
      this.error = this.i18n.t('palWorkbench.invalidJson');
      return;
    }

    this.running = true;
    this.error = '';
    this.success = '';
    this.mcpService.invokePalTool<unknown>(this.selectedToolName, parsedArguments)
      .pipe(takeUntilDestroyed(this.destroyRef))
      .subscribe({
        next: result => {
          this.invocations = [
            {
              toolName: this.selectedToolName,
              args: JSON.stringify(parsedArguments, null, 2),
              result: this.prettyPrint(result),
              state: 'success',
              timestamp: new Date(),
            },
            ...this.invocations,
          ];
          this.success = this.i18n.t('palWorkbench.executed', { name: this.selectedToolName });
          this.running = false;
        },
        error: err => {
          this.invocations = [
            {
              toolName: this.selectedToolName,
              args: JSON.stringify(parsedArguments, null, 2),
              result: this.prettyPrint(err?.error || err?.message || err),
              state: 'error',
              timestamp: new Date(),
            },
            ...this.invocations,
          ];
          this.error = this.i18n.t('palWorkbench.executeFailed', { name: this.selectedToolName });
          this.running = false;
        },
      });
  }

  validateArgs(): void {
    const text = this.argumentsText.trim();
    if (!text || text === '{}') {
      this.argsValid = true;
      this.argsValidationMessage = '';
      this.argsValidationState = 'None';
      return;
    }
    try {
      JSON.parse(text);
      this.argsValid = true;
      this.argsValidationMessage = '✓ Valid JSON';
      this.argsValidationState = 'Positive';
    } catch {
      this.argsValid = false;
      this.argsValidationMessage = '✗ Invalid JSON';
      this.argsValidationState = 'Negative';
    }
  }

  clearResults(): void {
    this.invocations = [];
    this.success = '';
    this.error = '';
  }

  trackByInvocation(index: number, invocation: InvocationEntry): string {
    return `${invocation.toolName}-${invocation.timestamp.getTime()}-${index}`;
  }

  private buildTemplateForTool(tool: MCPToolDefinition): Record<string, unknown> {
    const schema = tool.inputSchema || {};
    const properties = schema['properties'];
    const required = Array.isArray(schema['required']) ? schema['required'] as string[] : [];
    if (!properties || typeof properties !== 'object') {
      return {};
    }

    const template: Record<string, unknown> = {};
    for (const [propertyName, propertySchema] of Object.entries(properties as Record<string, { type?: string }>)) {
      template[propertyName] = this.defaultValueForProperty(propertySchema?.type, required.includes(propertyName));
    }
    return template;
  }

  private defaultValueForProperty(type: string | undefined, required: boolean): unknown {
    if (type === 'number' || type === 'integer') {
      return required ? 0 : null;
    }
    if (type === 'array') {
      return [];
    }
    if (type === 'object') {
      return {};
    }
    return required ? '' : null;
  }

  private prettyPrint(value: unknown): string {
    if (typeof value === 'string') {
      return value;
    }
    try {
      return JSON.stringify(value, null, 2);
    } catch {
      return String(value);
    }
  }
}
