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
import { AgUiClient } from '../../../../ag-ui-angular/src/lib/services/ag-ui-client.service';
import { AgUiToolRegistry } from '../../../../ag-ui-angular/src/lib/services/tool-registry.service';
import { ToolCallArgsDoneEvent, ToolCallStartEvent } from '../../../../ag-ui-angular/src/lib/types/ag-ui-events';
import { AuditService } from './audit.service';

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

/** Human-readable review model for a pending action */
export interface PendingActionReview {
  action: PendingAction;
  riskLabel: string;
  riskDescription: string;
  affectedScope: AffectedScopeSummary;
  finalArguments: Record<string, unknown>;
  diff: ActionDiffEntry[];
}

/** Human-readable summary of affected scope */
export interface AffectedScopeSummary {
  entityCount: number;
  entities: string[];
  fieldCount: number;
  fields: string[];
  changeTypes: string[];
  summary: string;
}

/** Diff row for action arguments */
export interface ActionDiffEntry {
  path: string;
  before: unknown;
  after: unknown;
  changeType: 'added' | 'removed' | 'changed' | 'unchanged';
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
  /** Holds backend tool metadata until full args arrive via tool.call_args_done. */
  private pendingToolMetadata = new Map<string, { toolName: string; runId?: string }>();
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
    @Optional() @Inject(GOVERNANCE_CONFIG) config?: GovernanceConfig,
    @Optional() private auditService?: AuditService
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
      affectedData: options?.affectedData || this.inferAffectedData(toolName, args),
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
    this.auditService?.logConfirmation(result);

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
    this.auditService?.logConfirmation(result);

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
   * Build a UI-facing review model for a pending action.
   */
  buildPendingActionReview(
    actionOrId: string | PendingAction,
    modifications: Record<string, unknown> = {}
  ): PendingActionReview | undefined {
    const action = typeof actionOrId === 'string'
      ? this.pendingActionsMap.get(actionOrId)
      : actionOrId;

    if (!action) {
      return undefined;
    }

    const finalArguments = {
      ...action.arguments,
      ...modifications,
    };

    return {
      action,
      riskLabel: this.getRiskLabel(action.riskLevel),
      riskDescription: this.getRiskDescription(action.riskLevel),
      affectedScope: this.summarizeAffectedScope(action, finalArguments),
      finalArguments,
      diff: this.buildArgumentDiff(action.arguments, finalArguments),
    };
  }

  /**
   * Subscribe to tool calls and intercept those requiring confirmation.
   * Blocked tools emit a violation and are not executed.
   * Tools requiring confirmation are deferred on tool.call_start, but the
   * user-facing approval item is created only once tool.call_args_done arrives
   * with the complete argument payload.
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

        // For tools requiring confirmation, pause execution immediately but do
        // not create the approval item until the complete args payload arrives.
        if (this.requiresConfirmation(event.toolName)) {
          this.pendingToolMetadata.set(event.toolCallId, {
            toolName: event.toolName,
            runId: event.runId,
          });

          // Pause tool execution until confirmed/rejected
          this.toolRegistry.deferInvocation(event.toolCallId).catch(() => {
            // Rejection is handled in rejectAction(); swallow the unhandled rejection here
          });
        }
      });

    this.agUiClient.tool$
      .pipe(
        takeUntil(this.destroy$),
        filter((e): e is ToolCallArgsDoneEvent => (e as ToolCallArgsDoneEvent).type === 'tool.call_args_done')
      )
      .subscribe((event: ToolCallArgsDoneEvent) => {
        const metadata = this.pendingToolMetadata.get(event.toolCallId);
        if (!metadata) {
          return;
        }

        this.pendingToolMetadata.delete(event.toolCallId);

        const action = this.createPendingAction(metadata.toolName, event.arguments, {
          runId: metadata.runId,
        });

        // Map the governance actionId ↔ toolCallId for later resolution
        this.actionToToolCallId.set(action.id, event.toolCallId);
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

  private getRiskLabel(riskLevel: PendingAction['riskLevel']): string {
    switch (riskLevel) {
      case 'critical':
        return 'Critical risk';
      case 'high':
        return 'High risk';
      case 'medium':
        return 'Medium risk';
      default:
        return 'Low risk';
    }
  }

  private getRiskDescription(riskLevel: PendingAction['riskLevel']): string {
    switch (riskLevel) {
      case 'critical':
        return 'This action can change sensitive system or security state.';
      case 'high':
        return 'This action changes or removes important business data.';
      case 'medium':
        return 'This action modifies existing data and should be verified.';
      default:
        return 'This action has limited scope but should still be reviewed.';
    }
  }

  private summarizeAffectedScope(
    action: PendingAction,
    finalArguments: Record<string, unknown>
  ): AffectedScopeSummary {
    const affectedData = action.affectedData && action.affectedData.length > 0
      ? action.affectedData
      : this.inferAffectedData(action.toolName, finalArguments);

    const entities = Array.from(new Set(
      affectedData.map(item => `${item.entityType}:${item.entityId}`)
    ));
    const fields = Array.from(new Set(
      affectedData.flatMap(item => item.fields ?? [])
    ));
    const changeTypes = Array.from(new Set(
      affectedData.map(item => item.changeType)
    ));
    const entityCount = entities.length;
    const fieldCount = fields.length;
    const primaryEntityType = affectedData[0]?.entityType ?? 'record';

    return {
      entityCount,
      entities,
      fieldCount,
      fields,
      changeTypes,
      summary: `${entityCount} ${this.pluralize(primaryEntityType, entityCount)} · ${changeTypes.join(', ') || 'review'} · ${fieldCount} field${fieldCount === 1 ? '' : 's'}`,
    };
  }

  private buildArgumentDiff(
    beforeArgs: Record<string, unknown>,
    afterArgs: Record<string, unknown>
  ): ActionDiffEntry[] {
    const before = this.flattenArguments(beforeArgs);
    const after = this.flattenArguments(afterArgs);
    const paths = Array.from(new Set([...before.keys(), ...after.keys()])).sort();

    if (paths.length === 0) {
      return [{
        path: 'arguments',
        before: undefined,
        after: undefined,
        changeType: 'unchanged',
      }];
    }

    return paths.map(path => {
      const hasBefore = before.has(path);
      const hasAfter = after.has(path);
      const beforeValue = before.get(path);
      const afterValue = after.get(path);

      let changeType: ActionDiffEntry['changeType'] = 'unchanged';
      if (!hasBefore && hasAfter) {
        changeType = 'added';
      } else if (hasBefore && !hasAfter) {
        changeType = 'removed';
      } else if (!this.valuesEqual(beforeValue, afterValue)) {
        changeType = 'changed';
      }

      return {
        path,
        before: beforeValue,
        after: afterValue,
        changeType,
      };
    });
  }

  private inferAffectedData(toolName: string, args: Record<string, unknown>): AffectedData[] {
    const entityType = this.inferEntityType(toolName);
    const changeType = this.inferChangeType(toolName);
    const idKeys = Object.keys(args).filter(key => this.isIdentifierKey(key));
    const fieldKeys = Object.keys(args).filter(key => !this.isIdentifierKey(key));

    const entityIds = idKeys.length > 0
      ? idKeys.map(key => `${key}:${String(args[key])}`)
      : ['pending'];

    return entityIds.map(entityId => ({
      entityType,
      entityId,
      fields: fieldKeys,
      changeType,
    }));
  }

  private inferEntityType(toolName: string): string {
    const verbs = new Set(['create', 'update', 'modify', 'change', 'delete', 'remove', 'approve', 'submit', 'execute']);
    const parts = toolName.toLowerCase().split(/[_\-.]+/).filter(Boolean);
    const nounParts = parts.filter(part => !verbs.has(part));
    return nounParts[0] ?? 'record';
  }

  private inferChangeType(toolName: string): AffectedData['changeType'] {
    const lower = toolName.toLowerCase();
    if (lower.includes('delete') || lower.includes('remove')) return 'delete';
    if (lower.includes('create')) return 'create';
    if (lower.includes('execute') || lower.includes('approve') || lower.includes('submit')) return 'execute';
    return 'update';
  }

  private flattenArguments(
    value: Record<string, unknown>,
    prefix = ''
  ): Map<string, unknown> {
    const entries = new Map<string, unknown>();

    for (const [key, nested] of Object.entries(value)) {
      const path = prefix ? `${prefix}.${key}` : key;
      if (Array.isArray(nested)) {
        if (nested.length === 0) {
          entries.set(path, []);
          continue;
        }
        nested.forEach((item, index) => {
          if (item && typeof item === 'object') {
            this.flattenObjectValue(item as Record<string, unknown>, `${path}[${index}]`, entries);
          } else {
            entries.set(`${path}[${index}]`, item);
          }
        });
        continue;
      }

      if (nested && typeof nested === 'object') {
        this.flattenObjectValue(nested as Record<string, unknown>, path, entries);
        continue;
      }

      entries.set(path, nested);
    }

    return entries;
  }

  private flattenObjectValue(
    value: Record<string, unknown>,
    prefix: string,
    entries: Map<string, unknown>
  ): void {
    const keys = Object.keys(value);
    if (keys.length === 0) {
      entries.set(prefix, {});
      return;
    }

    keys.forEach(key => {
      const nested = value[key];
      const path = `${prefix}.${key}`;
      if (Array.isArray(nested)) {
        if (nested.length === 0) {
          entries.set(path, []);
          return;
        }
        nested.forEach((item, index) => {
          if (item && typeof item === 'object') {
            this.flattenObjectValue(item as Record<string, unknown>, `${path}[${index}]`, entries);
          } else {
            entries.set(`${path}[${index}]`, item);
          }
        });
        return;
      }

      if (nested && typeof nested === 'object') {
        this.flattenObjectValue(nested as Record<string, unknown>, path, entries);
        return;
      }

      entries.set(path, nested);
    });
  }

  private valuesEqual(left: unknown, right: unknown): boolean {
    return JSON.stringify(left) === JSON.stringify(right);
  }

  private isIdentifierKey(key: string): boolean {
    return /(^id$|Id$|_id$|Ids$|_ids$)/i.test(key);
  }

  private pluralize(noun: string, count: number): string {
    return count === 1 ? noun : `${noun}s`;
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
      this.auditService?.log(
        {
          type: 'rejection',
          description: `Action ${action.toolName} expired`,
        },
        'expired',
        { runId: action.runId }
      );
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
    this.pendingToolMetadata.clear();
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
