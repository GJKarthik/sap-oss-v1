/**
 * Team Approval Panel Component
 *
 * Displays pending multi-approver approval requests and allows
 * team members to approve/reject actions based on their role.
 */

import { Component, DestroyRef, OnInit, inject } from '@angular/core';
import { CommonModule } from '@angular/common';
import { takeUntilDestroyed } from '@angular/core/rxjs-interop';
import { Ui5WebcomponentsModule } from '@ui5/webcomponents-ngx';
import { TeamGovernanceService, PendingApproval } from '../../services/team-governance.service';
import { TeamConfigService } from '../../services/team-config.service';
import { AuthService } from '../../services/auth.service';
import { DateFormatPipe } from '../../shared';

@Component({
  selector: 'app-team-approval-panel',
  standalone: true,
  imports: [CommonModule, Ui5WebcomponentsModule, DateFormatPipe],
  template: `
    <ui5-card>
      <ui5-card-header
        slot="header"
        title-text="Team Approvals"
        subtitle-text="Multi-approver action requests"
        [additionalText]="pendingApprovals.length + ' pending'">
      </ui5-card-header>

      <div class="approval-list" *ngIf="pendingApprovals.length > 0">
        <div class="approval-item" *ngFor="let approval of pendingApprovals; trackBy: trackById">
          <div class="approval-header">
            <div class="approval-title">
              <ui5-icon [name]="getRiskIcon(approval.riskLevel)" [attr.aria-hidden]="true"></ui5-icon>
              <strong>{{ approval.actionName }}</strong>
              <ui5-tag [design]="getRiskDesign(approval.riskLevel)">{{ approval.riskLevel }}</ui5-tag>
            </div>
            <span class="approval-time">{{ approval.requestedAt | dateFormat:'short' }}</span>
          </div>

          <p class="approval-description">{{ approval.description }}</p>

          <div class="approval-progress">
            <span class="progress-label">
              {{ approval.currentApprovals.length }} / {{ approval.requiredApprovals }} approvals
            </span>
            <div class="progress-bar">
              <div class="progress-fill"
                [style.width.%]="(approval.currentApprovals.length / approval.requiredApprovals) * 100">
              </div>
            </div>
          </div>

          <div class="approval-decisions" *ngIf="approval.currentApprovals.length > 0">
            <div class="decision" *ngFor="let decision of approval.currentApprovals">
              <ui5-icon [name]="decision.decision === 'approve' ? 'accept' : 'decline'" [attr.aria-hidden]="true"></ui5-icon>
              <span>{{ decision.displayName }} ({{ decision.role }})</span>
              <span class="decision-reason" *ngIf="decision.reason">— {{ decision.reason }}</span>
            </div>
          </div>

          <div class="approval-args" *ngIf="approval.arguments && hasArgs(approval)">
            <details>
              <summary>Arguments</summary>
              <pre>{{ approval.arguments | json }}</pre>
            </details>
          </div>

          <div class="approval-actions" *ngIf="canApprove(approval)">
            <ui5-button design="Positive" icon="accept" (click)="approve(approval)">
              Approve
            </ui5-button>
            <ui5-button design="Negative" icon="decline" (click)="showRejectDialog(approval)">
              Reject
            </ui5-button>
          </div>
          <div class="approval-status" *ngIf="!canApprove(approval) && approval.status === 'pending'">
            <ui5-tag design="Information">Awaiting other approvers</ui5-tag>
          </div>
        </div>
      </div>

      <div class="empty-state" *ngIf="pendingApprovals.length === 0">
        <ui5-icon name="approvals" style="font-size: 2rem; color: var(--sapContent_LabelColor);"></ui5-icon>
        <p>No pending team approvals</p>
      </div>
    </ui5-card>

    <!-- Reject reason dialog -->
    <ui5-dialog #rejectDialog header-text="Reject Action">
      <div style="padding: 1rem; display: flex; flex-direction: column; gap: 1rem;">
        <ui5-label>Reason for rejection:</ui5-label>
        <ui5-textarea #rejectReason [rows]="3" placeholder="Optional reason..." growing></ui5-textarea>
      </div>
      <div slot="footer" style="display: flex; gap: 0.5rem; justify-content: flex-end; padding: 0.5rem;">
        <ui5-button design="Negative" (click)="confirmReject()">Reject</ui5-button>
        <ui5-button design="Transparent" (click)="cancelReject()">Cancel</ui5-button>
      </div>
    </ui5-dialog>
  `,

  styles: [`
    .approval-list { padding: 0.75rem; display: flex; flex-direction: column; gap: 1rem; }
    .approval-item { border: 1px solid var(--sapTile_BorderColor, #e4e4e4); border-radius: 0.5rem; padding: 1rem; }
    .approval-header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 0.5rem; }
    .approval-title { display: flex; align-items: center; gap: 0.5rem; }
    .approval-time { font-size: 0.75rem; color: var(--sapContent_LabelColor); }
    .approval-description { margin: 0.5rem 0; font-size: 0.875rem; color: var(--sapTextColor); }
    .approval-progress { margin: 0.75rem 0; }
    .progress-label { font-size: 0.75rem; color: var(--sapContent_LabelColor); display: block; margin-bottom: 0.25rem; }
    .progress-bar { height: 4px; background: var(--sapField_BorderColor, #89919a); border-radius: 2px; overflow: hidden; }
    .progress-fill { height: 100%; background: var(--sapPositiveColor, #107e3e); transition: width 0.3s; }
    .approval-decisions { margin: 0.5rem 0; display: flex; flex-direction: column; gap: 0.25rem; }
    .decision { display: flex; align-items: center; gap: 0.5rem; font-size: 0.8125rem; }
    .decision-reason { color: var(--sapContent_LabelColor); font-style: italic; }
    .approval-args { margin: 0.5rem 0; }
    .approval-args pre { background: var(--sapShell_Background, #f5f6f7); padding: 0.5rem; border-radius: 0.25rem; overflow-x: auto; font-size: 0.75rem; max-height: 150px; }
    .approval-actions { display: flex; gap: 0.5rem; margin-top: 0.75rem; }
    .approval-status { margin-top: 0.75rem; }
    .empty-state { padding: 2rem; text-align: center; color: var(--sapContent_LabelColor); display: flex; flex-direction: column; align-items: center; gap: 0.5rem; }
  `]
})
export class TeamApprovalPanelComponent implements OnInit {
  private readonly destroyRef = inject(DestroyRef);
  private readonly governance = inject(TeamGovernanceService);
  private readonly teamConfig = inject(TeamConfigService);
  private readonly auth = inject(AuthService);

  pendingApprovals: PendingApproval[] = [];
  private rejectingApproval: PendingApproval | null = null;
  private rejectDialogEl: any = null;
  private rejectReasonEl: any = null;

  ngOnInit(): void {
    this.governance.pendingApprovals$
      .pipe(takeUntilDestroyed(this.destroyRef))
      .subscribe(approvals => {
        this.pendingApprovals = approvals.filter(a => a.status === 'pending');
      });
  }

  trackById(_: number, item: PendingApproval): string { return item.id; }

  getRiskIcon(risk: string): string {
    switch (risk) { case 'critical': return 'alert'; case 'high': return 'warning'; case 'medium': return 'information'; default: return 'hint'; }
  }

  getRiskDesign(risk: string): 'Positive' | 'Negative' | 'Critical' | 'Information' | 'Neutral' | 'Set1' | 'Set2' {
    switch (risk) { case 'critical': return 'Negative'; case 'high': return 'Critical'; case 'medium': return 'Information'; default: return 'Positive'; }
  }

  canApprove(approval: PendingApproval): boolean {
    const userId = this.auth.getUser()?.username || '';
    if (approval.requestedBy === userId) return false;
    if (approval.currentApprovals.some(d => d.userId === userId)) return false;
    return this.governance.canApprove(userId, approval.actionName);
  }

  hasArgs(approval: PendingApproval): boolean { return Object.keys(approval.arguments).length > 0; }

  approve(approval: PendingApproval): void {
    const user = this.auth.getUser();
    this.governance.submitDecision(approval.id, user?.username || '', user?.username || '', (user?.role as any) || 'viewer', 'approve');
  }

  showRejectDialog(approval: PendingApproval): void {
    this.rejectingApproval = approval;
    this.rejectDialogEl = document.querySelector('ui5-dialog[header-text="Reject Action"]');
    this.rejectReasonEl = this.rejectDialogEl?.querySelector('ui5-textarea');
    if (this.rejectDialogEl?.show) this.rejectDialogEl.show();
  }

  confirmReject(): void {
    if (!this.rejectingApproval) return;
    const user = this.auth.getUser();
    const reason = this.rejectReasonEl?.value || '';
    this.governance.submitDecision(this.rejectingApproval.id, user?.username || '', user?.username || '', (user?.role as any) || 'viewer', 'reject', reason || undefined);
    this.rejectingApproval = null;
    if (this.rejectDialogEl?.close) this.rejectDialogEl.close();
  }

  cancelReject(): void {
    this.rejectingApproval = null;
    if (this.rejectDialogEl?.close) this.rejectDialogEl.close();
  }
}