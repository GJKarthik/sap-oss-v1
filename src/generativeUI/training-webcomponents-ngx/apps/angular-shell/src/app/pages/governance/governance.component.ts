/**
 * Team Governance Page for Training Console
 *
 * Provides team approval workflows for AI training actions.
 * Uses Angular 20 standalone + @if/@for control flow.
 */

import { Component, CUSTOM_ELEMENTS_SCHEMA, ChangeDetectionStrategy, inject, OnInit, OnDestroy } from '@angular/core';
import { Subject, takeUntil } from 'rxjs';
import { TeamGovernanceService, PendingApproval } from '../../services/team-governance.service';
import { TeamConfigService, GovernancePolicyConfig } from '../../services/team-config.service';
import { AuthService } from '../../services/auth.service';
import { I18nService } from '../../services/i18n.service';
import '@ui5/webcomponents/dist/Card.js';
import '@ui5/webcomponents/dist/Tag.js';
import '@ui5/webcomponents/dist/Button.js';
import '@ui5/webcomponents/dist/Icon.js';
import '@ui5/webcomponents/dist/Dialog.js';
import '@ui5/webcomponents/dist/TextArea.js';
import '@ui5/webcomponents/dist/Label.js';

@Component({
  selector: 'app-governance',
  standalone: true,
  schemas: [CUSTOM_ELEMENTS_SCHEMA],
  changeDetection: ChangeDetectionStrategy.OnPush,
  template: `
    <div class="governance-page">
      <header class="page-header">
        <h2>Team Governance</h2>
        <p class="subtitle">Multi-approver action review &amp; team policies</p>
      </header>

      <!-- Pending Approvals -->
      <section class="section">
        <h3>Pending Approvals <ui5-tag>{{ pendingApprovals.length }}</ui5-tag></h3>
        @if (pendingApprovals.length > 0) {
          @for (approval of pendingApprovals; track approval.id) {
            <div class="approval-card">
              <div class="approval-header">
                <div class="approval-title">
                  <ui5-icon [attr.name]="getRiskIcon(approval.riskLevel)"></ui5-icon>
                  <strong>{{ approval.actionName }}</strong>
                  <ui5-tag [attr.design]="getRiskDesign(approval.riskLevel)">{{ approval.riskLevel }}</ui5-tag>
                </div>
                <span class="meta">by {{ approval.requestedBy }}</span>
              </div>
              <p class="approval-desc">{{ approval.description }}</p>
              <div class="progress-row">
                <span class="meta">{{ approval.currentApprovals.length }} / {{ approval.requiredApprovals }} approvals</span>
                <div class="progress-bar"><div class="progress-fill" [style.width.%]="(approval.currentApprovals.length / approval.requiredApprovals) * 100"></div></div>
              </div>
              @for (decision of approval.currentApprovals; track decision.userId) {
                <div class="decision-row">
                  <ui5-icon [attr.name]="decision.decision === 'approve' ? 'accept' : 'decline'"></ui5-icon>
                  {{ decision.displayName }} ({{ decision.role }})
                  @if (decision.reason) { <span class="meta"> — {{ decision.reason }}</span> }
                </div>
              }
              @if (canApprove(approval)) {
                <div class="action-row">
                  <ui5-button design="Positive" icon="accept" (click)="approve(approval)">Approve</ui5-button>
                  <ui5-button design="Negative" icon="decline" (click)="reject(approval)">Reject</ui5-button>
                </div>
              } @else {
                <ui5-tag design="Information">Awaiting other approvers</ui5-tag>
              }
            </div>
          }
        } @else {
          <div class="empty">
            <ui5-icon name="approvals" style="font-size: 2rem;"></ui5-icon>
            <p>No pending approvals</p>
          </div>
        }
      </section>

      <!-- Team Policies -->
      <section class="section">
        <h3>Team Policies</h3>
        @if (policies.length > 0) {
          @for (policy of policies; track policy.id) {
            <div class="policy-card">
              <div class="policy-row">
                <strong>{{ policy.name }}</strong>
                <ui5-tag [attr.design]="policy.active ? 'Positive' : 'Negative'">{{ policy.active ? 'Active' : 'Inactive' }}</ui5-tag>
              </div>
              <span class="meta">Type: {{ policy.ruleType }} · Requires {{ policy.requireApprovalCount }} approval(s) · Roles: {{ policy.approverRoles.join(', ') }}</span>
            </div>
          }
        } @else {
          <div class="empty"><p>No team policies configured. Configure via Team Settings.</p></div>
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
  `]
})
export class GovernanceComponent implements OnInit, OnDestroy {
  private readonly governance = inject(TeamGovernanceService);
  private readonly teamConfig = inject(TeamConfigService);
  private readonly auth = inject(AuthService);
  private readonly destroy$ = new Subject<void>();

  pendingApprovals: PendingApproval[] = [];
  policies: GovernancePolicyConfig[] = [];

  ngOnInit(): void {
    this.governance.pendingApprovals$.pipe(takeUntil(this.destroy$))
      .subscribe(a => this.pendingApprovals = a.filter(x => x.status === 'pending'));
    this.teamConfig.teamConfig$.pipe(takeUntil(this.destroy$))
      .subscribe(c => this.policies = c?.settings.governancePolicies ?? []);
  }

  ngOnDestroy(): void { this.destroy$.next(); this.destroy$.complete(); }

  getRiskIcon(r: string): string { return r === 'critical' ? 'alert' : r === 'high' ? 'warning' : r === 'medium' ? 'information' : 'hint'; }
  getRiskDesign(r: string): string { return r === 'critical' ? 'Negative' : r === 'high' ? 'Critical' : r === 'medium' ? 'Information' : 'Positive'; }

  canApprove(a: PendingApproval): boolean {
    const u = this.auth.token() ? 'training-user' : '';
    return u !== a.requestedBy && !a.currentApprovals.some(d => d.userId === u) && this.governance.canApprove(u, a.actionName);
  }

  approve(a: PendingApproval): void { this.governance.submitDecision(a.id, 'training-user', 'Training User', 'editor', 'approve'); }
  reject(a: PendingApproval): void { this.governance.submitDecision(a.id, 'training-user', 'Training User', 'editor', 'reject'); }
}
