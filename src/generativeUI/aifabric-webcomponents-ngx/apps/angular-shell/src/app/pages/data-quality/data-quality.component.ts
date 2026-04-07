import { CUSTOM_ELEMENTS_SCHEMA, Component, DestroyRef, ElementRef, OnInit, ViewChild, inject } from '@angular/core';
import { CommonModule } from '@angular/common';
import { HttpClient } from '@angular/common/http';
import { FormsModule } from '@angular/forms';
import { Ui5WebcomponentsModule } from '@ui5/webcomponents-ngx';
import { takeUntilDestroyed } from '@angular/core/rxjs-interop';
import { environment } from '../../../environments/environment';
import { AuthService } from '../../services/auth.service';
import { EmptyStateComponent, DateFormatPipe, ConfirmationDialogComponent, ConfirmationDialogData, CrossAppLinkComponent } from '../../shared';

/**
 * Data Quality Component
 * 
 * Provides UI for data quality validation using the Data Cleaning Copilot MCP.
 * Features:
 * - Table selection and schema preview
 * - Run data quality checks
 * - View check results with violations
 * - Data profiling statistics
 * - Anomaly detection visualization
 */

interface TableSchema {
  name: string;
  columns: ColumnSchema[];
  row_count?: number;
}

interface ColumnSchema {
  name: string;
  type: string;
  nullable: boolean;
  primary_key: boolean;
}

interface CheckResult {
  check_name: string;
  description: string;
  status: 'passed' | 'failed' | 'warning';
  violations_count: number;
  violations: Violation[];
  execution_time_ms: number;
}

interface Violation {
  row_index: number;
  column: string;
  value: unknown;
  expected: string;
  message: string;
}

interface ProfileResult {
  column: string;
  type: string;
  null_count: number;
  null_percentage: number;
  unique_count: number;
  unique_percentage: number;
  min?: number | string;
  max?: number | string;
  mean?: number;
  std?: number;
  sample_values: unknown[];
}

interface AnomalyResult {
  column: string;
  method: string;
  anomalies_count: number;
  anomaly_indices: number[];
  threshold: number;
  statistics: {
    mean: number;
    std: number;
    min_anomaly: number;
    max_anomaly: number;
  };
}

interface PendingApproval {
  id: string;
  tool: string;
  query: string;
  table_name: string;
  estimated_rows: number;
  created_at: string;
  requested_by: string;
  status: 'pending' | 'approved' | 'rejected';
}

interface McpHealthResponse {
  status?: string;
}

interface McpToolResultEnvelope {
  result?: {
    content?: Array<{ text: string }>;
  };
}

interface PendingApprovalsResponse {
  approvals?: PendingApproval[];
}

interface ProfileToolResponse {
  row_count?: number;
  columns?: Record<string, Partial<ProfileResult>>;
}

interface AnomalyToolResponse {
  method?: string;
  threshold?: number;
  anomalies_found?: number;
  anomaly_indices?: number[];
  statistics?: Partial<AnomalyResult['statistics']>;
}

interface DialogElement extends HTMLElement {
  show(): void;
  close(): void;
}

@Component({
  selector: 'app-data-quality',
  standalone: true,
  imports: [CommonModule, FormsModule, Ui5WebcomponentsModule, EmptyStateComponent, DateFormatPipe, ConfirmationDialogComponent, CrossAppLinkComponent],
  schemas: [CUSTOM_ELEMENTS_SCHEMA],
  template: `
    <div class="data-quality-container" role="region" aria-label="Data Quality Dashboard">
      <app-cross-app-link
        targetApp="training"
        targetRoute="/data-cleaning"
        targetLabel="Data Cleaning"
        icon="edit"
        relationLabel="Related — clean training data:">
      </app-cross-app-link>

      <!-- Header -->
      <div class="page-header">
        <h1>Data Quality Studio</h1>
        <p class="subtitle">AI-powered data validation using Data Cleaning Copilot</p>
      </div>

      <section class="studio-hero" aria-label="Data Quality core workflow">
        <div class="studio-hero__copy">
          <span class="studio-hero__eyebrow">Core workflow</span>
          <ui5-title level="H4">Validate tables, profile columns, and govern cleaning actions in one surface.</ui5-title>
          <p>
            Start with validation, move into profiling and anomaly review, then approve generated cleaning queries
            only when a real data mutation needs human signoff.
          </p>
        </div>
        <div class="studio-hero__metrics">
          <div class="studio-metric">
            <span class="studio-metric__label">MCP</span>
            <span class="studio-metric__value">{{ mcpHealthy ? 'Connected' : 'Unavailable' }}</span>
          </div>
          <div class="studio-metric">
            <span class="studio-metric__label">Tables</span>
            <span class="studio-metric__value">{{ tables.length }}</span>
          </div>
          <div class="studio-metric">
            <span class="studio-metric__label">Pending approvals</span>
            <span class="studio-metric__value">{{ pendingApprovals.length }}</span>
          </div>
        </div>
      </section>

      <!-- MCP Status Banner -->
      <ui5-card class="status-card" [class.status-healthy]="mcpHealthy" [class.status-unhealthy]="!mcpHealthy">
        <div class="status-banner">
          <ui5-icon [name]="mcpHealthy ? 'sys-enter' : 'error'" 
                    [class]="mcpHealthy ? 'icon-healthy' : 'icon-unhealthy'"></ui5-icon>
          <span class="status-text">
            Data Cleaning Copilot MCP: {{ mcpHealthy ? 'Connected' : 'Unavailable' }}
          </span>
          <ui5-button design="Transparent" icon="refresh" (click)="checkMcpHealth()" [disabled]="loading">
            Refresh
          </ui5-button>
        </div>
      </ui5-card>

      <!-- Loading State -->
      <div class="loading-container" *ngIf="loading" role="status" aria-live="polite">
        <ui5-busy-indicator active size="M"></ui5-busy-indicator>
        <span class="loading-text">{{ loadingMessage }}</span>
      </div>

      <!-- Error Message -->
      <ui5-message-strip *ngIf="error" design="Negative" [hideCloseButton]="false" (close)="error = ''" role="alert">
        {{ error }}
      </ui5-message-strip>

      <!-- Tab Container -->
      <ui5-tabcontainer class="main-tabs" collapsed fixed>
        <!-- Validation Tab -->
        <ui5-tab text="Validation" icon="validate" selected>
          <div class="tab-content">
            <!-- Table Selection -->
            <ui5-card>
              <ui5-card-header slot="header" title-text="Select Table" subtitle-text="Choose a table to validate">
                <ui5-icon slot="avatar" name="database"></ui5-icon>
              </ui5-card-header>
              <div class="form-row">
                <ui5-select ngDefaultControl name="selectedTable" [(ngModel)]="selectedTable" (change)="onTableSelect()" accessible-name="Table selection">
                  <ui5-option *ngFor="let table of tables" [value]="table.name">{{ table.name }}</ui5-option>
                </ui5-select>
                <ui5-button design="Emphasized" icon="play" (click)="runValidation()" 
                            [disabled]="!selectedTable || loading || !mcpHealthy">
                  Run Validation
                </ui5-button>
              </div>

              <!-- Schema Preview -->
              <div class="schema-preview" *ngIf="selectedTableSchema">
                <h4>Schema: {{ selectedTableSchema.name }}</h4>
                <ui5-table>
                  <ui5-table-header-cell><span>Column</span></ui5-table-header-cell>
                  <ui5-table-header-cell><span>Type</span></ui5-table-header-cell>
                  <ui5-table-header-cell><span>Nullable</span></ui5-table-header-cell>
                  <ui5-table-header-cell><span>Primary Key</span></ui5-table-header-cell>
                  <ui5-table-row *ngFor="let col of selectedTableSchema.columns">
                    <ui5-table-cell><code>{{ col.name }}</code></ui5-table-cell>
                    <ui5-table-cell><ui5-tag design="Information">{{ col.type }}</ui5-tag></ui5-table-cell>
                    <ui5-table-cell>
                      <ui5-icon [name]="col.nullable ? 'accept' : 'decline'" 
                                [class]="col.nullable ? 'icon-yes' : 'icon-no'"></ui5-icon>
                    </ui5-table-cell>
                    <ui5-table-cell>
                      <ui5-icon *ngIf="col.primary_key" name="key"></ui5-icon>
                    </ui5-table-cell>
                  </ui5-table-row>
                </ui5-table>
              </div>
            </ui5-card>

            <!-- Validation Results -->
            <ui5-card *ngIf="checkResults.length > 0" class="results-card">
              <ui5-card-header slot="header" title-text="Validation Results" 
                              [subtitleText]="'Checks: ' + checkResults.length + ' | Violations: ' + totalViolations">
                <ui5-icon slot="avatar" name="checklist"></ui5-icon>
              </ui5-card-header>
              <div class="results-summary">
                <div class="summary-stat passed">
                  <span class="stat-value">{{ passedChecks }}</span>
                  <span class="stat-label">Passed</span>
                </div>
                <div class="summary-stat failed">
                  <span class="stat-value">{{ failedChecks }}</span>
                  <span class="stat-label">Failed</span>
                </div>
                <div class="summary-stat warning">
                  <span class="stat-value">{{ warningChecks }}</span>
                  <span class="stat-label">Warnings</span>
                </div>
              </div>
              <ui5-table aria-label="Validation results">
                <ui5-table-header-cell><span>Check</span></ui5-table-header-cell>
                <ui5-table-header-cell><span>Status</span></ui5-table-header-cell>
                <ui5-table-header-cell><span>Violations</span></ui5-table-header-cell>
                <ui5-table-header-cell><span>Time</span></ui5-table-header-cell>
                <ui5-table-header-cell><span>Actions</span></ui5-table-header-cell>
                <ui5-table-row *ngFor="let result of checkResults; trackBy: trackByCheckName">
                  <ui5-table-cell>
                    <div class="check-info">
                      <strong>{{ result.check_name }}</strong>
                      <span class="check-desc">{{ result.description }}</span>
                    </div>
                  </ui5-table-cell>
                  <ui5-table-cell>
                    <ui5-tag [design]="getStatusDesign(result.status)">
                      {{ result.status | uppercase }}
                    </ui5-tag>
                  </ui5-table-cell>
                  <ui5-table-cell>
                    <span [class.violation-count]="result.violations_count > 0">
                      {{ result.violations_count }}
                    </span>
                  </ui5-table-cell>
                  <ui5-table-cell>{{ result.execution_time_ms }}ms</ui5-table-cell>
                  <ui5-table-cell>
                    <ui5-button *ngIf="result.violations_count > 0" design="Transparent" icon="detail-view"
                                (click)="showViolations(result)" aria-label="View violations">
                      View
                    </ui5-button>
                  </ui5-table-cell>
                </ui5-table-row>
              </ui5-table>
            </ui5-card>
          </div>
        </ui5-tab>

        <!-- Profiling Tab -->
        <ui5-tab text="Profiling" icon="analytics">
          <div class="tab-content">
            <ui5-card>
              <ui5-card-header slot="header" title-text="Data Profiling" 
                              subtitle-text="Statistical analysis of table columns">
                <ui5-icon slot="avatar" name="pie-chart"></ui5-icon>
              </ui5-card-header>
              <div class="form-row">
                <ui5-select ngDefaultControl name="profilingTable" [(ngModel)]="profilingTable" accessible-name="Table for profiling">
                  <ui5-option *ngFor="let table of tables" [value]="table.name">{{ table.name }}</ui5-option>
                </ui5-select>
                <ui5-input type="Number" ngDefaultControl name="sampleSize" [(ngModel)]="sampleSize" placeholder="Sample size (default: 1000)"
                          accessible-name="Sample size"></ui5-input>
                <ui5-button design="Emphasized" icon="analytics" (click)="runProfiling()"
                            [disabled]="!profilingTable || loading || !mcpHealthy">
                  Profile Data
                </ui5-button>
              </div>
            </ui5-card>

            <ui5-card *ngIf="profileResults.length > 0" class="profile-results">
              <ui5-card-header slot="header" title-text="Profile Results" 
                              [subtitleText]="profilingTable + ' (' + profileResults.length + ' columns)'">
              </ui5-card-header>
              <ui5-table aria-label="Data profile results">
                <ui5-table-header-cell><span>Column</span></ui5-table-header-cell>
                <ui5-table-header-cell><span>Type</span></ui5-table-header-cell>
                <ui5-table-header-cell><span>Nulls</span></ui5-table-header-cell>
                <ui5-table-header-cell><span>Unique</span></ui5-table-header-cell>
                <ui5-table-header-cell><span>Min/Max</span></ui5-table-header-cell>
                <ui5-table-header-cell><span>Mean/Std</span></ui5-table-header-cell>
                <ui5-table-row *ngFor="let profile of profileResults">
                  <ui5-table-cell><code>{{ profile.column }}</code></ui5-table-cell>
                  <ui5-table-cell><ui5-tag design="Information">{{ profile.type }}</ui5-tag></ui5-table-cell>
                  <ui5-table-cell>
                    <span [class.warning-value]="profile.null_percentage > 10">
                      {{ profile.null_count }} ({{ profile.null_percentage | number:'1.1-1' }}%)
                    </span>
                  </ui5-table-cell>
                  <ui5-table-cell>{{ profile.unique_count }} ({{ profile.unique_percentage | number:'1.1-1' }}%)</ui5-table-cell>
                  <ui5-table-cell>
                    <span *ngIf="profile.min !== undefined">{{ profile.min }} - {{ profile.max }}</span>
                    <span *ngIf="profile.min === undefined">-</span>
                  </ui5-table-cell>
                  <ui5-table-cell>
                    <span *ngIf="profile.mean !== undefined">{{ profile.mean | number:'1.2-2' }} ± {{ profile.std | number:'1.2-2' }}</span>
                    <span *ngIf="profile.mean === undefined">-</span>
                  </ui5-table-cell>
                </ui5-table-row>
              </ui5-table>
            </ui5-card>
          </div>
        </ui5-tab>

        <!-- Anomaly Detection Tab -->
        <ui5-tab text="Anomalies" icon="alert">
          <div class="tab-content">
            <ui5-card>
              <ui5-card-header slot="header" title-text="Anomaly Detection" 
                              subtitle-text="Identify outliers and unusual patterns">
                <ui5-icon slot="avatar" name="warning"></ui5-icon>
              </ui5-card-header>
              <div class="form-row">
                <ui5-select ngDefaultControl name="anomalyTable" [(ngModel)]="anomalyTable" accessible-name="Table for anomaly detection">
                  <ui5-option *ngFor="let table of tables" [value]="table.name">{{ table.name }}</ui5-option>
                </ui5-select>
                <ui5-input ngDefaultControl name="anomalyColumn" [(ngModel)]="anomalyColumn" placeholder="Column name"
                          accessible-name="Column for anomaly detection"></ui5-input>
                <ui5-select ngDefaultControl name="anomalyMethod" [(ngModel)]="anomalyMethod" accessible-name="Detection method">
                  <ui5-option value="zscore">Z-Score</ui5-option>
                  <ui5-option value="iqr">IQR (Interquartile Range)</ui5-option>
                  <ui5-option value="isolation_forest">Isolation Forest</ui5-option>
                </ui5-select>
                <ui5-button design="Emphasized" icon="search" (click)="detectAnomalies()"
                            [disabled]="!anomalyTable || !anomalyColumn || loading || !mcpHealthy">
                  Detect Anomalies
                </ui5-button>
              </div>
            </ui5-card>

            <ui5-card *ngIf="anomalyResult" class="anomaly-results">
              <ui5-card-header slot="header" 
                              [titleText]="'Anomalies in ' + anomalyResult.column"
                              [subtitleText]="anomalyResult.anomalies_count + ' anomalies found'">
                <ui5-icon slot="avatar" [name]="anomalyResult.anomalies_count > 0 ? 'warning' : 'sys-enter'"></ui5-icon>
              </ui5-card-header>
              <div class="anomaly-stats">
                <div class="stat-box">
                  <span class="stat-label">Method</span>
                  <span class="stat-value">{{ anomalyResult.method | uppercase }}</span>
                </div>
                <div class="stat-box">
                  <span class="stat-label">Threshold</span>
                  <span class="stat-value">{{ anomalyResult.threshold }}</span>
                </div>
                <div class="stat-box">
                  <span class="stat-label">Mean</span>
                  <span class="stat-value">{{ anomalyResult.statistics.mean | number:'1.2-2' }}</span>
                </div>
                <div class="stat-box">
                  <span class="stat-label">Std Dev</span>
                  <span class="stat-value">{{ anomalyResult.statistics.std | number:'1.2-2' }}</span>
                </div>
                <div class="stat-box warning" *ngIf="anomalyResult.anomalies_count > 0">
                  <span class="stat-label">Anomaly Range</span>
                  <span class="stat-value">{{ anomalyResult.statistics.min_anomaly | number:'1.2-2' }} - {{ anomalyResult.statistics.max_anomaly | number:'1.2-2' }}</span>
                </div>
              </div>
              <div *ngIf="anomalyResult.anomaly_indices.length > 0" class="anomaly-indices">
                <h4>Anomaly Row Indices (first 50)</h4>
                <div class="index-chips">
                  <ui5-tag *ngFor="let idx of anomalyResult.anomaly_indices.slice(0, 50)" design="Negative">
                    {{ idx }}
                  </ui5-tag>
                </div>
              </div>
            </ui5-card>
          </div>
        </ui5-tab>

        <!-- Approvals Tab -->
        <ui5-tab text="Approvals" icon="approvals" [additionalText]="pendingApprovals.length + ''">
          <div class="tab-content">
            <ui5-card>
              <ui5-card-header slot="header" title-text="Pending Approvals" 
                              subtitle-text="Review and approve generated cleaning queries">
                <ui5-icon slot="avatar" name="task"></ui5-icon>
              </ui5-card-header>
              <div class="batch-toolbar" *ngIf="pendingApprovals.length > 0">
                <ui5-checkbox
                  text="Select all"
                  [checked]="selectedApprovalIds.size === pendingApprovals.length && pendingApprovals.length > 0"
                  (change)="toggleSelectAll()">
                </ui5-checkbox>
                <ui5-button
                  design="Positive"
                  icon="accept"
                  [disabled]="selectedApprovalIds.size === 0 || mutating || !canApprove"
                  (click)="batchApprove()">
                  Approve selected ({{ selectedApprovalIds.size }})
                </ui5-button>
              </div>
              <ui5-table *ngIf="pendingApprovals.length > 0" aria-label="Pending approvals">
                <ui5-table-header-cell><span></span></ui5-table-header-cell>
                <ui5-table-header-cell><span>ID</span></ui5-table-header-cell>
                <ui5-table-header-cell><span>Tool</span></ui5-table-header-cell>
                <ui5-table-header-cell><span>Table</span></ui5-table-header-cell>
                <ui5-table-header-cell><span>Est. Rows</span></ui5-table-header-cell>
                <ui5-table-header-cell><span>Requested</span></ui5-table-header-cell>
                <ui5-table-header-cell><span>Actions</span></ui5-table-header-cell>
                <ui5-table-row *ngFor="let approval of pendingApprovals">
                  <ui5-table-cell>
                    <ui5-checkbox [checked]="selectedApprovalIds.has(approval.id)" (change)="toggleApprovalSelection(approval.id)"></ui5-checkbox>
                  </ui5-table-cell>
                  <ui5-table-cell><code>{{ approval.id | slice:0:8 }}...</code></ui5-table-cell>
                  <ui5-table-cell><ui5-tag design="Information">{{ approval.tool }}</ui5-tag></ui5-table-cell>
                  <ui5-table-cell>{{ approval.table_name }}</ui5-table-cell>
                  <ui5-table-cell>
                    <span [class.warning-value]="approval.estimated_rows > 100">{{ approval.estimated_rows }}</span>
                  </ui5-table-cell>
                  <ui5-table-cell>{{ approval.created_at | dateFormat:'short' }}</ui5-table-cell>
                  <ui5-table-cell>
                    <ui5-button design="Transparent" icon="show" (click)="reviewApproval(approval)">Review</ui5-button>
                    <ui5-button design="Positive" icon="accept" (click)="approveQuery(approval)" 
                                [disabled]="mutating || !canApprove">Approve</ui5-button>
                    <ui5-button design="Negative" icon="decline" (click)="rejectQuery(approval)"
                                [disabled]="mutating || !canApprove">Reject</ui5-button>
                  </ui5-table-cell>
                </ui5-table-row>
              </ui5-table>
              <app-empty-state *ngIf="pendingApprovals.length === 0" icon="approvals"
                              title="No Pending Approvals"
                              description="All generated queries have been reviewed.">
              </app-empty-state>
            </ui5-card>
          </div>
        </ui5-tab>
      </ui5-tabcontainer>

      <!-- Violations Dialog -->
      <ui5-dialog #violationsDialog header-text="Violations Detail">
        <div class="dialog-content" *ngIf="selectedCheck">
          <h3>{{ selectedCheck.check_name }}</h3>
          <p>{{ selectedCheck.description }}</p>
          <ui5-table *ngIf="selectedCheck.violations.length > 0">
            <ui5-table-header-cell><span>Row</span></ui5-table-header-cell>
            <ui5-table-header-cell><span>Column</span></ui5-table-header-cell>
            <ui5-table-header-cell><span>Value</span></ui5-table-header-cell>
            <ui5-table-header-cell><span>Expected</span></ui5-table-header-cell>
            <ui5-table-header-cell><span>Message</span></ui5-table-header-cell>
            <ui5-table-row *ngFor="let v of selectedCheck.violations.slice(0, 100)">
              <ui5-table-cell>{{ v.row_index }}</ui5-table-cell>
              <ui5-table-cell><code>{{ v.column }}</code></ui5-table-cell>
              <ui5-table-cell><code>{{ v.value | json }}</code></ui5-table-cell>
              <ui5-table-cell>{{ v.expected }}</ui5-table-cell>
              <ui5-table-cell>{{ v.message }}</ui5-table-cell>
            </ui5-table-row>
          </ui5-table>
          <p *ngIf="selectedCheck.violations.length > 100" class="truncation-note">
            Showing first 100 of {{ selectedCheck.violations.length }} violations
          </p>
        </div>
        <div slot="footer">
          <ui5-button design="Emphasized" (click)="closeViolationsDialog()">Close</ui5-button>
        </div>
      </ui5-dialog>

      <!-- Query Review Dialog -->
      <ui5-dialog #queryDialog header-text="Review Generated Query">
        <div class="dialog-content" *ngIf="selectedApproval">
          <ui5-message-strip design="Critical">
            This query will modify data. Review carefully before approval.
          </ui5-message-strip>
          <div class="query-info">
            <p><strong>Table:</strong> {{ selectedApproval.table_name }}</p>
            <p><strong>Estimated Rows:</strong> {{ selectedApproval.estimated_rows }}</p>
            <p><strong>Requested by:</strong> {{ selectedApproval.requested_by }}</p>
          </div>
          <h4>SQL Query</h4>
          <pre class="sql-code">{{ selectedApproval.query }}</pre>
        </div>
        <div slot="footer">
          <ui5-button design="Transparent" (click)="closeQueryDialog()">Cancel</ui5-button>
          <ui5-button design="Negative" (click)="rejectSelectedApproval()" [disabled]="mutating || !canApprove || !selectedApproval">Reject</ui5-button>
          <ui5-button design="Positive" (click)="approveSelectedApproval()" [disabled]="mutating || !canApprove || !selectedApproval">Approve</ui5-button>
        </div>
      </ui5-dialog>

      <!-- Batch Approve Confirmation Dialog -->
      <app-confirmation-dialog
        [data]="batchConfirmData"
        [open]="showBatchConfirm"
        (confirmed)="executeBatchApprove()"
        (cancelled)="showBatchConfirm = false">
      </app-confirmation-dialog>
    </div>
  `,
  styles: [`
    .data-quality-container {
      display: grid;
      gap: 1rem;
      padding: 1rem;
      max-width: 1440px;
      margin: 0 auto;
    }

    .page-header {
      display: grid;
      gap: 0.35rem;
    }

    .page-header h1,
    .page-header p {
      margin: 0;
    }

    .subtitle {
      color: var(--sapContent_LabelColor);
      line-height: 1.5;
    }

    .studio-hero {
      display: grid;
      gap: 1rem;
      padding: 1.4rem;
      border-radius: 1rem;
      background: linear-gradient(135deg, rgba(255, 255, 255, 0.96), rgba(232, 244, 253, 0.72));
      border: 1px solid color-mix(in srgb, var(--sapList_BorderColor) 88%, white);
      box-shadow: var(--sapContent_Shadow1);
    }

    .studio-hero__copy {
      display: grid;
      gap: 0.45rem;
    }

    .studio-hero__copy ui5-title,
    .studio-hero__copy p {
      margin: 0;
    }

    .studio-hero__copy p {
      color: var(--sapContent_LabelColor);
      max-width: 48rem;
      line-height: 1.5;
    }

    .studio-hero__eyebrow {
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

    .studio-hero__metrics {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(180px, 1fr));
      gap: 0.75rem;
    }

    .studio-metric {
      display: grid;
      gap: 0.25rem;
      padding: 0.9rem 1rem;
      border-radius: 0.85rem;
      background: rgba(255, 255, 255, 0.84);
      border: 1px solid color-mix(in srgb, var(--sapList_BorderColor) 88%, white);
    }

    .studio-metric__label {
      color: var(--sapContent_LabelColor);
      font-size: var(--sapFontSmallSize);
      font-weight: 700;
      text-transform: uppercase;
      letter-spacing: 0.04em;
    }

    .studio-metric__value {
      color: var(--sapTextColor);
      font-size: 1.15rem;
      font-weight: 700;
    }

    .status-card {
      overflow: hidden;
    }

    .status-banner {
      display: flex;
      align-items: center;
      gap: 0.75rem;
      padding: 0.9rem 1rem;
    }

    .status-text {
      flex: 1;
      font-weight: 600;
    }

    .icon-healthy {
      color: var(--sapPositiveColor);
    }

    .icon-unhealthy {
      color: var(--sapNegativeColor);
    }

    .loading-container {
      display: inline-flex;
      align-items: center;
      gap: 0.6rem;
      padding: 0.9rem 1rem;
      border-radius: 0.85rem;
      background: rgba(255, 255, 255, 0.84);
      border: 1px solid var(--sapList_BorderColor);
    }

    .loading-text {
      color: var(--sapContent_LabelColor);
    }

    .main-tabs {
      display: block;
      background: transparent;
    }

    .tab-content {
      display: grid;
      gap: 1rem;
      padding: 1rem 0 0;
    }

    .form-row {
      display: flex;
      gap: 0.75rem;
      flex-wrap: wrap;
      padding: 1rem;
      align-items: center;
    }

    .form-row > * {
      flex: 1 1 200px;
    }

    .schema-preview,
    .results-summary,
    .anomaly-stats,
    .dialog-content,
    .query-info {
      padding: 1rem;
    }

    .schema-preview {
      display: grid;
      gap: 0.75rem;
      border-top: 1px solid var(--sapList_BorderColor);
    }

    .schema-preview h4,
    .anomaly-indices h4,
    .dialog-content h3,
    .dialog-content h4,
    .query-info p {
      margin: 0;
    }

    .results-summary {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(140px, 1fr));
      gap: 0.75rem;
    }

    .summary-stat,
    .stat-box {
      display: grid;
      gap: 0.25rem;
      padding: 0.9rem 1rem;
      border-radius: 0.85rem;
      background: var(--sapList_Background);
      border: 1px solid var(--sapList_BorderColor);
    }

    .summary-stat.passed,
    .stat-box.warning {
      border-color: color-mix(in srgb, var(--sapPositiveColor) 25%, var(--sapList_BorderColor));
    }

    .summary-stat.failed {
      border-color: color-mix(in srgb, var(--sapNegativeColor) 25%, var(--sapList_BorderColor));
    }

    .summary-stat.warning {
      border-color: color-mix(in srgb, var(--sapCriticalColor) 25%, var(--sapList_BorderColor));
    }

    .stat-value {
      color: var(--sapTextColor);
      font-size: 1.2rem;
      font-weight: 700;
    }

    .stat-label {
      color: var(--sapContent_LabelColor);
      font-size: var(--sapFontSmallSize);
      font-weight: 600;
    }

    .check-info {
      display: grid;
      gap: 0.2rem;
    }

    .check-desc {
      color: var(--sapContent_LabelColor);
      font-size: var(--sapFontSmallSize);
    }

    .violation-count,
    .warning-value {
      color: var(--sapCriticalColor);
      font-weight: 700;
    }

    .anomaly-stats {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(140px, 1fr));
      gap: 0.75rem;
    }

    .anomaly-indices {
      display: grid;
      gap: 0.75rem;
      padding: 0 1rem 1rem;
    }

    .index-chips {
      display: flex;
      gap: 0.5rem;
      flex-wrap: wrap;
    }

    .dialog-content {
      display: grid;
      gap: 0.75rem;
      min-width: min(70vw, 960px);
    }

    .query-info {
      display: grid;
      gap: 0.35rem;
      padding: 0;
    }

    .sql-code {
      margin: 0;
      padding: 1rem;
      white-space: pre-wrap;
      word-break: break-word;
      border-radius: 0.75rem;
      background: var(--sapShell_Background);
      border: 1px solid var(--sapList_BorderColor);
      color: var(--sapContent_ContrastTextColor);
    }

    .truncation-note {
      color: var(--sapContent_LabelColor);
      font-size: var(--sapFontSmallSize);
    }

    ui5-card,
    ui5-message-strip,
    ui5-table {
      width: 100%;
    }

    @media (max-width: 720px) {
      .data-quality-container {
        padding: 0.75rem;
      }

      .studio-hero {
        padding: 1rem;
      }

      .form-row {
        flex-direction: column;
        align-items: stretch;
      }

      .dialog-content {
        min-width: auto;
      }
    }
  `]
})
export class DataQualityComponent implements OnInit {
  private readonly http = inject(HttpClient);
  private readonly destroyRef = inject(DestroyRef);
  private readonly authService = inject(AuthService);

  @ViewChild('violationsDialog') private violationsDialog?: ElementRef<DialogElement>;
  @ViewChild('queryDialog') private queryDialog?: ElementRef<DialogElement>;

  // State
  loading = false;
  loadingMessage = '';
  mutating = false;
  error = '';
  mcpHealthy = false;

  // Data
  tables: TableSchema[] = [];
  selectedTable = '';
  selectedTableSchema: TableSchema | null = null;
  checkResults: CheckResult[] = [];
  profileResults: ProfileResult[] = [];
  anomalyResult: AnomalyResult | null = null;
  pendingApprovals: PendingApproval[] = [];
  selectedApprovalIds = new Set<string>();

  // Form inputs
  profilingTable = '';
  sampleSize = '1000';
  anomalyTable = '';
  anomalyColumn = '';
  anomalyMethod = 'zscore';

  // Dialog state
  selectedCheck: CheckResult | null = null;
  selectedApproval: PendingApproval | null = null;
  showBatchConfirm = false;
  batchConfirmData: ConfirmationDialogData = { title: '', message: '' };

  readonly canApprove = this.authService.getUser()?.role === 'admin';

  get totalViolations(): number {
    return this.checkResults.reduce((sum, r) => sum + r.violations_count, 0);
  }

  get passedChecks(): number {
    return this.checkResults.filter(r => r.status === 'passed').length;
  }

  get failedChecks(): number {
    return this.checkResults.filter(r => r.status === 'failed').length;
  }

  get warningChecks(): number {
    return this.checkResults.filter(r => r.status === 'warning').length;
  }

  ngOnInit(): void {
    this.checkMcpHealth();
    this.loadTables();
    this.loadPendingApprovals();
  }

  checkMcpHealth(): void {
    this.http.get<McpHealthResponse>(`${environment.apiBaseUrl}/mcp/data-cleaning/health`)
      .pipe(takeUntilDestroyed(this.destroyRef))
      .subscribe({
        next: response => {
          this.mcpHealthy = response.status === 'ok';
        },
        error: () => {
          this.mcpHealthy = false;
        }
      });
  }

  loadTables(): void {
    const request = {
      jsonrpc: '2.0',
      id: 1,
      method: 'tools/call',
      params: {
        name: 'list_tables',
        arguments: {}
      }
    };

    this.http.post<McpToolResultEnvelope>(`${environment.apiBaseUrl}/mcp/data-cleaning`, request)
      .pipe(takeUntilDestroyed(this.destroyRef))
      .subscribe({
        next: response => {
          try {
            const content = JSON.parse(response.result?.content?.[0]?.text ?? '{}');
            this.tables = content.tables || [];
          } catch {
            this.tables = [];
            this.error = 'Failed to load tables';
          }
        },
        error: () => {
          this.tables = [];
          this.error = 'Failed to load tables';
        }
      });
  }

  onTableSelect(): void {
    this.selectedTableSchema = this.tables.find(t => t.name === this.selectedTable) || null;
    this.checkResults = [];
  }

  runValidation(): void {
    if (!this.selectedTable) return;

    this.loading = true;
    this.loadingMessage = 'Running validation checks...';
    this.error = '';

    const request = {
      jsonrpc: '2.0',
      id: 1,
      method: 'tools/call',
      params: {
        name: 'data_quality_check',
        arguments: { table_name: this.selectedTable }
      }
    };

    this.http.post<McpToolResultEnvelope>(`${environment.apiBaseUrl}/mcp/data-cleaning`, request)
      .pipe(takeUntilDestroyed(this.destroyRef))
      .subscribe({
        next: response => {
          if (response.result) {
            // Parse MCP response
            try {
              const content = JSON.parse(response.result.content?.[0]?.text ?? '{}');
              this.checkResults = content.checks || [];
            } catch {
              this.checkResults = [];
              this.error = 'Invalid response format';
            }
          } else {
            this.checkResults = [];
            this.error = 'No results returned';
          }
          this.loading = false;
        },
        error: err => {
          this.error = 'Failed to run validation: ' + (err.message || 'Unknown error');
          this.loading = false;
        }
      });
  }

  runProfiling(): void {
    if (!this.profilingTable) return;

    this.loading = true;
    this.loadingMessage = 'Profiling data...';
    this.error = '';
    this.profileResults = [];

    const parsedSampleSize = Number.parseInt(this.sampleSize, 10);
    const request = {
      jsonrpc: '2.0',
      id: 1,
      method: 'tools/call',
      params: {
        name: 'data_profiling',
        arguments: {
          table_name: this.profilingTable,
          ...(Number.isFinite(parsedSampleSize) && parsedSampleSize > 0 ? { sample_size: parsedSampleSize } : {}),
        }
      }
    };

    this.http.post<McpToolResultEnvelope>(`${environment.apiBaseUrl}/mcp/data-cleaning`, request)
      .pipe(takeUntilDestroyed(this.destroyRef))
      .subscribe({
        next: response => {
          try {
            const content = JSON.parse(response.result?.content?.[0]?.text ?? '{}') as ProfileToolResponse;
            this.profileResults = this.mapProfileResults(content);
            if (this.profileResults.length === 0) {
              this.error = 'No profiling results returned';
            }
          } catch {
            this.error = 'Invalid profiling response format';
          }
          this.loading = false;
        },
        error: err => {
          this.error = 'Failed to run profiling: ' + (err.message || 'Unknown error');
          this.loading = false;
        }
      });
  }

  detectAnomalies(): void {
    if (!this.anomalyTable || !this.anomalyColumn) return;

    this.loading = true;
    this.loadingMessage = 'Detecting anomalies...';
    this.error = '';
    this.anomalyResult = null;

    const request = {
      jsonrpc: '2.0',
      id: 1,
      method: 'tools/call',
      params: {
        name: 'anomaly_detection',
        arguments: {
          table_name: this.anomalyTable,
          column_name: this.anomalyColumn,
          method: this.anomalyMethod,
        }
      }
    };

    this.http.post<McpToolResultEnvelope>(`${environment.apiBaseUrl}/mcp/data-cleaning`, request)
      .pipe(takeUntilDestroyed(this.destroyRef))
      .subscribe({
        next: response => {
          try {
            const content = JSON.parse(response.result?.content?.[0]?.text ?? '{}') as AnomalyToolResponse;
            this.anomalyResult = this.mapAnomalyResult(content);
          } catch {
            this.error = 'Invalid anomaly detection response format';
          }
          this.loading = false;
        },
        error: err => {
          this.error = 'Failed to detect anomalies: ' + (err.message || 'Unknown error');
          this.loading = false;
        }
      });
  }

  loadPendingApprovals(): void {
    this.http.get<PendingApprovalsResponse>(`${environment.apiBaseUrl}/governance/data-cleaning/pending`)
      .pipe(takeUntilDestroyed(this.destroyRef))
      .subscribe({
        next: response => {
          this.pendingApprovals = response.approvals || [];
        },
        error: () => {
          this.pendingApprovals = [];
        }
      });
  }

  toggleSelectAll(): void {
    if (this.selectedApprovalIds.size === this.pendingApprovals.length) {
      this.selectedApprovalIds.clear();
    } else {
      this.selectedApprovalIds = new Set(this.pendingApprovals.map(a => a.id));
    }
  }

  toggleApprovalSelection(id: string): void {
    if (this.selectedApprovalIds.has(id)) {
      this.selectedApprovalIds.delete(id);
    } else {
      this.selectedApprovalIds.add(id);
    }
  }

  batchApprove(): void {
    const ids = [...this.selectedApprovalIds];
    if (ids.length === 0 || this.mutating || !this.canApprove) return;

    const tableNames = [...new Set(
      ids.map(id => this.pendingApprovals.find(a => a.id === id)?.table_name).filter(Boolean),
    )];

    this.batchConfirmData = {
      title: 'Approve Cleaning Queries',
      message: `You are about to approve ${ids.length} cleaning quer${ids.length === 1 ? 'y' : 'ies'} affecting table${tableNames.length === 1 ? '' : 's'} ${tableNames.join(', ')}. This will modify data.`,
      confirmText: 'Approve',
      cancelText: 'Cancel',
      confirmDesign: 'Positive',
      icon: 'alert',
    };
    this.showBatchConfirm = true;
  }

  executeBatchApprove(): void {
    this.showBatchConfirm = false;
    const ids = [...this.selectedApprovalIds];
    if (ids.length === 0) return;

    this.mutating = true;
    let remaining = ids.length;
    for (const id of ids) {
      const approval = this.pendingApprovals.find(a => a.id === id);
      if (!approval) { remaining--; continue; }
      this.http.post<unknown>(`${environment.apiBaseUrl}/governance/data-cleaning/${id}/approve`, {})
        .pipe(takeUntilDestroyed(this.destroyRef))
        .subscribe({
          next: () => {
            this.pendingApprovals = this.pendingApprovals.filter(a => a.id !== id);
            this.selectedApprovalIds.delete(id);
            remaining--;
            if (remaining <= 0) this.mutating = false;
          },
          error: () => {
            this.selectedApprovalIds.delete(id);
            remaining--;
            if (remaining <= 0) this.mutating = false;
          }
        });
    }
  }

  approveQuery(approval: PendingApproval): void {
    this.mutating = true;
    this.http.post<unknown>(`${environment.apiBaseUrl}/governance/data-cleaning/${approval.id}/approve`, {})
      .pipe(takeUntilDestroyed(this.destroyRef))
      .subscribe({
        next: () => {
          this.pendingApprovals = this.pendingApprovals.filter(a => a.id !== approval.id);
          if (this.selectedApproval?.id === approval.id) {
            this.closeQueryDialog();
          }
          this.mutating = false;
        },
        error: err => {
          this.error = 'Failed to approve query: ' + (err.message || 'Unknown error');
          this.mutating = false;
        }
      });
  }

  rejectQuery(approval: PendingApproval): void {
    this.mutating = true;
    this.http.post<unknown>(`${environment.apiBaseUrl}/governance/data-cleaning/${approval.id}/reject`, {})
      .pipe(takeUntilDestroyed(this.destroyRef))
      .subscribe({
        next: () => {
          this.pendingApprovals = this.pendingApprovals.filter(a => a.id !== approval.id);
          if (this.selectedApproval?.id === approval.id) {
            this.closeQueryDialog();
          }
          this.mutating = false;
        },
        error: err => {
          this.error = 'Failed to reject query: ' + (err.message || 'Unknown error');
          this.mutating = false;
        }
      });
  }

  showViolations(check: CheckResult): void {
    this.selectedCheck = check;
    this.violationsDialog?.nativeElement.show();
  }

  closeViolationsDialog(): void {
    this.violationsDialog?.nativeElement.close();
    this.selectedCheck = null;
  }

  reviewApproval(approval: PendingApproval): void {
    this.selectedApproval = approval;
    this.queryDialog?.nativeElement.show();
  }

  approveSelectedApproval(): void {
    if (this.selectedApproval && this.canApprove && !this.mutating) {
      this.approveQuery(this.selectedApproval);
    }
  }

  rejectSelectedApproval(): void {
    if (this.selectedApproval && this.canApprove && !this.mutating) {
      this.rejectQuery(this.selectedApproval);
    }
  }

  closeQueryDialog(): void {
    this.queryDialog?.nativeElement.close();
    this.selectedApproval = null;
  }

  getStatusDesign(status: CheckResult['status']): 'Positive' | 'Negative' | 'Information' | 'Critical' {
    switch (status) {
      case 'passed': return 'Positive';
      case 'failed': return 'Negative';
      case 'warning': return 'Critical';
      default: return 'Information';
    }
  }

  trackByCheckName(index: number, check: CheckResult): string {
    return check.check_name;
  }

  private mapProfileResults(content: ProfileToolResponse): ProfileResult[] {
    const rowCount = this.asNumber(content.row_count);
    const columns = content.columns ?? {};

    return Object.entries(columns).map(([column, rawProfile]) => {
      const nullCount = this.asNumber(rawProfile.null_count);
      const uniqueCount = this.asNumber(rawProfile.unique_count);

      return {
        column,
        type: typeof rawProfile.type === 'string' ? rawProfile.type : 'UNKNOWN',
        null_count: nullCount,
        null_percentage: rowCount > 0 ? (nullCount / rowCount) * 100 : 0,
        unique_count: uniqueCount,
        unique_percentage: rowCount > 0 ? (uniqueCount / rowCount) * 100 : 0,
        min: this.asRangeValue(rawProfile.min),
        max: this.asRangeValue(rawProfile.max),
        mean: this.asOptionalNumber(rawProfile.mean),
        std: this.asOptionalNumber(rawProfile.std),
        sample_values: Array.isArray(rawProfile.sample_values) ? rawProfile.sample_values : [],
      };
    });
  }

  private mapAnomalyResult(content: AnomalyToolResponse): AnomalyResult {
    return {
      column: this.anomalyColumn,
      method: typeof content.method === 'string' ? content.method : this.anomalyMethod,
      anomalies_count: this.asNumber(content.anomalies_found),
      anomaly_indices: Array.isArray(content.anomaly_indices)
        ? content.anomaly_indices.filter((value): value is number => typeof value === 'number')
        : [],
      threshold: this.asNumber(content.threshold),
      statistics: {
        mean: this.asNumber(content.statistics?.mean),
        std: this.asNumber(content.statistics?.std),
        min_anomaly: this.asNumber(content.statistics?.min_anomaly),
        max_anomaly: this.asNumber(content.statistics?.max_anomaly),
      }
    };
  }

  private asNumber(value: unknown): number {
    return typeof value === 'number' && Number.isFinite(value) ? value : 0;
  }

  private asOptionalNumber(value: unknown): number | undefined {
    return typeof value === 'number' && Number.isFinite(value) ? value : undefined;
  }

  private asRangeValue(value: unknown): number | string | undefined {
    if (typeof value === 'number' && Number.isFinite(value)) {
      return value;
    }

    return typeof value === 'string' && value.length > 0 ? value : undefined;
  }
}
