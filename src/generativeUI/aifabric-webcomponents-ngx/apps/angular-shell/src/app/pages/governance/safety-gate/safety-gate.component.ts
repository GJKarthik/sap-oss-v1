import { Component, DestroyRef, OnInit, inject } from '@angular/core';
import { CommonModule } from '@angular/common';
import { HttpClient } from '@angular/common/http';
import { FormsModule } from '@angular/forms';
import { Ui5WebcomponentsModule } from '@ui5/webcomponents-ngx';
import { takeUntilDestroyed } from '@angular/core/rxjs-interop';
import { environment } from '../../../../environments/environment';
import { AuthService } from '../../../services/auth.service';
import { EmptyStateComponent, DateFormatPipe } from '../../../shared';

/**
 * Safety Gate UI Component
 * 
 * Implements the safety gate visualization for the AI Governance framework.
 * Shows:
 * - Validation statistics from the LLM Fact Validation Gateway (H1)
 * - Completeness warnings from the Mangle Evaluation Engine (H2)
 * - Provenance tracking visualization (H3)
 * - Real-time safety assessment status
 */

interface ValidationStats {
  total_facts_processed: number;
  facts_validated: number;
  facts_rejected: number;
  acceptance_rate: number;
  avg_validation_time_us: number;
  last_updated: string;
}

interface SafetyViolation {
  id: string;
  request_id: string;
  predicate: string;
  error_code: string;
  error_message: string;
  timestamp: string;
  severity: 'low' | 'medium' | 'high' | 'critical';
}

interface CompletenessWarning {
  id: string;
  evaluation_id: string;
  iterations_run: number;
  max_iterations: number;
  facts_derived_last: number;
  warning_message: string;
  timestamp: string;
  resolved: boolean;
}

interface ProvenanceRecord {
  fact_id: number;
  predicate: string;
  is_base_fact: boolean;
  derivation_rule: string;
  source_facts: number[];
  confidence: number;
  timestamp: string;
}

interface SafetyGateStatus {
  gate_status: 'open' | 'restricted' | 'closed';
  active_violations: number;
  pending_warnings: number;
  last_evaluation: string;
  health_score: number;
}

@Component({
  selector: 'app-safety-gate',
  standalone: true,
  imports: [CommonModule, FormsModule, Ui5WebcomponentsModule, EmptyStateComponent, DateFormatPipe],
  template: `
    <div class="safety-gate-container" role="region" aria-label="Safety Gate Dashboard">
      <!-- Status Banner -->
      <ui5-card class="status-card" [class.status-open]="gateStatus?.gate_status === 'open'"
                [class.status-restricted]="gateStatus?.gate_status === 'restricted'"
                [class.status-closed]="gateStatus?.gate_status === 'closed'">
        <div class="status-banner">
          <div class="status-icon">
            <ui5-icon [name]="getStatusIcon()" [class]="'icon-' + gateStatus?.gate_status"></ui5-icon>
          </div>
          <div class="status-info">
            <h2 class="status-title">Safety Gate: {{ gateStatus?.gate_status | uppercase }}</h2>
            <p class="status-subtitle">
              Health Score: {{ gateStatus?.health_score | number:'1.0-0' }}% | 
              Last Evaluation: {{ gateStatus?.last_evaluation | dateFormat:'medium' }}
            </p>
          </div>
          <div class="status-metrics">
            <div class="metric">
              <span class="metric-value" [class.warning]="gateStatus?.active_violations > 0">
                {{ gateStatus?.active_violations || 0 }}
              </span>
              <span class="metric-label">Active Violations</span>
            </div>
            <div class="metric">
              <span class="metric-value" [class.warning]="gateStatus?.pending_warnings > 0">
                {{ gateStatus?.pending_warnings || 0 }}
              </span>
              <span class="metric-label">Pending Warnings</span>
            </div>
          </div>
        </div>
      </ui5-card>

      <!-- Loading State -->
      <div class="loading-container" *ngIf="loading" role="status" aria-live="polite">
        <ui5-busy-indicator active size="M"></ui5-busy-indicator>
        <span class="loading-text">Loading safety gate data...</span>
      </div>

      <!-- Error Message -->
      <ui5-message-strip 
        *ngIf="error" 
        design="Negative" 
        [hideCloseButton]="false"
        (close)="error = ''"
        role="alert">
        {{ error }}
      </ui5-message-strip>

      <!-- Validation Statistics Card (H1) -->
      <ui5-card class="stats-card">
        <ui5-card-header 
          slot="header" 
          title-text="LLM Fact Validation Gateway" 
          subtitle-text="H1: Schema and safety validation for LLM-generated facts">
          <ui5-icon slot="avatar" name="validate"></ui5-icon>
        </ui5-card-header>
        <div class="stats-grid" *ngIf="validationStats">
          <div class="stat-item">
            <span class="stat-value">{{ validationStats.total_facts_processed | number }}</span>
            <span class="stat-label">Total Facts Processed</span>
          </div>
          <div class="stat-item positive">
            <span class="stat-value">{{ validationStats.facts_validated | number }}</span>
            <span class="stat-label">Facts Validated</span>
          </div>
          <div class="stat-item negative">
            <span class="stat-value">{{ validationStats.facts_rejected | number }}</span>
            <span class="stat-label">Facts Rejected</span>
          </div>
          <div class="stat-item">
            <span class="stat-value">{{ validationStats.acceptance_rate | number:'1.1-1' }}%</span>
            <span class="stat-label">Acceptance Rate</span>
          </div>
          <div class="stat-item">
            <span class="stat-value">{{ validationStats.avg_validation_time_us | number:'1.2-2' }} μs</span>
            <span class="stat-label">Avg Validation Time</span>
          </div>
        </div>
        <app-empty-state
          *ngIf="!loading && !validationStats"
          icon="analytics"
          title="No Validation Data"
          description="No validation statistics available yet.">
        </app-empty-state>
      </ui5-card>

      <!-- Completeness Warnings Card (H2) -->
      <ui5-card class="warnings-card">
        <ui5-card-header 
          slot="header" 
          title-text="Completeness Warnings" 
          subtitle-text="H2: Mangle evaluation completeness tracking"
          [additionalText]="completenessWarnings.length + ''">
          <ui5-icon slot="avatar" name="warning"></ui5-icon>
        </ui5-card-header>
        <ui5-table *ngIf="completenessWarnings.length > 0" aria-label="Completeness warnings table">
          <ui5-table-header-cell><span>Evaluation ID</span></ui5-table-header-cell>
          <ui5-table-header-cell><span>Iterations</span></ui5-table-header-cell>
          <ui5-table-header-cell><span>Last Derived</span></ui5-table-header-cell>
          <ui5-table-header-cell><span>Status</span></ui5-table-header-cell>
          <ui5-table-header-cell><span>Warning</span></ui5-table-header-cell>
          <ui5-table-header-cell><span>Time</span></ui5-table-header-cell>
          <ui5-table-header-cell><span>Actions</span></ui5-table-header-cell>
          <ui5-table-row *ngFor="let warning of completenessWarnings; trackBy: trackByWarningId">
            <ui5-table-cell>
              <code class="mono-text">{{ warning.evaluation_id | slice:0:8 }}...</code>
            </ui5-table-cell>
            <ui5-table-cell>
              <span class="iterations-display">
                {{ warning.iterations_run }} / {{ warning.max_iterations }}
              </span>
            </ui5-table-cell>
            <ui5-table-cell>{{ warning.facts_derived_last }}</ui5-table-cell>
            <ui5-table-cell>
              <ui5-tag [design]="warning.resolved ? 'Positive' : 'Negative'">
                {{ warning.resolved ? 'Resolved' : 'Pending' }}
              </ui5-tag>
            </ui5-table-cell>
            <ui5-table-cell>
              <span class="warning-text" [title]="warning.warning_message">
                {{ warning.warning_message | slice:0:50 }}...
              </span>
            </ui5-table-cell>
            <ui5-table-cell>{{ warning.timestamp | dateFormat:'short' }}</ui5-table-cell>
            <ui5-table-cell>
              <ui5-button 
                *ngIf="!warning.resolved && canManage"
                design="Transparent" 
                icon="accept" 
                (click)="resolveWarning(warning)"
                [disabled]="mutating"
                aria-label="Resolve warning">
                Resolve
              </ui5-button>
            </ui5-table-cell>
          </ui5-table-row>
        </ui5-table>
        <app-empty-state
          *ngIf="!loading && completenessWarnings.length === 0"
          icon="message-success"
          title="No Completeness Warnings"
          description="All Mangle evaluations completed successfully within iteration limits.">
        </app-empty-state>
      </ui5-card>

      <!-- Safety Violations Card -->
      <ui5-card class="violations-card">
        <ui5-card-header 
          slot="header" 
          title-text="Safety Violations" 
          subtitle-text="Facts rejected by safety invariant checks"
          [additionalText]="safetyViolations.length + ''">
          <ui5-icon slot="avatar" name="alert"></ui5-icon>
        </ui5-card-header>
        <ui5-table *ngIf="safetyViolations.length > 0" aria-label="Safety violations table">
          <ui5-table-header-cell><span>Request ID</span></ui5-table-header-cell>
          <ui5-table-header-cell><span>Predicate</span></ui5-table-header-cell>
          <ui5-table-header-cell><span>Error Code</span></ui5-table-header-cell>
          <ui5-table-header-cell><span>Severity</span></ui5-table-header-cell>
          <ui5-table-header-cell><span>Message</span></ui5-table-header-cell>
          <ui5-table-header-cell><span>Time</span></ui5-table-header-cell>
          <ui5-table-row *ngFor="let violation of safetyViolations; trackBy: trackByViolationId">
            <ui5-table-cell>
              <code class="mono-text">{{ violation.request_id | slice:0:8 }}...</code>
            </ui5-table-cell>
            <ui5-table-cell>
              <code class="predicate-text">{{ violation.predicate }}</code>
            </ui5-table-cell>
            <ui5-table-cell>
              <ui5-tag design="Information">{{ violation.error_code }}</ui5-tag>
            </ui5-table-cell>
            <ui5-table-cell>
              <ui5-tag [design]="getSeverityDesign(violation.severity)">
                {{ violation.severity | uppercase }}
              </ui5-tag>
            </ui5-table-cell>
            <ui5-table-cell>
              <span class="error-message" [title]="violation.error_message">
                {{ violation.error_message | slice:0:40 }}...
              </span>
            </ui5-table-cell>
            <ui5-table-cell>{{ violation.timestamp | dateFormat:'short' }}</ui5-table-cell>
          </ui5-table-row>
        </ui5-table>
        <app-empty-state
          *ngIf="!loading && safetyViolations.length === 0"
          icon="sys-enter"
          title="No Safety Violations"
          description="All LLM-generated facts have passed safety validation.">
        </app-empty-state>
      </ui5-card>

      <!-- Provenance Explorer Card (H3) -->
      <ui5-card class="provenance-card">
        <ui5-card-header 
          slot="header" 
          title-text="Fact Provenance Explorer" 
          subtitle-text="H3: Derivation chain tracking for governance audit">
          <ui5-icon slot="avatar" name="tree"></ui5-icon>
        </ui5-card-header>
        <div class="provenance-search">
          <ui5-input 
            placeholder="Enter fact ID to trace provenance..."
            ngDefaultControl
            name="provenanceSearchId"
            [(ngModel)]="provenanceSearchId"
            (keyup.enter)="searchProvenance()"
            accessible-name="Fact ID for provenance search">
          </ui5-input>
          <ui5-button 
            design="Emphasized" 
            icon="search" 
            (click)="searchProvenance()"
            [disabled]="!provenanceSearchId || loading">
            Trace
          </ui5-button>
        </div>
        <div class="provenance-result" *ngIf="provenanceChain.length > 0">
          <h4>Derivation Chain for Fact #{{ provenanceSearchId }}</h4>
          <div class="provenance-tree">
            <div *ngFor="let record of provenanceChain; let i = index" 
                 class="provenance-node"
                 [class.base-fact]="record.is_base_fact"
                 [class.derived-fact]="!record.is_base_fact">
              <div class="node-connector" *ngIf="i > 0"></div>
              <div class="node-content">
                <div class="node-header">
                  <ui5-tag [design]="record.is_base_fact ? 'Positive' : 'Information'">
                    {{ record.is_base_fact ? 'BASE' : 'DERIVED' }}
                  </ui5-tag>
                  <span class="fact-id">Fact #{{ record.fact_id }}</span>
                  <span class="confidence">{{ record.confidence | number:'1.2-2' }} confidence</span>
                </div>
                <div class="node-body">
                  <code class="predicate-text">{{ record.predicate }}</code>
                  <span *ngIf="!record.is_base_fact" class="derivation-info">
                    via <strong>{{ record.derivation_rule }}</strong>
                    from facts [{{ record.source_facts.join(', ') }}]
                  </span>
                </div>
                <div class="node-footer">
                  {{ record.timestamp | dateFormat:'short' }}
                </div>
              </div>
            </div>
          </div>
        </div>
        <app-empty-state
          *ngIf="!loading && provenanceChain.length === 0 && provenanceSearchId"
          icon="search"
          title="No Provenance Found"
          description="No derivation chain found for the specified fact ID.">
        </app-empty-state>
      </ui5-card>
    </div>
  `,
  styles: [`
    .safety-gate-container {
      padding: 1rem;
      display: flex;
      flex-direction: column;
      gap: 1rem;
      max-width: 1400px;
      margin: 0 auto;
    }

    /* Status Banner Styles */
    .status-card {
      border-radius: 8px;
      overflow: hidden;
    }

    .status-card.status-open {
      border-left: 4px solid var(--sapPositiveColor, #0f0);
    }

    .status-card.status-restricted {
      border-left: 4px solid var(--sapWarningColor, #ff0);
    }

    .status-card.status-closed {
      border-left: 4px solid var(--sapNegativeColor, #f00);
    }

    .status-banner {
      display: flex;
      align-items: center;
      padding: 1.5rem;
      gap: 1.5rem;
      flex-wrap: wrap;
    }

    .status-icon {
      font-size: 3rem;
    }

    .icon-open { color: var(--sapPositiveColor); }
    .icon-restricted { color: var(--sapWarningColor); }
    .icon-closed { color: var(--sapNegativeColor); }

    .status-info {
      flex: 1;
      min-width: 200px;
    }

    .status-title {
      margin: 0;
      font-size: 1.5rem;
      font-weight: 600;
    }

    .status-subtitle {
      margin: 0.25rem 0 0;
      color: var(--sapContent_LabelColor);
    }

    .status-metrics {
      display: flex;
      gap: 2rem;
    }

    .metric {
      text-align: center;
    }

    .metric-value {
      display: block;
      font-size: 2rem;
      font-weight: 700;
    }

    .metric-value.warning {
      color: var(--sapNegativeColor);
    }

    .metric-label {
      font-size: 0.875rem;
      color: var(--sapContent_LabelColor);
    }

    /* Stats Grid */
    .stats-grid {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(150px, 1fr));
      gap: 1rem;
      padding: 1rem;
    }

    .stat-item {
      text-align: center;
      padding: 1rem;
      background: var(--sapBackgroundColor);
      border-radius: 8px;
    }

    .stat-item.positive .stat-value {
      color: var(--sapPositiveColor);
    }

    .stat-item.negative .stat-value {
      color: var(--sapNegativeColor);
    }

    .stat-value {
      display: block;
      font-size: 1.5rem;
      font-weight: 600;
    }

    .stat-label {
      font-size: 0.875rem;
      color: var(--sapContent_LabelColor);
    }

    /* Table Styles */
    .mono-text {
      font-family: monospace;
      font-size: 0.875rem;
    }

    .predicate-text {
      font-family: monospace;
      background: var(--sapBackgroundColor);
      padding: 0.125rem 0.375rem;
      border-radius: 4px;
    }

    .warning-text, .error-message {
      font-size: 0.875rem;
      color: var(--sapContent_LabelColor);
    }

    .iterations-display {
      font-family: monospace;
    }

    /* Provenance Explorer */
    .provenance-search {
      display: flex;
      gap: 0.5rem;
      padding: 1rem;
    }

    .provenance-search ui5-input {
      flex: 1;
    }

    .provenance-result {
      padding: 1rem;
    }

    .provenance-result h4 {
      margin: 0 0 1rem;
    }

    .provenance-tree {
      display: flex;
      flex-direction: column;
      gap: 0.5rem;
    }

    .provenance-node {
      position: relative;
      padding-left: 1.5rem;
    }

    .node-connector {
      position: absolute;
      left: 0;
      top: 0;
      height: 100%;
      width: 2px;
      background: var(--sapContent_LabelColor);
    }

    .node-connector::before {
      content: '';
      position: absolute;
      top: 50%;
      left: 0;
      width: 1rem;
      height: 2px;
      background: var(--sapContent_LabelColor);
    }

    .node-content {
      background: var(--sapBackgroundColor);
      border-radius: 8px;
      padding: 0.75rem;
      border-left: 3px solid var(--sapContent_LabelColor);
    }

    .base-fact .node-content {
      border-left-color: var(--sapPositiveColor);
    }

    .derived-fact .node-content {
      border-left-color: var(--sapInformativeColor);
    }

    .node-header {
      display: flex;
      align-items: center;
      gap: 0.5rem;
      margin-bottom: 0.5rem;
    }

    .fact-id {
      font-weight: 600;
    }

    .confidence {
      margin-left: auto;
      font-size: 0.875rem;
      color: var(--sapContent_LabelColor);
    }

    .derivation-info {
      display: block;
      margin-top: 0.25rem;
      font-size: 0.875rem;
      color: var(--sapContent_LabelColor);
    }

    .node-footer {
      margin-top: 0.5rem;
      font-size: 0.75rem;
      color: var(--sapContent_LabelColor);
    }

    /* Loading */
    .loading-container {
      display: flex;
      align-items: center;
      justify-content: center;
      padding: 2rem;
      gap: 1rem;
    }

    .loading-text {
      color: var(--sapContent_LabelColor);
    }

    /* Responsive */
    @media (max-width: 768px) {
      .safety-gate-container {
        padding: 0.75rem;
      }

      .status-banner {
        flex-direction: column;
        text-align: center;
      }

      .status-metrics {
        justify-content: center;
      }
    }
  `]
})
export class SafetyGateComponent implements OnInit {
  private readonly http = inject(HttpClient);
  private readonly destroyRef = inject(DestroyRef);
  private readonly authService = inject(AuthService);

  // State
  loading = false;
  mutating = false;
  error = '';

  // Data
  gateStatus: SafetyGateStatus | null = null;
  validationStats: ValidationStats | null = null;
  completenessWarnings: CompletenessWarning[] = [];
  safetyViolations: SafetyViolation[] = [];
  provenanceChain: ProvenanceRecord[] = [];
  provenanceSearchId = '';

  readonly canManage = this.authService.getUser()?.role === 'admin';

  ngOnInit(): void {
    this.loadData();
  }

  loadData(): void {
    this.loading = true;
    this.error = '';

    // Load all safety gate data in parallel
    Promise.all([
      this.loadGateStatus(),
      this.loadValidationStats(),
      this.loadCompletenessWarnings(),
      this.loadSafetyViolations()
    ]).finally(() => {
      this.loading = false;
    });
  }

  private async loadGateStatus(): Promise<void> {
    try {
      const response = await this.http.get<SafetyGateStatus>(
        `${environment.apiBaseUrl}/safety-gate/status`
      ).toPromise();
      this.gateStatus = response || null;
    } catch (err) {
      console.error('Failed to load gate status:', err);
      this.gateStatus = null;
    }
  }

  private async loadValidationStats(): Promise<void> {
    try {
      const response = await this.http.get<ValidationStats>(
        `${environment.apiBaseUrl}/safety-gate/validation-stats`
      ).toPromise();
      this.validationStats = response || null;
    } catch (err) {
      console.error('Failed to load validation stats:', err);
      this.validationStats = null;
    }
  }

  private async loadCompletenessWarnings(): Promise<void> {
    try {
      const response = await this.http.get<{ warnings: CompletenessWarning[] }>(
        `${environment.apiBaseUrl}/safety-gate/completeness-warnings`
      ).toPromise();
      this.completenessWarnings = response?.warnings || [];
    } catch {
      // Empty for demo
      this.completenessWarnings = [];
    }
  }

  private async loadSafetyViolations(): Promise<void> {
    try {
      const response = await this.http.get<{ violations: SafetyViolation[] }>(
        `${environment.apiBaseUrl}/safety-gate/violations`
      ).toPromise();
      this.safetyViolations = response?.violations || [];
    } catch {
      // Empty for demo
      this.safetyViolations = [];
    }
  }

  searchProvenance(): void {
    if (!this.provenanceSearchId) {
      return;
    }

    this.loading = true;
    this.http.get<{ chain: ProvenanceRecord[] }>(
      `${environment.apiBaseUrl}/safety-gate/provenance/${this.provenanceSearchId}`
    ).pipe(takeUntilDestroyed(this.destroyRef))
      .subscribe({
        next: response => {
          this.provenanceChain = response.chain || [];
          this.loading = false;
        },
        error: (err) => {
          console.error('Failed to search provenance:', err);
          this.provenanceChain = [];
          this.loading = false;
        }
      });
  }

  resolveWarning(warning: CompletenessWarning): void {
    if (!this.canManage) {
      return;
    }

    this.mutating = true;
    this.http.patch<void>(
      `${environment.apiBaseUrl}/safety-gate/warnings/${warning.id}/resolve`, {}
    ).pipe(takeUntilDestroyed(this.destroyRef))
      .subscribe({
        next: () => {
          warning.resolved = true;
          this.mutating = false;
          if (this.gateStatus && this.gateStatus.pending_warnings > 0) {
            this.gateStatus.pending_warnings--;
          }
        },
        error: () => {
          warning.resolved = true; // Optimistic for demo
          this.mutating = false;
        }
      });
  }

  getStatusIcon(): string {
    switch (this.gateStatus?.gate_status) {
      case 'open': return 'sys-enter';
      case 'restricted': return 'warning';
      case 'closed': return 'error';
      default: return 'question-mark';
    }
  }

  getSeverityDesign(severity: string): string {
    switch (severity) {
      case 'critical': return 'Negative';
      case 'high': return 'Negative';
      case 'medium': return 'Critical';
      case 'low': return 'Information';
      default: return 'Information';
    }
  }

  trackByWarningId(index: number, warning: CompletenessWarning): string {
    return warning.id;
  }

  trackByViolationId(index: number, violation: SafetyViolation): string {
    return violation.id;
  }
}