/**
 * Team Governance Page for Training Console
 *
 * Provides team approval workflows for AI training actions.
 * Uses Angular 20 standalone + @if/@for control flow.
 */

import { Component, ChangeDetectionStrategy, ChangeDetectorRef, inject, OnInit, OnDestroy } from '@angular/core';
import { CommonModule } from '@angular/common';
import { HttpClient } from '@angular/common/http';
import { Subject, takeUntil } from 'rxjs';
import { TeamGovernanceService, PendingApproval } from '../../services/team-governance.service';
import { TeamConfigService, GovernancePolicyConfig } from '../../services/team-config.service';
import { AuthService } from '../../services/auth.service';
import { I18nService } from '../../services/i18n.service';
import { ToastService } from '../../services/toast.service';
import { environment } from '../../../environments/environment';
import { Ui5TrainingComponentsModule } from '../../shared/ui5-training-components.module';
import { CrossAppLinkComponent } from '../../shared';

interface ApiApproval {
  id: string; title: string; description: string; risk_level: string;
  requested_by: string; approvers: string[]; status: string;
  decisions: { approver: string; action: string; comment: string; decided_at: string }[];
  created_at: string; updated_at: string;
}

interface ApiPolicy {
  id: string; name: string; description: string; enabled: boolean;
}

@Component({
  selector: 'app-governance',
  standalone: true,
  imports: [CommonModule, Ui5TrainingComponentsModule, CrossAppLinkComponent],
  changeDetection: ChangeDetectionStrategy.OnPush,
  template: `
    <div class="governance-page" role="main" [attr.aria-label]="i18n.t('governance.title')">
      <ui5-breadcrumbs>
        <ui5-breadcrumbs-item href="/dashboard" text="Home"></ui5-breadcrumbs-item>
        <ui5-breadcrumbs-item text="Governance"></ui5-breadcrumbs-item>
      </ui5-breadcrumbs>
      <header class="page-header">
        <ui5-title level="H4">{{ i18n.t('governance.title') }}</ui5-title>
        <p class="subtitle">{{ i18n.t('governance.subtitle') }}</p>
      </header>

      <app-cross-app-link
        targetApp="training"
        targetRoute="/deployments"
        targetLabelKey="nav.deployments"
        icon="inbox">
      </app-cross-app-link>

      @if (loading) {
        <div class="loading-container" role="status" aria-live="polite">
          <ui5-busy-indicator active size="M"></ui5-busy-indicator>
        </div>
      }

      <!-- Pending Approvals -->
      <section class="section">
        <ui5-title level="H5">{{ i18n.t('governance.pendingApprovals') }} <ui5-tag>{{ apiApprovals.length }}</ui5-tag></ui5-title>
        @if (apiApprovals.length > 0) {
          @for (approval of apiApprovals; track approval.id) {
            <div class="approval-card">
              <div class="approval-header">
                <div class="approval-title">
                  <ui5-icon [attr.name]="getRiskIcon(approval.risk_level)"></ui5-icon>
                  <strong>{{ approval.title }}</strong>
                  <ui5-tag [attr.design]="getRiskDesign(approval.risk_level)">{{ approval.risk_level }}</ui5-tag>
                </div>
                <span class="meta">{{ i18n.t('governance.by') }} {{ approval.requested_by }}</span>
              </div>
              <p class="approval-desc">{{ approval.description }}</p>
              <div class="progress-row">
                <span class="meta">{{ approval.decisions.length }} / {{ approval.approvers.length }} {{ i18n.t('governance.approvals') }}</span>
                <div class="progress-bar"><div class="progress-fill" [style.width.%]="(approval.decisions.length / Math.max(approval.approvers.length, 1)) * 100"></div></div>
              </div>
              @for (decision of approval.decisions; track decision.approver) {
                <div class="decision-row">
                  <ui5-icon [attr.name]="decision.action === 'approve' ? 'accept' : 'decline'"></ui5-icon>
                  {{ decision.approver }}
                  @if (decision.comment) { <span class="meta"> — {{ decision.comment }}</span> }
                </div>
              }
              @if (approval.status === 'pending') {
                <div class="action-row">
                  <ui5-button design="Positive" icon="accept" (click)="approveApi(approval)">{{ i18n.t('governance.approve') }}</ui5-button>
                  <ui5-button design="Negative" icon="decline" (click)="rejectApi(approval)">{{ i18n.t('governance.reject') }}</ui5-button>
                </div>
              } @else {
                <ui5-tag [attr.design]="approval.status === 'approved' ? 'Positive' : 'Negative'">{{ approval.status }}</ui5-tag>
              }
            </div>
          }
        } @else {
          <div class="empty">
            <ui5-icon name="approvals" style="font-size: 2rem;"></ui5-icon>
            <p>{{ i18n.t('governance.noPendingApprovals') }}</p>
          </div>
        }
      </section>

      <!-- Team Policies -->
      <section class="section">
        <ui5-title level="H5">{{ i18n.t('governance.teamPolicies') }}</ui5-title>
        @if (apiPolicies.length > 0) {
          @for (policy of apiPolicies; track policy.id) {
            <div class="policy-card">
              <div class="policy-row">
                <strong>{{ policy.name }}</strong>
                <ui5-tag [attr.design]="policy.enabled ? 'Positive' : 'Negative'">{{ policy.enabled ? i18n.t('governance.active') : i18n.t('governance.inactive') }}</ui5-tag>
              </div>
              <span class="meta">{{ policy.description }}</span>
            </div>
          }
        } @else {
          <div class="empty"><p>{{ i18n.t('governance.noPolicies') }}</p></div>
        }
      </section>
    </div>
  `,
  styles: [`
    .governance-page { padding: 1.5rem; max-width: 900px; margin: 0 auto; }
    .page-header { margin-bottom: 1.5rem; }
    .page-header h2 { margin: 0; }
    .subtitle { color: var(--sapContent_LabelColor); margin: 0.25rem 0 0; }
    .section { margin-bottom: 2rem; }
    .section h3 { display: flex; align-items: center; gap: 0.5rem; }
    .approval-card, .policy-card { border: 1px solid var(--sapTile_BorderColor, #e4e4e4); border-radius: 0.5rem; padding: 1rem; margin-bottom: 0.75rem; }
    .approval-header { display: flex; justify-content: space-between; align-items: center; }
    .approval-title { display: flex; align-items: center; gap: 0.5rem; }
    .approval-desc { font-size: 0.875rem; margin: 0.5rem 0; }
    .progress-row { margin: 0.5rem 0; }
    .progress-bar { height: 4px; background: var(--sapField_BorderColor); border-radius: 2px; overflow: hidden; margin-top: 0.25rem; }
    .progress-fill { height: 100%; background: var(--sapPositiveColor, #107e3e); }
    .decision-row { display: flex; align-items: center; gap: 0.5rem; font-size: 0.8125rem; margin: 0.25rem 0; }
    .action-row { display: flex; gap: 0.5rem; margin-top: 0.75rem; }
    .policy-row { display: flex; justify-content: space-between; align-items: center; }
    .meta { font-size: 0.75rem; color: var(--sapContent_LabelColor); }
    .empty { padding: 2rem; text-align: center; color: var(--sapContent_LabelColor); display: flex; flex-direction: column; align-items: center; gap: 0.5rem; }
    .loading-container { display: flex; justify-content: center; padding: 3rem; }
    @media (max-width: 768px) { .governance-page { padding: 0.75rem; } .action-row { flex-direction: column; } }
  `]
})
export class GovernanceComponent implements OnInit, OnDestroy {
  private readonly http = inject(HttpClient);
  private readonly cdr = inject(ChangeDetectorRef);
  private readonly governance = inject(TeamGovernanceService);
  private readonly teamConfig = inject(TeamConfigService);
  private readonly auth = inject(AuthService);
  readonly i18n = inject(I18nService);
  private readonly toast = inject(ToastService);
  private readonly destroy$ = new Subject<void>();
  private readonly apiUrl = environment.apiBaseUrl;

  apiApprovals: ApiApproval[] = [];
  apiPolicies: ApiPolicy[] = [];
  loading = true;
  pendingApprovals: PendingApproval[] = [];
  policies: GovernancePolicyConfig[] = [];

  /** Expose Math to the template. */
  readonly Math = Math;

  ngOnInit(): void {
    this.loadApprovals();
    this.loadPolicies();
    // Also keep the client-side service connected for backward compat
    this.governance.pendingApprovals$.pipe(takeUntil(this.destroy$))
      .subscribe(a => this.pendingApprovals = a.filter(x => x.status === 'pending'));
    this.teamConfig.teamConfig$.pipe(takeUntil(this.destroy$))
      .subscribe(c => this.policies = c?.settings.governancePolicies ?? []);
  }

  ngOnDestroy(): void { this.destroy$.next(); this.destroy$.complete(); }

  loadApprovals(): void {
    this.http.get<{ approvals: ApiApproval[] }>(`${this.apiUrl}/governance/approvals`)
      .pipe(takeUntil(this.destroy$))
      .subscribe({ next: r => { this.apiApprovals = r.approvals; this.loading = false; this.cdr.markForCheck(); }, error: () => { this.loading = false; this.toast.error(this.i18n.t('governance.loadApprovalsFailed')); this.cdr.markForCheck(); } });
  }

  loadPolicies(): void {
    this.http.get<{ policies: ApiPolicy[] }>(`${this.apiUrl}/governance/policies`)
      .pipe(takeUntil(this.destroy$))
      .subscribe({ next: r => { this.apiPolicies = r.policies; this.cdr.markForCheck(); }, error: () => { this.toast.error(this.i18n.t('governance.loadPoliciesFailed')); this.cdr.markForCheck(); } });
  }

  getRiskIcon(r: string): string { return r === 'critical' ? 'alert' : r === 'high' ? 'warning' : r === 'medium' ? 'information' : 'hint'; }
  getRiskDesign(r: string): string { return r === 'critical' ? 'Negative' : r === 'high' ? 'Critical' : r === 'medium' ? 'Information' : 'Positive'; }

  approveApi(a: ApiApproval): void {
    this.http.post<ApiApproval>(`${this.apiUrl}/governance/approvals/${a.id}/decide`, { approver: 'training-user', action: 'approve' })
      .pipe(takeUntil(this.destroy$))
      .subscribe({ next: () => this.loadApprovals(), error: () => this.toast.error(this.i18n.t('governance.approveFailed')) });
  }

  rejectApi(a: ApiApproval): void {
    this.http.post<ApiApproval>(`${this.apiUrl}/governance/approvals/${a.id}/decide`, { approver: 'training-user', action: 'reject', comment: this.i18n.t('governance.rejectedByReviewer') })
      .pipe(takeUntil(this.destroy$))
      .subscribe({ next: () => this.loadApprovals(), error: () => this.toast.error(this.i18n.t('governance.rejectFailed')) });
  }
}
