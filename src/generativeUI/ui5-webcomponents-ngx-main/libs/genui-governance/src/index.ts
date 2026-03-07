// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2023 SAP SE
/**
 * @ui5/genui-governance - Public API
 */

// Module
export { GenUiGovernanceModule, GenUiGovernanceConfig } from './lib/genui-governance.module';

// Governance
export {
  GovernanceService,
  GOVERNANCE_CONFIG,
  GovernanceConfig,
  PendingAction,
  AffectedData,
  ConfirmationResult,
  PolicyConfig,
  RoleRule,
  PolicyViolation,
} from './lib/services/governance.service';

// Audit
export {
  AuditService,
  AUDIT_CONFIG,
  AuditConfig,
  AuditEntry,
  AuditAction,
  AuditContext,
  AuditQuery,
  DataSource,
} from './lib/services/audit.service';