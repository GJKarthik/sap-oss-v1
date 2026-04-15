/**
 * Team Governance Service for Training Console
 *
 * Extends the existing HTTP-based governance page with team-aware
 * approval workflows: multi-approver chains, role-based visibility,
 * and integration with TeamConfigService for policy enforcement.
 */

import { Injectable, OnDestroy } from '@angular/core';
import { HttpClient } from '@angular/common/http';
import { BehaviorSubject, Subject } from 'rxjs';
import { catchError, takeUntil } from 'rxjs/operators';
import { of } from 'rxjs';
import { environment } from '../../environments/environment';
import { TeamConfigService, TeamRole, GovernancePolicyConfig } from './team-config.service';

export type RiskLevel = 'low' | 'medium' | 'high' | 'critical';

export interface PendingApproval {
  id: string;
  actionName: string;
  description: string;
  riskLevel: RiskLevel;
  requestedBy: string;
  requestedAt: Date;
  requiredApprovals: number;
  currentApprovals: ApprovalDecision[];
  status: 'pending' | 'approved' | 'rejected' | 'expired';
  expiresAt: Date;
  arguments: Record<string, unknown>;
}

export interface ApprovalDecision {
  userId: string;
  displayName: string;
  role: TeamRole;
  decision: 'approve' | 'reject';
  reason?: string;
  decidedAt: Date;
}

export interface PolicyViolation {
  type: 'blocked' | 'unauthorized' | 'rate_limit';
  actionName: string;
  message: string;
  timestamp: Date;
}

@Injectable({ providedIn: 'root' })
export class TeamGovernanceService implements OnDestroy {
  private readonly destroy$ = new Subject<void>();
  private readonly apiUrl = `${environment.apiBaseUrl}/governance`;

  private readonly pendingApprovalsSubject = new BehaviorSubject<PendingApproval[]>([]);
  readonly pendingApprovals$ = this.pendingApprovalsSubject.asObservable();

  private readonly violationsSubject = new Subject<PolicyViolation>();
  readonly violations$ = this.violationsSubject.asObservable();

  private readonly blockedActions = new Set(['drop_table', 'delete_all', 'admin_reset']);

  constructor(
    private readonly http: HttpClient,
    private readonly teamConfig: TeamConfigService,
  ) {}

  /** Check if an action is blocked by team policy */
  isBlocked(actionName: string): boolean {
    if (this.blockedActions.has(actionName)) return true;
    const config = this.teamConfig.getTeamConfig();
    if (!config) return false;
    return config.settings.governancePolicies.some(
      p => p.active && p.ruleType === 'block' && p.name === actionName
    );
  }

  /** Check if an action requires team approval */
  requiresApproval(actionName: string): boolean {
    if (this.isBlocked(actionName)) return false;
    const config = this.teamConfig.getTeamConfig();
    if (!config) return false;
    return config.settings.governancePolicies.some(
      p => p.active && p.ruleType === 'approval' && p.name === actionName
    );
  }

  /** Create a pending approval request */
  createApprovalRequest(
    actionName: string,
    description: string,
    args: Record<string, unknown>,
    requestedBy: string,
  ): PendingApproval | null {
    if (this.isBlocked(actionName)) {
      this.violationsSubject.next({
        type: 'blocked', actionName, message: `Action '${actionName}' is blocked by team policy`, timestamp: new Date(),
      });
      return null;
    }

    const policy = this.findPolicy(actionName);
    const approval: PendingApproval = {
      id: crypto.randomUUID(),
      actionName, description, riskLevel: this.assessRisk(actionName),
      requestedBy, requestedAt: new Date(),
      requiredApprovals: policy?.requireApprovalCount ?? 1,
      currentApprovals: [], status: 'pending',
      expiresAt: new Date(Date.now() + 300_000),
      arguments: args,
    };

    const current = this.pendingApprovalsSubject.value;
    this.pendingApprovalsSubject.next([...current, approval]);

    // Persist to backend
    this.http.post(`${this.apiUrl}/approvals`, {
      title: approval.actionName,
      description: approval.description,
      risk_level: approval.riskLevel,
      requested_by: approval.requestedBy,
      approvers: approval.requiredApprovals > 1 ? ['team-lead', 'risk-owner'] : ['team-lead'],
      workflow_type: 'deployment',
    })
      .pipe(takeUntil(this.destroy$), catchError(() => of(null)))
      .subscribe();

    return approval;
  }

  /** Submit an approval decision */
  submitDecision(approvalId: string, userId: string, displayName: string, role: TeamRole, decision: 'approve' | 'reject', reason?: string): void {
    const approvals = this.pendingApprovalsSubject.value;
    const approval = approvals.find(a => a.id === approvalId);
    if (!approval || approval.status !== 'pending') return;

    approval.currentApprovals.push({ userId, displayName, role, decision, reason, decidedAt: new Date() });

    if (decision === 'reject') {
      approval.status = 'rejected';
    } else if (approval.currentApprovals.filter(d => d.decision === 'approve').length >= approval.requiredApprovals) {
      approval.status = 'approved';
    }

    this.pendingApprovalsSubject.next([...approvals]);
    this.http.post(`${this.apiUrl}/approvals/${approvalId}/decide`, { approver: userId, action: decision, comment: reason })
      .pipe(takeUntil(this.destroy$), catchError(() => of(null)))
      .subscribe();
  }

  /** Check if a user can approve based on team role */
  canApprove(userId: string, actionName: string): boolean {
    const policy = this.findPolicy(actionName);
    if (!policy) return false;
    const config = this.teamConfig.getTeamConfig();
    if (!config) return false;
    const member = config.members.find(m => m.userId === userId);
    if (!member) return false;
    return policy.approverRoles.includes(member.role);
  }

  private findPolicy(actionName: string): GovernancePolicyConfig | undefined {
    return this.teamConfig.getTeamConfig()?.settings.governancePolicies.find(
      p => p.active && p.name === actionName
    );
  }

  private assessRisk(actionName: string): RiskLevel {
    const lower = actionName.toLowerCase();
    if (['admin', 'system', 'security', 'config'].some(k => lower.includes(k))) return 'critical';
    if (['delete', 'remove', 'drop'].some(k => lower.includes(k))) return 'high';
    if (['update', 'modify'].some(k => lower.includes(k))) return 'medium';
    return 'low';
  }

  ngOnDestroy(): void {
    this.destroy$.next();
    this.destroy$.complete();
  }
}
