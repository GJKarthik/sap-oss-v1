// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2024 SAP SE
import type { AuditServiceHandler } from '../../../../src/generated/server/worldmonitor/audit/v1/service_server';
import { recordOtlpTrace } from './record-otlp-trace';
import { listAiDecisions } from './list-ai-decisions';
import { getAuditSummary } from './get-audit-summary';

export const auditHandler: AuditServiceHandler = {
  recordOtlpTrace,
  listAiDecisions,
  getAuditSummary,
};

