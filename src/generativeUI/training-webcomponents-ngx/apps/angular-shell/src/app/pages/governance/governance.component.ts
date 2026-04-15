import { Component, CUSTOM_ELEMENTS_SCHEMA, ChangeDetectionStrategy, inject, OnDestroy, OnInit } from '@angular/core';
import { CommonModule } from '@angular/common';
import { FormsModule } from '@angular/forms';
import { Subject, takeUntil } from 'rxjs';
import { AuthService } from '../../services/auth.service';
import { I18nService } from '../../services/i18n.service';
import { ToastService } from '../../services/toast.service';
import {
  TrainingGovernanceService,
  type TrainingApproval,
  type TrainingPolicy,
  type TrainingRun,
} from '../../services/training-governance.service';
import { CrossAppLinkComponent } from '../../shared';

@Component({
  selector: 'app-governance',
  standalone: true,
  imports: [CommonModule, FormsModule, CrossAppLinkComponent],
  schemas: [CUSTOM_ELEMENTS_SCHEMA],
  changeDetection: ChangeDetectionStrategy.OnPush,
  template: `
    <div class="governance-page" role="main" [attr.aria-label]="i18n.t('governance.title')">
      <header class="page-header">
        <div>
          <h2>{{ i18n.t('governance.title') }}</h2>
          <p class="subtitle">Training approvals, policies, gates, and evidence for governed pipeline, optimization, and deployment runs.</p>
        </div>
        <ui5-button design="Emphasized" icon="refresh" (click)="refresh()" [disabled]="loading">
          {{ i18n.t('common.refresh') }}
        </ui5-button>
      </header>

      <app-cross-app-link
        targetApp="training"
        targetRoute="/deployments"
        targetLabelKey="nav.deployments"
        icon="inbox">
      </app-cross-app-link>

      <div class="filter-bar">
        <select [(ngModel)]="filters.workflow_type" (ngModelChange)="loadRuns()">
          <option value="">All workflows</option>
          <option value="pipeline">Pipeline</option>
          <option value="optimization">Optimization</option>
          <option value="deployment">Deployment</option>
        </select>
        <select [(ngModel)]="filters.risk_tier" (ngModelChange)="loadRuns()">
          <option value="">All risks</option>
          <option value="low">Low</option>
          <option value="medium">Medium</option>
          <option value="high">High</option>
          <option value="critical">Critical</option>
        </select>
        <select [(ngModel)]="filters.status" (ngModelChange)="loadRuns()">
          <option value="">All statuses</option>
          <option value="draft">Draft</option>
          <option value="submitted">Submitted</option>
          <option value="running">Running</option>
          <option value="completed">Completed</option>
          <option value="failed">Failed</option>
        </select>
        <input [(ngModel)]="filters.team" (keyup.enter)="loadRuns()" placeholder="Filter by team" />
      </div>

      @if (loading) {
        <div class="loading-container" role="status" aria-live="polite">
          <ui5-busy-indicator active size="M"></ui5-busy-indicator>
        </div>
      }

      <div class="summary-grid">
        <div class="summary-card">
          <div class="summary-value">{{ approvals.length }}</div>
          <div class="summary-label">Approvals</div>
        </div>
        <div class="summary-card">
          <div class="summary-value">{{ runs.length }}</div>
          <div class="summary-label">Runs</div>
        </div>
        <div class="summary-card">
          <div class="summary-value">{{ blockedRunsCount() }}</div>
          <div class="summary-label">Blocked</div>
        </div>
        <div class="summary-card">
          <div class="summary-value">{{ pendingApprovalsCount() }}</div>
          <div class="summary-label">Pending</div>
        </div>
      </div>

      <section class="section">
        <h3>Approval Queue</h3>
        @if (approvals.length) {
          @for (approval of approvals; track approval.id) {
            <div class="approval-card">
              <div class="approval-header">
                <div class="approval-title">
                  <strong>{{ approval.title }}</strong>
                  <ui5-tag [design]="riskDesign(approval.risk_level)">{{ approval.risk_level }}</ui5-tag>
                  <ui5-tag [design]="stateDesign(approval.status)">{{ approval.status }}</ui5-tag>
                </div>
                <span class="meta">Run {{ approval.run_id }}</span>
              </div>
              <p class="approval-desc">{{ approval.description }}</p>
              <div class="decision-list">
                @for (decision of approval.decisions; track decision.approver + decision.decided_at) {
                  <div class="decision-row">
                    <ui5-icon [name]="decision.action === 'approve' ? 'accept' : 'decline'"></ui5-icon>
                    <span>{{ decision.approver }}</span>
                    <span class="meta">{{ decision.comment || decision.action }}</span>
                  </div>
                }
              </div>
              @if (approval.status === 'pending') {
                <div class="action-row">
                  <ui5-button design="Positive" icon="accept" (click)="decideApproval(approval, 'approve')">Approve</ui5-button>
                  <ui5-button design="Negative" icon="decline" (click)="decideApproval(approval, 'reject')">Reject</ui5-button>
                </div>
              }
            </div>
          }
        } @else {
          <div class="empty">No approvals match the current filters.</div>
        }
      </section>

      <section class="section">
        <h3>Run Register</h3>
        <div class="run-layout">
          <div class="run-list">
            @for (run of runs; track run.id) {
              <button type="button" class="run-card" [class.selected]="selectedRun?.id === run.id" (click)="selectRun(run.id)">
                <div class="run-card-header">
                  <strong>{{ run.run_name }}</strong>
                  <ui5-tag [design]="stateDesign(run.status)">{{ run.status }}</ui5-tag>
                </div>
                <div class="run-card-meta">
                  <span>{{ run.workflow_type }}</span>
                  <span>{{ run.team || 'unassigned' }}</span>
                  <span>{{ run.risk_tier }}</span>
                </div>
                @if (run.blocking_checks.length) {
                  <div class="run-blocker">{{ run.blocking_checks[0].detail }}</div>
                }
              </button>
            }
          </div>

          <div class="run-detail">
            @if (selectedRun; as run) {
              <div class="detail-card">
                <div class="detail-header">
                  <div>
                    <h4>{{ run.run_name }}</h4>
                    <p class="meta">{{ run.workflow_type }} · {{ run.id }}</p>
                  </div>
                  <div class="detail-tags">
                    <ui5-tag [design]="riskDesign(run.risk_tier)">{{ run.risk_tier }}</ui5-tag>
                    <ui5-tag [design]="stateDesign(run.approval_status)">{{ run.approval_status }}</ui5-tag>
                    <ui5-tag [design]="stateDesign(run.gate_status)">{{ run.gate_status }}</ui5-tag>
                  </div>
                </div>

                <div class="detail-grid">
                  <div><span class="meta">Requested by</span><strong>{{ run.requested_by }}</strong></div>
                  <div><span class="meta">Team</span><strong>{{ run.team || 'n/a' }}</strong></div>
                  <div><span class="meta">Model</span><strong>{{ run.model_name || 'n/a' }}</strong></div>
                  <div><span class="meta">Job</span><strong>{{ run.job_id || 'pending' }}</strong></div>
                </div>

                <h5>Gate Checklist</h5>
                <div class="gate-list">
                  @for (gate of run.gate_checks || []; track gate.gate_key) {
                    <div class="gate-item">
                      <span>{{ gate.gate_key }}</span>
                      <ui5-tag [design]="stateDesign(gate.status)">{{ gate.status }}</ui5-tag>
                      <span class="meta">{{ gate.detail }}</span>
                    </div>
                  }
                </div>

                <h5>Audit Evidence</h5>
                <div class="audit-list">
                  @for (entry of run.audit_entries || []; track entry.id || entry.created_at || $index) {
                    <div class="audit-item">
                      <strong>{{ entry.record?.event_type || entry.event_type || 'event' }}</strong>
                      <span class="meta">{{ entry.created_at || entry.record?.timestamp || 'timestamp unavailable' }}</span>
                    </div>
                  }
                </div>
              </div>
            } @else {
              <div class="empty">Select a run to inspect approval history, gate checks, and audit evidence.</div>
            }
          </div>
        </div>
      </section>

      <section class="section">
        <h3>Policy Catalogue</h3>
        <div class="policy-grid">
          @for (policy of policies; track policy.id) {
            <div class="policy-card">
              <div class="policy-row">
                <strong>{{ policy.name }}</strong>
                <ui5-tag [design]="policy.enabled ? 'Positive' : 'Negative'">{{ policy.enabled ? 'enabled' : 'disabled' }}</ui5-tag>
              </div>
              <span class="meta">{{ policy.workflow_type || 'all workflows' }} · {{ policy.rule_type }}</span>
              <p>{{ policy.description }}</p>
            </div>
          }
        </div>
      </section>
    </div>
  `,
  styles: [`
    .governance-page { padding: 1.5rem; max-width: 1200px; margin: 0 auto; display: flex; flex-direction: column; gap: 1.5rem; }
    .page-header { display: flex; justify-content: space-between; gap: 1rem; align-items: flex-start; }
    .page-header h2 { margin: 0; }
    .subtitle, .meta { color: var(--sapContent_LabelColor); }
    .filter-bar, .summary-grid, .action-row, .detail-tags, .policy-row, .approval-header, .run-card-header, .detail-header { display: flex; gap: 0.75rem; }
    .filter-bar { flex-wrap: wrap; }
    .filter-bar select, .filter-bar input { padding: 0.45rem 0.6rem; border: 1px solid var(--sapField_BorderColor); border-radius: 0.35rem; background: #fff; }
    .summary-grid { display: grid; grid-template-columns: repeat(4, 1fr); gap: 1rem; }
    .summary-card, .approval-card, .detail-card, .policy-card { border: 1px solid var(--sapTile_BorderColor, #e4e4e4); border-radius: 0.75rem; padding: 1rem; background: #fff; }
    .summary-value { font-size: 1.75rem; font-weight: 800; }
    .summary-label { font-size: 0.75rem; text-transform: uppercase; letter-spacing: 0.04em; color: var(--sapContent_LabelColor); }
    .section { display: flex; flex-direction: column; gap: 0.85rem; }
    .section h3, .detail-card h4, .detail-card h5 { margin: 0; }
    .approval-title, .decision-row, .gate-item { display: flex; align-items: center; gap: 0.5rem; }
    .decision-list, .gate-list, .audit-list, .policy-grid { display: flex; flex-direction: column; gap: 0.5rem; }
    .approval-desc, .policy-card p { margin: 0; }
    .run-layout { display: grid; grid-template-columns: 360px 1fr; gap: 1rem; }
    .run-list { display: flex; flex-direction: column; gap: 0.75rem; }
    .run-card { text-align: left; padding: 0.85rem; border: 1px solid var(--sapList_BorderColor, #ddd); border-radius: 0.75rem; background: #fff; cursor: pointer; display: flex; flex-direction: column; gap: 0.5rem; }
    .run-card.selected { border-color: var(--sapBrandColor, #0854a0); box-shadow: 0 0 0 1px rgba(8, 84, 160, 0.15); }
    .run-card-meta, .detail-grid { display: grid; grid-template-columns: repeat(2, 1fr); gap: 0.5rem; font-size: 0.8rem; }
    .run-blocker { font-size: 0.75rem; color: var(--sapCriticalTextColor, #8d2a0b); }
    .gate-item, .audit-item { justify-content: space-between; border: 1px solid rgba(0, 0, 0, 0.04); border-radius: 0.6rem; padding: 0.65rem 0.75rem; }
    .loading-container, .empty { display: flex; justify-content: center; padding: 2rem; text-align: center; color: var(--sapContent_LabelColor); }
    @media (max-width: 960px) {
      .summary-grid, .run-layout { grid-template-columns: 1fr; }
    }
  `],
})
export class GovernanceComponent implements OnInit, OnDestroy {
  private readonly governance = inject(TrainingGovernanceService);
  private readonly auth = inject(AuthService);
  readonly i18n = inject(I18nService);
  private readonly toast = inject(ToastService);
  private readonly destroy$ = new Subject<void>();

  approvals: TrainingApproval[] = [];
  policies: TrainingPolicy[] = [];
  runs: TrainingRun[] = [];
  selectedRun: TrainingRun | null = null;
  loading = true;

  filters = {
    workflow_type: '',
    risk_tier: '',
    status: '',
    team: '',
  };

  ngOnInit(): void {
    this.refresh();
  }

  ngOnDestroy(): void {
    this.destroy$.next();
    this.destroy$.complete();
  }

  refresh(): void {
    this.loading = true;
    this.loadApprovals();
    this.loadPolicies();
    this.loadRuns();
  }

  loadApprovals(): void {
    this.governance.listApprovals({
      workflow_type: this.filters.workflow_type,
    }).pipe(takeUntil(this.destroy$)).subscribe({
      next: (response) => this.approvals = response.approvals,
      error: () => this.toast.error(this.i18n.t('governance.loadApprovalsFailed')),
    });
  }

  loadPolicies(): void {
    this.governance.listPolicies().pipe(takeUntil(this.destroy$)).subscribe({
      next: (response) => this.policies = response.policies,
      error: () => this.toast.error(this.i18n.t('governance.loadPoliciesFailed')),
    });
  }

  loadRuns(): void {
    this.governance.listRuns({
      workflow_type: this.filters.workflow_type,
      risk_tier: this.filters.risk_tier,
      status: this.filters.status,
      team: this.filters.team,
    }).pipe(takeUntil(this.destroy$)).subscribe({
      next: (response) => {
        this.runs = response.runs;
        this.loading = false;
        if (this.selectedRun) {
          const matching = response.runs.find((run) => run.id === this.selectedRun?.id);
          if (matching) {
            this.selectRun(matching.id);
            return;
          }
        }
        this.selectedRun = response.runs[0] ?? null;
        if (this.selectedRun) {
          this.selectRun(this.selectedRun.id);
        }
      },
      error: () => {
        this.loading = false;
        this.toast.error('Failed to load governed training runs.');
      },
    });
  }

  selectRun(runId: string): void {
    this.governance.getRun(runId).pipe(takeUntil(this.destroy$)).subscribe({
      next: (run) => this.selectedRun = run,
      error: () => this.toast.error('Failed to load run detail.'),
    });
  }

  decideApproval(approval: TrainingApproval, action: 'approve' | 'reject'): void {
    const approver = this.auth.getUserId() || 'training-user';
    this.governance.decideApproval(approval.id, {
      approver,
      action,
      comment: action === 'reject' ? 'Rejected by reviewer.' : 'Approved by reviewer.',
    }).pipe(takeUntil(this.destroy$)).subscribe({
      next: () => this.refresh(),
      error: () => this.toast.error(action === 'approve' ? this.i18n.t('governance.approveFailed') : this.i18n.t('governance.rejectFailed')),
    });
  }

  blockedRunsCount(): number {
    return this.runs.filter((run) => run.gate_status === 'blocked').length;
  }

  pendingApprovalsCount(): number {
    return this.approvals.filter((approval) => approval.status === 'pending').length;
  }

  riskDesign(risk: string): 'Positive' | 'Information' | 'Critical' | 'Negative' {
    if (risk === 'critical') return 'Negative';
    if (risk === 'high') return 'Critical';
    if (risk === 'medium') return 'Information';
    return 'Positive';
  }

  stateDesign(status: string): 'Neutral' | 'Information' | 'Positive' | 'Critical' | 'Negative' {
    if (status === 'approved' || status === 'completed' || status === 'passed') return 'Positive';
    if (status === 'running') return 'Information';
    if (status === 'pending' || status === 'pending_approval' || status === 'submitted') return 'Critical';
    if (status === 'blocked' || status === 'failed' || status === 'rejected') return 'Negative';
    return 'Neutral';
  }
}
