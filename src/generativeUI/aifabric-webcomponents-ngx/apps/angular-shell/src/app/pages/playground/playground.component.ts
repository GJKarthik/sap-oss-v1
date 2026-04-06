import { Component, DestroyRef, OnInit, inject } from '@angular/core';
import { CommonModule } from '@angular/common';
import { FormsModule } from '@angular/forms';
import { Ui5WebcomponentsModule } from '@ui5/webcomponents-ngx';
import { takeUntilDestroyed } from '@angular/core/rxjs-interop';
import { EmptyStateComponent } from '../../shared';
import { MCPToolDefinition, McpService } from '../../services/mcp.service';

type InvocationState = 'success' | 'error';

interface InvocationEntry {
  toolName: string;
  args: string;
  result: string;
  state: InvocationState;
  timestamp: Date;
}

interface ToolFieldSummary {
  name: string;
  type: string;
  required: boolean;
}

@Component({
  selector: 'app-playground',
  standalone: true,
  imports: [CommonModule, FormsModule, Ui5WebcomponentsModule, EmptyStateComponent],
  template: `
    <ui5-page background-design="Solid">
      <ui5-bar slot="header" design="Header">
        <ui5-title slot="startContent" level="H3">PAL Workbench</ui5-title>
        <ui5-button
          slot="endContent"
          icon="refresh"
          design="Transparent"
          (click)="loadTools()"
          [disabled]="loading">
          {{ loading ? 'Loading...' : 'Refresh Tools' }}
        </ui5-button>
      </ui5-bar>

      <div class="workbench-container">
        <section class="workbench-hero" aria-label="PAL Workbench guide">
          <div class="workbench-hero__copy">
            <span class="workbench-hero__eyebrow">Expert tool</span>
            <ui5-title level="H4">Run PAL tooling with a guided contract, then inspect the backend response.</ui5-title>
            <p>Choose a tool, load its schema-backed template, and only then drop into the JSON payload when you need expert control.</p>
          </div>
          <div class="workbench-hero__steps">
            <span class="workbench-step">1. Pick a PAL tool</span>
            <span class="workbench-step">2. Load the suggested arguments</span>
            <span class="workbench-step">3. Run and review the real backend result</span>
          </div>
        </section>

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
              title-text="Tool Invocation"
              subtitle-text="Execute PAL analytics tools through the backend proxy">
            </ui5-card-header>

            <div class="card-content">
              <div class="field-group">
                <label for="pal-tool-select" class="field-label">Tool</label>
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
                <span>{{ selectedTool.description || 'No description provided.' }}</span>
              </div>

              <div class="tool-schema" *ngIf="selectedToolFields.length > 0">
                <div class="tool-schema__header">
                  <strong>Tool contract</strong>
                  <ui5-tag design="Information">{{ requiredToolFieldCount }} required</ui5-tag>
                </div>
                <div class="tool-schema__fields">
                  <div *ngFor="let field of selectedToolFields" class="tool-schema__field">
                    <div class="tool-schema__field-copy">
                      <span class="tool-schema__field-name">{{ field.name }}</span>
                      <span class="tool-schema__field-type">{{ field.type }}</span>
                    </div>
                    <ui5-tag [design]="field.required ? 'Critical' : 'Neutral'">
                      {{ field.required ? 'Required' : 'Optional' }}
                    </ui5-tag>
                  </div>
                </div>
              </div>

              <div class="field-group">
                <label for="pal-tool-args" class="field-label">Arguments (JSON)</label>
                <ui5-textarea
                  id="pal-tool-args"
                  ngDefaultControl
                  name="argumentsText"
                  [(ngModel)]="argumentsText"
                  [rows]="12"
                  growing
                  placeholder='{"table_name":"SALES_HISTORY","value_column":"REVENUE"}'
                  accessible-name="PAL tool arguments JSON">
                </ui5-textarea>
              </div>

              <div class="actions">
                <ui5-button
                  design="Emphasized"
                  icon="play"
                  (click)="runTool()"
                  [disabled]="running || !selectedToolName">
                  {{ running ? 'Running...' : 'Run Tool' }}
                </ui5-button>
                <ui5-button
                  design="Transparent"
                  icon="write-new-document"
                  (click)="applyToolTemplate()"
                  [disabled]="!selectedTool">
                  Load Template
                </ui5-button>
                <ui5-button
                  design="Transparent"
                  icon="clear-all"
                  (click)="clearResults()"
                  [disabled]="invocations.length === 0">
                  Clear Results
                </ui5-button>
              </div>
            </div>
          </ui5-card>

          <ui5-card class="result-card">
            <ui5-card-header
              slot="header"
              title-text="Invocation History"
              subtitle-text="Latest PAL execution output">
            </ui5-card-header>

            <div *ngIf="invocations.length > 0; else emptyState" class="history-list">
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
                  <div class="history-label">Arguments</div>
                  <pre>{{ invocation.args }}</pre>
                </div>
                <div class="history-block">
                  <div class="history-label">Result</div>
                  <pre>{{ invocation.result }}</pre>
                </div>
              </div>
            </div>

            <ng-template #emptyState>
              <app-empty-state
                icon="lab"
                title="No PAL executions yet"
                description="Select a tool, provide JSON arguments, and run it from the workbench.">
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

    .workbench-hero {
      display: grid;
      gap: 1rem;
      padding: 1.25rem;
      border-radius: 1rem;
      background: linear-gradient(135deg, rgba(255, 255, 255, 0.96), rgba(245, 247, 250, 0.88));
      border: 1px solid color-mix(in srgb, var(--sapList_BorderColor) 88%, white);
      box-shadow: var(--sapContent_Shadow1);
    }

    .workbench-hero__copy {
      display: grid;
      gap: 0.45rem;
    }

    .workbench-hero__copy ui5-title,
    .workbench-hero__copy p {
      margin: 0;
    }

    .workbench-hero__copy p {
      color: var(--sapContent_LabelColor);
      max-width: 48rem;
      line-height: 1.5;
    }

    .workbench-hero__eyebrow {
      display: inline-flex;
      align-items: center;
      width: fit-content;
      padding: 0.25rem 0.55rem;
      border-radius: 999px;
      background: color-mix(in srgb, var(--sapBrandColor) 12%, white);
      color: var(--sapBrandColor);
      font-size: 0.75rem;
      font-weight: 700;
      text-transform: uppercase;
      letter-spacing: 0.04em;
    }

    .workbench-hero__steps {
      display: flex;
      gap: 0.5rem;
      flex-wrap: wrap;
    }

    .workbench-step {
      display: inline-flex;
      align-items: center;
      padding: 0.45rem 0.7rem;
      border-radius: 999px;
      background: rgba(255, 255, 255, 0.86);
      border: 1px solid color-mix(in srgb, var(--sapList_BorderColor) 88%, white);
      color: var(--sapTextColor);
      font-size: var(--sapFontSmallSize);
      font-weight: 600;
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
      gap: 0.25rem;
      padding: 0.75rem;
      border-radius: 0.75rem;
      background: var(--sapList_Background);
      border: 1px solid var(--sapList_BorderColor);
    }

    .tool-schema {
      display: grid;
      gap: 0.75rem;
      padding: 0.9rem;
      border-radius: 0.75rem;
      background: rgba(255, 255, 255, 0.86);
      border: 1px solid var(--sapList_BorderColor);
    }

    .tool-schema__header {
      display: flex;
      justify-content: space-between;
      gap: 0.75rem;
      align-items: center;
    }

    .tool-schema__fields {
      display: grid;
      gap: 0.5rem;
    }

    .tool-schema__field {
      display: flex;
      justify-content: space-between;
      gap: 0.75rem;
      align-items: center;
      padding: 0.65rem 0.75rem;
      border-radius: 0.65rem;
      background: var(--sapList_Background);
      border: 1px solid color-mix(in srgb, var(--sapList_BorderColor) 90%, white);
    }

    .tool-schema__field-copy {
      display: grid;
      gap: 0.15rem;
    }

    .tool-schema__field-name {
      font-weight: 600;
      color: var(--sapTextColor);
    }

    .tool-schema__field-type {
      color: var(--sapContent_LabelColor);
      font-size: var(--sapFontSmallSize);
      font-family: 'SFMono-Regular', Consolas, 'Liberation Mono', Menlo, monospace;
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
export class PlaygroundComponent implements OnInit {
  private readonly mcpService = inject(McpService);
  private readonly destroyRef = inject(DestroyRef);

  palTools: MCPToolDefinition[] = [];
  selectedToolName = '';
  argumentsText = '{}';
  invocations: InvocationEntry[] = [];
  loading = false;
  running = false;
  error = '';
  success = '';

  get selectedTool(): MCPToolDefinition | undefined {
    return this.palTools.find(tool => tool.name === this.selectedToolName);
  }

  get selectedToolFields(): ToolFieldSummary[] {
    const properties = this.selectedTool?.inputSchema?.['properties'];
    const required = Array.isArray(this.selectedTool?.inputSchema?.['required'])
      ? (this.selectedTool?.inputSchema?.['required'] as string[])
      : [];

    if (!properties || typeof properties !== 'object') {
      return [];
    }

    return Object.entries(properties as Record<string, Record<string, unknown>>).map(([name, definition]) => ({
      name,
      type: typeof definition?.type === 'string' ? definition.type : 'unknown',
      required: required.includes(name),
    }));
  }

  get requiredToolFieldCount(): number {
    return this.selectedToolFields.filter(field => field.required).length;
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
          this.error = 'Failed to load PAL tools.';
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
      this.error = 'Arguments must be valid JSON.';
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
          this.success = `Executed ${this.selectedToolName}.`;
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
          this.error = `Failed to execute ${this.selectedToolName}.`;
          this.running = false;
        },
      });
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
