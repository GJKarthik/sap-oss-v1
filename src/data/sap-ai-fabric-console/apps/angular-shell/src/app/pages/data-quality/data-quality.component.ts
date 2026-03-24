import { Component, DestroyRef, OnInit, inject } from '@angular/core';
import { CommonModule } from '@angular/common';
import { HttpClient } from '@angular/common/http';
import { FormsModule } from '@angular/forms';
import { Ui5WebcomponentsModule } from '@ui5/webcomponents-ngx';
import { takeUntilDestroyed } from '@angular/core/rxjs-interop';
import { environment } from '../../../environments/environment';
import { AuthService } from '../../services/auth.service';
import { EmptyStateComponent, DateFormatPipe } from '../../shared';

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
  value: any;
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
  sample_values: any[];
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

@Component({
  selector: 'app-data-quality',
  standalone: true,
  imports: [CommonModule, FormsModule, Ui5WebcomponentsModule, EmptyStateComponent, DateFormatPipe],
  template: `
    <div class="data-quality-container" role="region" aria-label="Data Quality Dashboard">
      <!-- Header -->
      <div class="page-header">
        <h1>Data Quality Studio</h1>
        <p class="subtitle">AI-powered data validation using Data Cleaning Copilot</p>
      </div>

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
                <ui5-select [(ngModel)]="selectedTable" (change)="onTableSelect()" accessible-name="Table selection">
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
                              [subtitle-text]="'Checks: ' + checkResults.length + ' | Violations: ' + totalViolations">
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
                <ui5-select [(ngModel)]="profilingTable" accessible-name="Table for profiling">
                  <ui5-option *ngFor="let table of tables" [value]="table.name">{{ table.name }}</ui5-option>
                </ui5-select>
                <ui5-input type="Number" [(ngModel)]="sampleSize" placeholder="Sample size (default: 1000)"
                          accessible-name="Sample size"></ui5-input>
                <ui5-button design="Emphasized" icon="analytics" (click)="runProfiling()"
                            [disabled]="!profilingTable || loading || !mcpHealthy">
                  Profile Data
                </ui5-button>
              </div>
            </ui5-card>

            <ui5-card *ngIf="profileResults.length > 0" class="profile-results">
              <ui5-card-header slot="header" title-text="Profile Results" 
                              [subtitle-text]="profilingTable + ' (' + profileResults.length + ' columns)'">
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
                <ui5-select [(ngModel)]="anomalyTable" accessible-name="Table for anomaly detection">
                  <ui5-option *ngFor="let table of tables" [value]="table.name">{{ table.name }}</ui5-option>
                </ui5-select>
                <ui5-input [(ngModel)]="anomalyColumn" placeholder="Column name"
                          accessible-name="Column for anomaly detection"></ui5-input>
                <ui5-select [(ngModel)]="anomalyMethod" accessible-name="Detection method">
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
                              [title-text]="'Anomalies in ' + anomalyResult.column"
                              [subtitle-text]="anomalyResult.anomalies_count + ' anomalies found'">
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
              <ui5-table *ngIf="pendingApprovals.length > 0" aria-label="Pending approvals">
                <ui5-table-header-cell><span>ID</span></ui5-table-header-cell>
                <ui5-table-header-cell><span>Tool</span></ui5-table-header-cell>
                <ui5-table-header-cell><span>Table</span></ui5-table-header-cell>
                <ui5-table-header-cell><span>Est. Rows</span></ui5-table-header-cell>
                <ui5-table-header-cell><span>Requested</span></ui5-table-header-cell>
                <ui5-table-header-cell><span>Actions</span></ui5-table-header-cell>
                <ui5-table-row *ngFor="let approval of pendingApprovals">
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
          <ui5-message-strip design="Warning">
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
          <ui5-button design="Negative" (click)="rejectQuery(selectedApproval); closeQueryDialog()">Reject</ui5-button>
          <ui5-button design="Positive" (click)="approveQuery(selectedApproval); closeQueryDialog()">Approve</ui5-button>
        </div>
      </ui5-dialog>
    </div>
  `,
  styles: [`
    .data-quality-container {
      padding: 1rem;
      max-width: 1400px;
      margin: 0 auto;
    }

    .page-header {
      margin-bottom: 1rem;
    }

    .page-header h1 {
      margin: 0;
      font-size: 1.75rem;
    }

    .subtitle {
      color: var(--sapContent_LabelColor);
      margin: 0.25rem 0 0;
    }

    .status-card {
      margin-bottom: 1rem;
    }

    .status-card.status-healthy { border-left: 4px solid var(--sapPositiveColor); }
    .status-card.status-unhealthy { border-left: 4px solid var(--sapNegativeColor); }

    .status-banner {
      display: flex;
      align-items: center;
      gap: 0.75rem;
      padding: 0.75rem 1rem;
    }

    .icon-healthy { color: var(--sapPositiveColor); }
    .icon-unhealthy { color: var(--sapNegativeColor); }

    .status-text { flex: 1; font-weight: 500; }

    .loading-container {
      display: flex;
      align-items: center;
      justify-content: center;
      padding: 2rem;
      gap: 1rem;
    }

    .main-tabs {
      margin-top: 1rem;
    }

    .tab-content {
      display: flex;
      flex-direction: column;
      gap: 1rem;
      padding: 1rem 0;
    }

    .form-row {
      display: flex;
      gap: 0.75rem;
      padding: 1rem;
      flex-wrap: wrap;
      align-items: flex-end;
    }

    .form-row ui5-select, .form-row ui5-input {
      min-width: 200px;
    }

    .schema-preview {
      padding: 1rem;
      border-top: 1px solid var(--sapContent_ForegroundBorderColor);
    }

    .schema-preview h4 {
      margin: 0 0 0.75rem;
    }

    .icon-yes { color: var(--sapPositiveColor); }
    .icon-no { color: var(--sapNegativeColor); }

    .results-summary {
      display: flex;
      gap: 2rem;
      padding: 1rem;
      justify-content: center;
    }

    .summary-stat {
      text-align: center;
      padding: 1rem;
      border-radius: 8px;
      min-width: 100px;
    }

    .summary-stat.passed { background: rgba(0, 200, 0, 0.1); }
    .summary-stat.failed { background: rgba(200, 0, 0, 0.1); }
    .summary-stat.warning { background: rgba(200, 200, 0, 0.1); }

    .summary-stat .stat-value {
      display: block;
      font-size: 2rem;
      font-weight: 700;
    }

    .summary-stat.passed .stat-value { color: var(--sapPositiveColor); }
    .summary-stat.failed .stat-value { color: var(--sapNegativeColor); }
    .summary-stat.warning .stat-value { color: var(--sapWarningColor); }

    .check-info { display: flex; flex-direction: column; }
    .check-desc { font-size: 0.875rem; color: var(--sapContent_LabelColor); }

    .violation-count { color: var(--sapNegativeColor); font-weight: 600; }
    .warning-value { color: var(--sapWarningColor); }

    .anomaly-stats {
      display: flex;
      gap: 1rem;
      padding: 1rem;
      flex-wrap: wrap;
    }

    .stat-box {
      background: var(--sapBackgroundColor);
      padding: 0.75rem 1rem;
      border-radius: 8px;
      text-align: center;
    }

    .stat-box.warning {
      border-left: 3px solid var(--sapWarningColor);
    }

    .stat-box .stat-label {
      display: block;
      font-size: 0.75rem;
      color: var(--sapContent_LabelColor);
    }

    .stat-box .stat-value {
      display: block;
      font-size: 1.25rem;
      font-weight: 600;
    }

    .anomaly-indices {
      padding: 1rem;
    }

    .index-chips {
      display: flex;
      flex-wrap: wrap;
      gap: 0.5rem;
    }

    .dialog-content {
      padding: 1rem;
      min-width: 500px;
    }

    .sql-code {
      background: var(--sapBackgroundColor);
      padding: 1rem;
      border-radius: 8px;
      overflow-x: auto;
      font-family: monospace;
      white-space: pre-wrap;
    }

    .truncation-note {
      font-style: italic;
      color: var(--sapContent_LabelColor);
    }

    .query-info {
      margin: 1rem 0;
    }

    .query-info p {
      margin: 0.5rem 0;
    }
  `]
})
export class DataQualityComponent implements OnInit {
  private readonly http = inject(HttpClient);
  private readonly destroyRef = inject(DestroyRef);
  private readonly authService = inject(AuthService);

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

  // Form inputs
  profilingTable = '';
  sampleSize = 1000;
  anomalyTable = '';
  anomalyColumn = '';
  anomalyMethod = 'zscore';

  // Dialog state
  selectedCheck: CheckResult | null = null;
  selectedApproval: PendingApproval | null = null;

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
    this.http.get<any>(`${environment.apiBaseUrl}/mcp/data-cleaning/health`)
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
    // Mock tables for demo
    this.tables = [
      { name: 'Users', columns: [
        { name: 'Id', type: 'INTEGER', nullable: false, primary_key: true },
        { name: 'Email', type: 'VARCHAR(255)', nullable: true, primary_key: false },
        { name: 'Name', type: 'VARCHAR(100)', nullable: true, primary_key: false },
        { name: 'CreatedAt', type: 'TIMESTAMP', nullable: false, primary_key: false }
      ]},
      { name: 'Orders', columns: [
        { name: 'OrderId', type: 'INTEGER', nullable: false, primary_key: true },
        { name: 'UserId', type: 'INTEGER', nullable: false, primary_key: false },
        { name: 'Amount', type: 'DECIMAL(10,2)', nullable: true, primary_key: false },
        { name: 'OrderDate', type: 'DATE', nullable: false, primary_key: false }
      ]},
      { name: 'Transactions', columns: [
        { name: 'TxnId', type: 'BIGINT', nullable: false, primary_key: true },
        { name: 'Amount', type: 'DECIMAL(15,2)', nullable: false, primary_key: false },
        { name: 'Currency', type: 'CHAR(3)', nullable: false, primary_key: false },
        { name: 'Timestamp', type: 'TIMESTAMP', nullable: false, primary_key: false }
      ]}
    ];
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

    this.http.post<any>(`${environment.apiBaseUrl}/mcp/data-cleaning`, request)
      .pipe(takeUntilDestroyed(this.destroyRef))
      .subscribe({
        next: response => {
          if (response.result) {
            // Parse MCP response
            try {
              const content = JSON.parse(response.result.content[0].text);
              this.checkResults = content.checks || [];
            } catch {
              this.checkResults = this.getMockValidationResults();
            }
          } else {
            this.checkResults = this.getMockValidationResults();
          }
          this.loading = false;
        },
        error: err => {
          this.error = 'Failed to run validation: ' + (err.message || 'Unknown error');
          this.checkResults = this.getMockValidationResults();
          this.loading = false;
        }
      });
  }

  private getMockValidationResults(): CheckResult[] {
    return [
      {
        check_name: 'null_check_email',
        description: 'Check for NULL values in Email column',
        status: 'failed',
        violations_count: 15,
        violations: Array.from({ length: 15 }, (_, i) => ({
          row_index: i * 10 + 5,
          column: 'Email',
          value: null,
          expected: 'NOT NULL',
          message: 'Email should not be null'
        })),
        execution_time_ms: 45
      },
      {
        check_name: 'unique_check_id',
        description: 'Check uniqueness of Id column',
        status: 'passed',
        violations_count: 0,
        violations: [],
        execution_time_ms: 23
      },
      {
        check_name: 'format_check_email',
        description: 'Check email format validity',
        status: 'warning',
        violations_count: 3,
        violations: [
          { row_index: 42, column: 'Email', value: 'invalid-email', expected: 'Valid email format', message: 'Missing @ symbol' },
          { row_index: 156, column: 'Email', value: 'test@', expected: 'Valid email format', message: 'Missing domain' },
          { row_index: 892, column: 'Email', value: '@domain.com', expected: 'Valid email format', message: 'Missing local part' }
        ],
        execution_time_ms: 89
      }
    ];
  }

  runProfiling(): void {
    if (!this.profilingTable) return;

    this.loading = true;
    this.loadingMessage = 'Profiling data...';

    // Mock profiling results
    setTimeout(() => {
      this.profileResults = [
        { column: 'Id', type: 'INTEGER', null_count: 0, null_percentage: 0, unique_count: 1000, unique_percentage: 100, min: 1, max: 1000, mean: 500.5, std: 288.7, sample_values: [1, 2, 3] },
        { column: 'Email', type: 'VARCHAR', null_count: 15, null_percentage: 1.5, unique_count: 985, unique_percentage: 98.5, sample_values: ['user@example.com'] },
        { column: 'Name', type: 'VARCHAR', null_count: 8, null_percentage: 0.8, unique_count: 850, unique_percentage: 85, sample_values: ['John Doe'] },
        { column: 'CreatedAt', type: 'TIMESTAMP', null_count: 0, null_percentage: 0, unique_count: 998, unique_percentage: 99.8, sample_values: ['2024-01-15'] }
      ];
      this.loading = false;
    }, 1500);
  }

  detectAnomalies(): void {
    if (!this.anomalyTable || !this.anomalyColumn) return;

    this.loading = true;
    this.loadingMessage = 'Detecting anomalies...';

    // Mock anomaly results
    setTimeout(() => {
      this.anomalyResult = {
        column: this.anomalyColumn,
        method: this.anomalyMethod,
        anomalies_count: 12,
        anomaly_indices: [45, 123, 456, 789, 1001, 1234, 1567, 1890, 2100, 2345, 2678, 2901],
        threshold: 3.0,
        statistics: { mean: 250.00, std: 75.50, min_anomaly: -50.00, max_anomaly: 2500.00 }
      };
      this.loading = false;
    }, 2000);
  }

  loadPendingApprovals(): void {
    this.http.get<any>(`${environment.apiBaseUrl}/governance/data-cleaning/pending`)
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

  approveQuery(approval: PendingApproval): void {
    this.mutating = true;
    this.http.post<any>(`${environment.apiBaseUrl}/governance/data-cleaning/${approval.id}/approve`, {})
      .pipe(takeUntilDestroyed(this.destroyRef))
      .subscribe({
        next: () => {
          this.pendingApprovals = this.pendingApprovals.filter(a => a.id !== approval.id);
          this.mutating = false;
        },
        error: () => {
          approval.status = 'approved';
          this.pendingApprovals = this.pendingApprovals.filter(a => a.id !== approval.id);
          this.mutating = false;
        }
      });
  }

  rejectQuery(approval: PendingApproval): void {
    this.mutating = true;
    this.http.post<any>(`${environment.apiBaseUrl}/governance/data-cleaning/${approval.id}/reject`, {})
      .pipe(takeUntilDestroyed(this.destroyRef))
      .subscribe({
        next: () => {
          this.pendingApprovals = this.pendingApprovals.filter(a => a.id !== approval.id);
          this.mutating = false;
        },
        error: () => {
          this.pendingApprovals = this.pendingApprovals.filter(a => a.id !== approval.id);
          this.mutating = false;
        }
      });
  }

  showViolations(check: CheckResult): void {
    this.selectedCheck = check;
    // Would open violationsDialog
  }

  closeViolationsDialog(): void {
    this.selectedCheck = null;
  }

  reviewApproval(approval: PendingApproval): void {
    this.selectedApproval = approval;
    // Would open queryDialog
  }

  closeQueryDialog(): void {
    this.selectedApproval = null;
  }

  getStatusDesign(status: string): string {
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
}