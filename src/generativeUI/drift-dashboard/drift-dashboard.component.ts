/**
 * Drift Dashboard Component - SAP UI5 Web Components integration
 * 
 * This component addresses the meeting requirement:
 * "Build SAP UI5 dashboard component for vocabulary drift alerts"
 * 
 * It provides:
 * - Real-time drift metrics visualization
 * - NL readiness score gauges
 * - Vocabulary drift trend charts
 * - Alert notifications for threshold breaches
 * 
 * Status: STUB - Requires SAP UI5 Web Components runtime
 * 
 * @module DriftDashboard
 * @version 1.0.0
 */

import { Component, OnInit, OnDestroy, Input, Output, EventEmitter } from '@angular/core';
import { HttpClient } from '@angular/common/http';
import { Observable, Subject, timer, BehaviorSubject } from 'rxjs';
import { takeUntil, switchMap, catchError, map } from 'rxjs/operators';

// =============================================================================
// INTERFACES
// =============================================================================

/**
 * Drift metric data structure
 */
export interface DriftMetric {
  type: string;
  value: number;
  threshold_warning: number;
  threshold_alert: number;
  status: 'healthy' | 'warning' | 'alert' | 'critical';
  details?: Record<string, any>;
}

/**
 * NL Readiness assessment result
 */
export interface NLReadinessResult {
  schema_path: string;
  overall_score: number;
  human_ready: boolean;
  agent_ready: boolean;
  recommended_audience: 'human' | 'agent' | 'dual';
  field_scores: FieldReadinessScore[];
  issues_count: number;
}

/**
 * Field-level readiness score
 */
export interface FieldReadinessScore {
  field_name: string;
  score: number;
  readiness_level: 'human_ready' | 'agent_ready' | 'needs_work' | 'not_ready';
  has_description: boolean;
  has_readable_name: boolean;
  issues: string[];
}

/**
 * Vocabulary drift report
 */
export interface VocabularyDriftReport {
  report_id: string;
  timestamp: string;
  overall_status: 'healthy' | 'warning' | 'alert' | 'critical';
  metrics: DriftMetric[];
  oov_terms: string[];
  new_terms: string[];
  deprecated_terms_used: string[];
  recommendations: string[];
}

/**
 * Spec drift finding
 */
export interface SpecDriftFinding {
  drift_id: string;
  drift_type: string;
  severity: 'CRITICAL' | 'HIGH' | 'MEDIUM' | 'LOW';
  artifact_path: string;
  message: string;
  suggestion: string;
}

/**
 * Dashboard state
 */
export interface DashboardState {
  loading: boolean;
  error: string | null;
  lastUpdated: Date | null;
  specDrift: {
    findings: SpecDriftFinding[];
    critical_count: number;
    high_count: number;
  };
  nlReadiness: {
    reports: NLReadinessResult[];
    average_score: number;
    human_ready_count: number;
    total_schemas: number;
  };
  vocabularyDrift: VocabularyDriftReport | null;
}

// =============================================================================
// COMPONENT
// =============================================================================

/**
 * Drift Dashboard Component
 * 
 * Displays drift metrics, NL readiness scores, and vocabulary alignment status.
 * 
 * @example
 * ```html
 * <app-drift-dashboard
 *   [refreshInterval]="30000"
 *   [apiEndpoint]="/api/drift"
 *   (alertTriggered)="handleAlert($event)">
 * </app-drift-dashboard>
 * ```
 */
@Component({
  selector: 'app-drift-dashboard',
  template: `
    <ui5-card class="drift-dashboard">
      <ui5-card-header 
        slot="header"
        title-text="Drift Monitoring Dashboard"
        subtitle-text="Last updated: {{ state.lastUpdated | date:'medium' }}"
        status="{{ getOverallStatus() }}">
        <ui5-icon name="synchronize" slot="action" (click)="refresh()"></ui5-icon>
      </ui5-card-header>

      <!-- Loading State -->
      <div *ngIf="state.loading" class="loading-container">
        <ui5-busy-indicator active size="Medium"></ui5-busy-indicator>
        <span>Loading drift metrics...</span>
      </div>

      <!-- Error State -->
      <ui5-message-strip 
        *ngIf="state.error" 
        design="Negative"
        (close)="clearError()">
        {{ state.error }}
      </ui5-message-strip>

      <!-- Main Content -->
      <div *ngIf="!state.loading" class="dashboard-content">
        
        <!-- Summary Cards Row -->
        <div class="summary-row">
          <!-- Spec Drift Card -->
          <ui5-card class="metric-card">
            <ui5-card-header 
              slot="header" 
              title-text="Spec-Schema-Code Drift"
              [status]="getSpecDriftStatus()">
            </ui5-card-header>
            <div class="metric-content">
              <div class="metric-value" [class]="getSpecDriftClass()">
                {{ state.specDrift.findings.length }}
              </div>
              <div class="metric-label">Total Findings</div>
              <div class="metric-breakdown">
                <span class="critical">🔴 {{ state.specDrift.critical_count }} Critical</span>
                <span class="high">🟠 {{ state.specDrift.high_count }} High</span>
              </div>
            </div>
          </ui5-card>

          <!-- NL Readiness Card -->
          <ui5-card class="metric-card">
            <ui5-card-header 
              slot="header" 
              title-text="NL Readiness"
              [status]="getNLReadinessStatus()">
            </ui5-card-header>
            <div class="metric-content">
              <div class="gauge-container">
                <svg viewBox="0 0 100 50" class="gauge">
                  <path 
                    d="M 10 50 A 40 40 0 0 1 90 50" 
                    fill="none" 
                    stroke="#e0e0e0" 
                    stroke-width="8"/>
                  <path 
                    [attr.d]="getGaugePath(state.nlReadiness.average_score)" 
                    fill="none" 
                    [attr.stroke]="getScoreColor(state.nlReadiness.average_score)" 
                    stroke-width="8"
                    stroke-linecap="round"/>
                </svg>
                <div class="gauge-value">{{ state.nlReadiness.average_score }}/100</div>
              </div>
              <div class="metric-label">Average Score</div>
              <div class="metric-breakdown">
                Human-Ready: {{ state.nlReadiness.human_ready_count }}/{{ state.nlReadiness.total_schemas }}
              </div>
            </div>
          </ui5-card>

          <!-- Vocabulary Drift Card -->
          <ui5-card class="metric-card">
            <ui5-card-header 
              slot="header" 
              title-text="Vocabulary Drift"
              [status]="getVocabDriftStatus()">
            </ui5-card-header>
            <div class="metric-content" *ngIf="state.vocabularyDrift">
              <div class="metric-value" [class]="state.vocabularyDrift.overall_status">
                {{ getOOVRate() | percent:'1.0-1' }}
              </div>
              <div class="metric-label">OOV Rate</div>
              <div class="metric-breakdown">
                <span>{{ state.vocabularyDrift.oov_terms.length }} OOV terms</span>
                <span>{{ state.vocabularyDrift.new_terms.length }} new terms</span>
              </div>
            </div>
          </ui5-card>
        </div>

        <!-- Alerts Section -->
        <ui5-panel 
          *ngIf="hasAlerts()" 
          header-text="Active Alerts"
          class="alerts-panel"
          collapsed="false">
          <ui5-list mode="None">
            <ui5-li 
              *ngFor="let alert of getAlerts()" 
              [icon]="getAlertIcon(alert.severity)"
              [description]="alert.message"
              [additionalText]="alert.severity"
              [additionalTextState]="getAlertState(alert.severity)">
              {{ alert.drift_type }}
            </ui5-li>
          </ui5-list>
        </ui5-panel>

        <!-- Recommendations Section -->
        <ui5-panel 
          *ngIf="state.vocabularyDrift?.recommendations?.length" 
          header-text="Recommendations"
          class="recommendations-panel">
          <ui5-list mode="None">
            <ui5-li 
              *ngFor="let rec of state.vocabularyDrift.recommendations"
              icon="lightbulb">
              {{ rec }}
            </ui5-li>
          </ui5-list>
        </ui5-panel>

        <!-- Detailed Tables Section -->
        <ui5-tabcontainer class="details-tabs">
          <!-- Spec Drift Findings Tab -->
          <ui5-tab text="Spec Drift Findings" icon="error">
            <ui5-table>
              <ui5-table-column slot="columns" min-width="200">
                <span>Artifact</span>
              </ui5-table-column>
              <ui5-table-column slot="columns" min-width="100">
                <span>Type</span>
              </ui5-table-column>
              <ui5-table-column slot="columns" min-width="80">
                <span>Severity</span>
              </ui5-table-column>
              <ui5-table-column slot="columns" min-width="300">
                <span>Message</span>
              </ui5-table-column>

              <ui5-table-row *ngFor="let finding of state.specDrift.findings">
                <ui5-table-cell>{{ finding.artifact_path }}</ui5-table-cell>
                <ui5-table-cell>{{ finding.drift_type }}</ui5-table-cell>
                <ui5-table-cell>
                  <ui5-badge color-scheme="{{ getSeverityColorScheme(finding.severity) }}">
                    {{ finding.severity }}
                  </ui5-badge>
                </ui5-table-cell>
                <ui5-table-cell>{{ finding.message }}</ui5-table-cell>
              </ui5-table-row>
            </ui5-table>
          </ui5-tab>

          <!-- NL Readiness Details Tab -->
          <ui5-tab text="Schema Readiness" icon="detail-view">
            <ui5-table>
              <ui5-table-column slot="columns" min-width="250">
                <span>Schema</span>
              </ui5-table-column>
              <ui5-table-column slot="columns" min-width="80">
                <span>Score</span>
              </ui5-table-column>
              <ui5-table-column slot="columns" min-width="100">
                <span>Audience</span>
              </ui5-table-column>
              <ui5-table-column slot="columns" min-width="100">
                <span>Issues</span>
              </ui5-table-column>

              <ui5-table-row *ngFor="let schema of state.nlReadiness.reports">
                <ui5-table-cell>{{ schema.schema_path }}</ui5-table-cell>
                <ui5-table-cell>
                  <ui5-badge [color-scheme]="getScoreColorScheme(schema.overall_score)">
                    {{ schema.overall_score }}/100
                  </ui5-badge>
                </ui5-table-cell>
                <ui5-table-cell>{{ schema.recommended_audience }}</ui5-table-cell>
                <ui5-table-cell>{{ schema.issues_count }}</ui5-table-cell>
              </ui5-table-row>
            </ui5-table>
          </ui5-tab>

          <!-- OOV Terms Tab -->
          <ui5-tab text="OOV Terms" icon="text" *ngIf="state.vocabularyDrift?.oov_terms?.length">
            <ui5-list mode="None" header-text="Out-of-Vocabulary Terms">
              <ui5-li *ngFor="let term of state.vocabularyDrift.oov_terms.slice(0, 20)">
                {{ term }}
              </ui5-li>
            </ui5-list>
            <ui5-link *ngIf="state.vocabularyDrift.oov_terms.length > 20">
              View all {{ state.vocabularyDrift.oov_terms.length }} terms...
            </ui5-link>
          </ui5-tab>
        </ui5-tabcontainer>
      </div>
    </ui5-card>
  `,
  styles: [`
    .drift-dashboard {
      padding: 1rem;
    }

    .loading-container {
      display: flex;
      flex-direction: column;
      align-items: center;
      padding: 2rem;
      gap: 1rem;
    }

    .dashboard-content {
      display: flex;
      flex-direction: column;
      gap: 1.5rem;
    }

    .summary-row {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(280px, 1fr));
      gap: 1rem;
    }

    .metric-card {
      min-height: 180px;
    }

    .metric-content {
      padding: 1rem;
      text-align: center;
    }

    .metric-value {
      font-size: 2.5rem;
      font-weight: 700;
      margin-bottom: 0.5rem;
    }

    .metric-value.healthy { color: #107e3e; }
    .metric-value.warning { color: #df6e0c; }
    .metric-value.alert { color: #e9730c; }
    .metric-value.critical { color: #bb0000; }

    .metric-label {
      font-size: 0.875rem;
      color: #6a6d70;
      margin-bottom: 0.5rem;
    }

    .metric-breakdown {
      display: flex;
      justify-content: center;
      gap: 1rem;
      font-size: 0.75rem;
      color: #6a6d70;
    }

    .gauge-container {
      position: relative;
      width: 120px;
      height: 80px;
      margin: 0 auto;
    }

    .gauge {
      width: 100%;
      height: 100%;
    }

    .gauge-value {
      position: absolute;
      bottom: 0;
      left: 50%;
      transform: translateX(-50%);
      font-size: 1.25rem;
      font-weight: 600;
    }

    .alerts-panel {
      --_ui5_panel_background: #fff3cd;
    }

    .recommendations-panel {
      --_ui5_panel_background: #d1ecf1;
    }

    .details-tabs {
      margin-top: 1rem;
    }

    .critical { color: #bb0000; }
    .high { color: #e9730c; }
  `]
})
export class DriftDashboardComponent implements OnInit, OnDestroy {
  /**
   * API endpoint for fetching drift data
   */
  @Input() apiEndpoint: string = '/api/drift';

  /**
   * Refresh interval in milliseconds (default: 30 seconds)
   */
  @Input() refreshInterval: number = 30000;

  /**
   * Whether to auto-refresh
   */
  @Input() autoRefresh: boolean = true;

  /**
   * Emits when an alert threshold is breached
   */
  @Output() alertTriggered = new EventEmitter<SpecDriftFinding>();

  /**
   * Component state
   */
  state: DashboardState = {
    loading: true,
    error: null,
    lastUpdated: null,
    specDrift: {
      findings: [],
      critical_count: 0,
      high_count: 0,
    },
    nlReadiness: {
      reports: [],
      average_score: 0,
      human_ready_count: 0,
      total_schemas: 0,
    },
    vocabularyDrift: null,
  };

  private destroy$ = new Subject<void>();
  private refresh$ = new BehaviorSubject<void>(undefined);

  constructor(private http: HttpClient) {}

  ngOnInit(): void {
    // Set up auto-refresh if enabled
    if (this.autoRefresh && this.refreshInterval > 0) {
      timer(0, this.refreshInterval)
        .pipe(takeUntil(this.destroy$))
        .subscribe(() => this.loadDriftData());
    } else {
      this.loadDriftData();
    }
  }

  ngOnDestroy(): void {
    this.destroy$.next();
    this.destroy$.complete();
  }

  /**
   * Manually trigger a refresh
   */
  refresh(): void {
    this.loadDriftData();
  }

  /**
   * Clear current error
   */
  clearError(): void {
    this.state = { ...this.state, error: null };
  }

  /**
   * Load drift data from API
   */
  private loadDriftData(): void {
    this.state = { ...this.state, loading: true, error: null };

    // In a real implementation, these would be separate API calls
    // For now, we'll simulate the data structure

    // Simulate API call delay
    setTimeout(() => {
      this.state = {
        loading: false,
        error: null,
        lastUpdated: new Date(),
        specDrift: {
          findings: this.getMockSpecDriftFindings(),
          critical_count: 1,
          high_count: 2,
        },
        nlReadiness: {
          reports: this.getMockNLReadinessReports(),
          average_score: 65,
          human_ready_count: 5,
          total_schemas: 12,
        },
        vocabularyDrift: this.getMockVocabularyDrift(),
      };

      // Emit alerts for critical findings
      this.state.specDrift.findings
        .filter(f => f.severity === 'CRITICAL')
        .forEach(f => this.alertTriggered.emit(f));
    }, 500);
  }

  // ==========================================================================
  // MOCK DATA (Replace with real API calls)
  // ==========================================================================

  private getMockSpecDriftFindings(): SpecDriftFinding[] {
    return [
      {
        drift_id: 'DRIFT-001',
        drift_type: 'Schema-Spec Drift',
        severity: 'CRITICAL',
        artifact_path: 'docs/schema/simula/config.schema.json',
        message: 'Schema field "complexity_level" not documented in spec',
        suggestion: 'Add field documentation to Chapter 6',
      },
      {
        drift_id: 'DRIFT-002',
        drift_type: 'Code-Schema Drift',
        severity: 'HIGH',
        artifact_path: 'src/training/pipeline/simula_taxonomy_builder.py',
        message: 'Code references deprecated enum value',
        suggestion: 'Update to use new enum from enums.yaml',
      },
    ];
  }

  private getMockNLReadinessReports(): NLReadinessResult[] {
    return [
      {
        schema_path: 'docs/schema/simula/config.schema.json',
        overall_score: 72,
        human_ready: true,
        agent_ready: true,
        recommended_audience: 'dual',
        field_scores: [],
        issues_count: 3,
      },
      {
        schema_path: 'docs/schema/tb/entity-params.schema.json',
        overall_score: 45,
        human_ready: false,
        agent_ready: true,
        recommended_audience: 'agent',
        field_scores: [],
        issues_count: 8,
      },
    ];
  }

  private getMockVocabularyDrift(): VocabularyDriftReport {
    return {
      report_id: 'VOCAB-DRIFT-20260423',
      timestamp: new Date().toISOString(),
      overall_status: 'warning',
      metrics: [
        {
          type: 'oov_rate',
          value: 0.15,
          threshold_warning: 0.10,
          threshold_alert: 0.20,
          status: 'warning',
        },
        {
          type: 'divergence',
          value: 0.22,
          threshold_warning: 0.20,
          threshold_alert: 0.30,
          status: 'warning',
        },
      ],
      oov_terms: ['bukrs', 'waers', 'hkont', 'newterm1', 'newterm2'],
      new_terms: ['newterm1', 'newterm2'],
      deprecated_terms_used: ['txt2sql'],
      recommendations: [
        'Add OOV terms to vocabulary registry: bukrs, waers, hkont',
        'Deprecated terms in use: txt2sql. Update prompts to use canonical forms.',
      ],
    };
  }

  // ==========================================================================
  // HELPER METHODS
  // ==========================================================================

  getOverallStatus(): string {
    if (this.state.specDrift.critical_count > 0) return 'Critical';
    if (this.state.specDrift.high_count > 0) return 'Warning';
    if (this.state.vocabularyDrift?.overall_status === 'alert') return 'Warning';
    return 'Healthy';
  }

  getSpecDriftStatus(): string {
    if (this.state.specDrift.critical_count > 0) return 'Error';
    if (this.state.specDrift.high_count > 0) return 'Warning';
    return 'Success';
  }

  getSpecDriftClass(): string {
    if (this.state.specDrift.critical_count > 0) return 'critical';
    if (this.state.specDrift.high_count > 0) return 'warning';
    return 'healthy';
  }

  getNLReadinessStatus(): string {
    if (this.state.nlReadiness.average_score >= 70) return 'Success';
    if (this.state.nlReadiness.average_score >= 40) return 'Warning';
    return 'Error';
  }

  getVocabDriftStatus(): string {
    if (!this.state.vocabularyDrift) return 'None';
    const status = this.state.vocabularyDrift.overall_status;
    if (status === 'healthy') return 'Success';
    if (status === 'warning') return 'Warning';
    return 'Error';
  }

  getOOVRate(): number {
    if (!this.state.vocabularyDrift) return 0;
    const oovMetric = this.state.vocabularyDrift.metrics.find(m => m.type === 'oov_rate');
    return oovMetric?.value ?? 0;
  }

  getGaugePath(score: number): string {
    // Calculate arc path for gauge
    const percentage = Math.min(score / 100, 1);
    const angle = percentage * 180;
    const radians = (angle - 180) * (Math.PI / 180);
    const x = 50 + 40 * Math.cos(radians);
    const y = 50 + 40 * Math.sin(radians);
    const largeArcFlag = angle > 180 ? 1 : 0;
    return `M 10 50 A 40 40 0 ${largeArcFlag} 1 ${x} ${y}`;
  }

  getScoreColor(score: number): string {
    if (score >= 70) return '#107e3e';  // Green
    if (score >= 40) return '#df6e0c';  // Orange
    return '#bb0000';  // Red
  }

  getScoreColorScheme(score: number): string {
    if (score >= 70) return '8';  // Green
    if (score >= 40) return '1';  // Orange
    return '2';  // Red
  }

  getSeverityColorScheme(severity: string): string {
    switch (severity) {
      case 'CRITICAL': return '2';  // Red
      case 'HIGH': return '1';      // Orange
      case 'MEDIUM': return '3';    // Yellow
      default: return '8';          // Green
    }
  }

  hasAlerts(): boolean {
    return this.state.specDrift.critical_count > 0 || 
           this.state.specDrift.high_count > 0;
  }

  getAlerts(): SpecDriftFinding[] {
    return this.state.specDrift.findings.filter(
      f => f.severity === 'CRITICAL' || f.severity === 'HIGH'
    );
  }

  getAlertIcon(severity: string): string {
    switch (severity) {
      case 'CRITICAL': return 'error';
      case 'HIGH': return 'warning';
      default: return 'information';
    }
  }

  getAlertState(severity: string): string {
    switch (severity) {
      case 'CRITICAL': return 'Error';
      case 'HIGH': return 'Warning';
      default: return 'Information';
    }
  }
}


// =============================================================================
// MODULE STUB
// =============================================================================

/**
 * NOTE: This is a STUB implementation.
 * 
 * To fully implement this dashboard, you need:
 * 
 * 1. Install SAP UI5 Web Components:
 *    npm install @ui5/webcomponents @ui5/webcomponents-fiori @ui5/webcomponents-icons
 * 
 * 2. Install Angular wrapper:
 *    npm install @plentycode/ui5-webcomponents-ngx
 * 
 * 3. Import in your Angular module:
 *    ```typescript
 *    import { Ui5WebcomponentsModule } from '@plentycode/ui5-webcomponents-ngx';
 *    
 *    @NgModule({
 *      imports: [Ui5WebcomponentsModule],
 *      declarations: [DriftDashboardComponent],
 *    })
 *    export class DriftDashboardModule { }
 *    ```
 * 
 * 4. Create API endpoints:
 *    - GET /api/drift/spec-drift
 *    - GET /api/drift/nl-readiness
 *    - GET /api/drift/vocabulary
 * 
 * 5. Connect to the Python scripts:
 *    - scripts/spec-drift/audit.py
 *    - scripts/spec-drift/nl_readiness_assessor.py
 *    - scripts/spec-drift/vocabulary_drift_monitor.py
 */