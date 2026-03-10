// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2023 SAP SE
/**
 * Governance Service
 *
 * Manages action confirmation workflows and policy enforcement
 * for AI-generated UI actions.
 */

import { Injectable, OnDestroy, Inject, Optional, InjectionToken } from '@angular/core';
import { Subject, BehaviorSubject } from 'rxjs';
import { takeUntil, filter } from 'rxjs/operators';
import { AgUiClient, AgUiToolRegistry, ToolCallStartEvent } from '@ui5/ag-ui-angular';

// =============================================================================
// Types
// =============================================================================

/** Action requiring confirmation */
export interface PendingAction {
  /** Unique action ID */
  id: string;
  /** Tool name being invoked */
  toolName: string;
  /** Arguments to the tool */
  arguments: Record<string, unknown>;
  /** Action description for user */
  description: string;
  /** Risk level */
  riskLevel: 'low' | 'medium' | 'high' | 'critical';
  /** Data being affected */
  affectedData?: AffectedData[];
  /** Created timestamp */
  createdAt: Date;
  /** Expiration timestamp */
  expiresAt?: Date;
  /** Run ID */
  runId?: string;
  /** Whether modifications are allowed */
  allowModifications: boolean;
}

/** Data affected by an action */
export interface AffectedData {
  /** Entity type */
  entityType: string;
  /** Entity identifier */
  entityId: string;
  /** Fields being modified */
  fields?: string[];
  /** Change type */
  changeType: 'create' | 'update' | 'delete' | 'execute';
}

/** Action confirmation result */
export interface ConfirmationResult {
  actionId: string;
  confirmed: boolean;
  modifications?: Record<string, unknown>;
  reason?: string;
  confirmedBy: string;
  confirmedAt: Date;
}

/** Policy configuration */
export interface PolicyConfig {
  /** Actions requiring confirmation */
  requireConfirmation: string[];
  /** Blocked actions */
  blockedActions: string[];
  /** Timeout for pending actions (ms) */
  confirmationTimeout: number;
  /** Role-based rules */
  roleRules?: RoleRule[];
}

/** Role-based rule */
export interface RoleRule {
  role: string;
  allowed: string[];
  denied: string[];
  requireConfirmation: string[];
}

/** Default policy configuration */
const DEFAULT_POLICY: PolicyConfig = {
  requireConfirmation: [
    'create_purchase_order',
    'approve_request',
    'submit_payment',
    'delete_record',
    'modify_user',
    'change_settings',
  ],
  blockedActions: [
    'drop_table',
    'delete_all',
    'admin_reset',
  ],
  confirmationTimeout: 300000, // 5 minutes
};

export const GOVERNANCE_CONFIG = new InjectionToken<GovernanceConfig>('GOVERNANCE_CONFIG');

export interface GovernanceConfig {
  policy?: Partial<PolicyConfig>;
  userId?: string;
  userRoles?: string[];
}

// =============================================================================
// Governance Service
// =============================================================================

@Injectable()
export class GovernanceService implements OnDestroy {
  private destroy$ = new Subject<void>();
  private policy: PolicyConfig = DEFAULT_POLICY;
  private userId = 'anonymous';
  private userRoles: string[] = [];

  // Pending actions
  private pendingActionsMap = new Map<string, PendingAction>();
  /** Maps governance actionId → transport toolCallId for deferred gating */
  private actionToToolCallId = new Map<string, string>();
  private pendingActionsSubject = new BehaviorSubject<PendingAction[]>([]);
  readonly pendingActions$ = this.pendingActionsSubject.asObservable();

  // Confirmation results
  private confirmationSubject = new Subject<ConfirmationResult>();
  readonly confirmation$ = this.confirmationSubject.asObservable();

  // Policy violations
  private violationSubject = new Subject<PolicyViolation>();
  readonly violation$ = this.violationSubject.asObservable();

  constructor(
    private agUiClient: AgUiClient,
    private toolRegistry: AgUiToolRegistry,
    @Optional() @Inject(GOVERNANCE_CONFIG) config?: GovernanceConfig
  ) {
    if (config) {
      this.configure(config);
    }
    this.subscribeToToolCalls();
  }

  /**
   * Configure the governance service
   */
  configure(config: GovernanceConfig): void {
    if (config.policy) {
      this.policy = {
        ...DEFAULT_POLICY,
        ...config.policy,
        // Always merge arrays additively so partial config cannot silently wipe hardened defaults
        blockedActions: [
          ...DEFAULT_POLICY.blockedActions,
          ...(config.policy.blockedActions ?? []),
        ],
        requireConfirmation: [
          ...DEFAULT_POLICY.requireConfirmation,
          ...(config.policy.requireConfirmation ?? []),
        ],
      };
    }
    if (config.userId) {
      this.userId = config.userId;
    }
    if (config.userRoles) {
      this.userRoles = config.userRoles;
    }
  }

  /**
   * Check if an action requires confirmation
   */
  requiresConfirmation(toolName: string): boolean {
    // Check if blocked
    if (this.isBlocked(toolName)) {
      return false; // Will be rejected entirely
    }

    // Check role-specific rules
    for (const role of this.userRoles) {
      const rule = this.policy.roleRules?.find(r => r.role === role);
      if (rule?.requireConfirmation.includes(toolName)) {
        return true;
      }
    }

    // Check global rules
    return this.policy.requireConfirmation.includes(toolName);
  }

  /**
   * Check if an action is blocked
   */
  isBlocked(toolName: string): boolean {
    // Check role-specific denials
    for (const role of this.userRoles) {
      const rule = this.policy.roleRules?.find(r => r.role === role);
      if (rule?.denied.includes(toolName)) {
        return true;
      }
    }

    // Check global blocks
    return this.policy.blockedActions.includes(toolName);
  }

  /**
   * Create a pending action for confirmation
   */
  createPendingAction(
    toolName: string,
    args: Record<string, unknown>,
    options?: Partial<PendingAction>
  ): PendingAction {
    const id = this.generateId();
    const action: PendingAction = {
      id,
      toolName,
      arguments: args,
      description: options?.description || `Execute ${toolName}`,
      riskLevel: options?.riskLevel || this.assessRiskLevel(toolName),
      affectedData: options?.affectedData,
      createdAt: new Date(),
      expiresAt: new Date(Date.now() + this.policy.confirmationTimeout),
      runId: options?.runId || this.agUiClient.getCurrentRunId() || undefined,
      allowModifications: options?.allowModifications ?? true,
    };

    this.pendingActionsMap.set(id, action);
    this.emitPendingActions();

    // Set expiration timer
    setTimeout(() => {
      if (this.pendingActionsMap.has(id)) {
        this.expireAction(id);
      }
    }, this.policy.confirmationTimeout);

    return action;
  }

  /**
   * Confirm a pending action
   */
  async confirmAction(
    actionId: string,
    modifications?: Record<string, unknown>
  ): Promise<void> {
    const action = this.pendingActionsMap.get(actionId);
    if (!action) {
      throw new Error(`Action ${actionId} not found or expired`);
    }

    // Apply modifications
    const finalArgs = modifications
      ? { ...action.arguments, ...modifications }
      : action.arguments;

    // Remove from pending
    this.pendingActionsMap.delete(actionId);
    this.emitPendingActions();

    // Emit confirmation
    const result: ConfirmationResult = {
      actionId,
      confirmed: true,
      modifications,
      confirmedBy: this.userId,
      confirmedAt: new Date(),
    };
    this.confirmationSubject.next(result);

    // Resolve the deferred tool execution gate (if any)
    const toolCallId = this.actionToToolCallId.get(actionId);
    if (toolCallId) {
      this.actionToToolCallId.delete(actionId);
      this.toolRegistry.resolveDeferred(toolCallId);
    }

    // Send confirmation to agent
    await this.agUiClient.confirmAction(actionId, modifications);
  }

  /**
   * Reject a pending action
   */
  async rejectAction(actionId: string, reason?: string): Promise<void> {
    const action = this.pendingActionsMap.get(actionId);
    if (!action) {
      throw new Error(`Action ${actionId} not found or expired`);
    }

    // Remove from pending
    this.pendingActionsMap.delete(actionId);
    this.emitPendingActions();

    // Emit rejection
    const result: ConfirmationResult = {
      actionId,
      confirmed: false,
      reason,
      confirmedBy: this.userId,
      confirmedAt: new Date(),
    };
    this.confirmationSubject.next(result);

    // Reject the deferred tool execution gate (if any)
    const toolCallId = this.actionToToolCallId.get(actionId);
    if (toolCallId) {
      this.actionToToolCallId.delete(actionId);
      this.toolRegistry.rejectDeferred(toolCallId, reason || 'User rejected');
    }

    // Send rejection to agent
    await this.agUiClient.rejectAction(actionId, reason);
  }

  /**
   * Get pending actions
   */
  getPendingActions(): PendingAction[] {
    return Array.from(this.pendingActionsMap.values());
  }

  /**
   * Get a specific pending action
   */
  getPendingAction(actionId: string): PendingAction | undefined {
    return this.pendingActionsMap.get(actionId);
  }

  /**
   * Subscribe to tool calls and intercept those requiring confirmation.
   * Blocked tools emit a violation and are not executed.
   * Tools requiring confirmation are deferred via AgUiToolRegistry until the
   * user confirms or rejects via confirmAction() / rejectAction().
   */
  private subscribeToToolCalls(): void {
    this.agUiClient.tool$
      .pipe(
        takeUntil(this.destroy$),
        filter((e): e is ToolCallStartEvent => (e as ToolCallStartEvent).type === 'tool.call_start')
      )
      .subscribe((event: ToolCallStartEvent) => {
        // Skip frontend tools (handled by ToolRegistry directly)
        if (event.location === 'frontend') return;

        // Check if blocked — emit violation, do not gate (execution never started)
        if (this.isBlocked(event.toolName)) {
          this.violationSubject.next({
            type: 'blocked_action',
            toolName: event.toolName,
            message: `Action '${event.toolName}' is blocked by policy`,
          });
          return;
        }

        // Check if confirmation is required — defer and wait
        if (this.requiresConfirmation(event.toolName)) {
          const action = this.createPendingAction(event.toolName, {}, {
            runId: event.runId,
          });

          // Map the governance actionId ↔ toolCallId for later resolution
          this.actionToToolCallId.set(action.id, event.toolCallId);

          // Pause tool execution until confirmed/rejected
          this.toolRegistry.deferInvocation(event.toolCallId).catch(() => {
            // Rejection is handled in rejectAction(); swallow the unhandled rejection here
          });
        }
      });
  }

  /**
   * Assess risk level of an action
   */
  private assessRiskLevel(toolName: string): PendingAction['riskLevel'] {
    const highRisk = ['delete', 'remove', 'drop', 'terminate', 'cancel'];
    const critical = ['admin', 'system', 'config', 'security'];

    const lower = toolName.toLowerCase();

    if (critical.some(k => lower.includes(k))) return 'critical';
    if (highRisk.some(k => lower.includes(k))) return 'high';
    if (lower.includes('update') || lower.includes('modify')) return 'medium';
    return 'low';
  }

  /**
   * Expire a pending action
   */
  private expireAction(actionId: string): void {
    const action = this.pendingActionsMap.get(actionId);
    if (action) {
      this.pendingActionsMap.delete(actionId);
      this.emitPendingActions();

      // Reject the deferred tool execution gate (if any)
      const toolCallId = this.actionToToolCallId.get(actionId);
      if (toolCallId) {
        this.actionToToolCallId.delete(actionId);
        this.toolRegistry.rejectDeferred(toolCallId, 'Action expired');
      }

      // Emit as rejection
      this.confirmationSubject.next({
        actionId,
        confirmed: false,
        reason: 'Action expired',
        confirmedBy: 'system',
        confirmedAt: new Date(),
      });
    }
  }

  /**
   * Emit updated pending actions list
   */
  private emitPendingActions(): void {
    this.pendingActionsSubject.next(Array.from(this.pendingActionsMap.values()));
  }

  /**
   * Generate unique ID
   */
  private generateId(): string {
    return crypto.randomUUID();
  }

  ngOnDestroy(): void {
    this.destroy$.next();
    this.destroy$.complete();
    this.pendingActionsSubject.complete();
    this.confirmationSubject.complete();
    this.violationSubject.complete();
  }
}

/** Policy violation event */
export interface PolicyViolation {
  type: 'blocked_action' | 'unauthorized' | 'rate_limit';
  toolName: string;
  message: string;
}