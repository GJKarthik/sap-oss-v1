// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2024 SAP SE
/**
 * Client-side audit service.
 *
 * Fetches AI decision audit events from the /api/audit/v1/ endpoints,
 * and provides a helper to push OTLP spans (used by vLLM / broker / Mangle
 * when running locally or in the same network).
 */

import type {
  AiDecision,
  GetAuditSummaryResponse,
  ListAiDecisionsRequest,
  RecordOtlpTraceRequest,
} from '../generated/server/worldmonitor/audit/v1/service_server';

const BASE = '/api/audit/v1';

async function post<T>(path: string, body: unknown): Promise<T> {
  const res = await fetch(`${BASE}/${path}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  });
  if (!res.ok) throw new Error(`audit API ${path}: ${res.status}`);
  return res.json() as Promise<T>;
}

// ---------------------------------------------------------------------------

export interface AuditDecisionsResult {
  success: boolean;
  decisions: AiDecision[];
  nextCursor: string;
  totalCount: number;
  error?: string;
}

export async function fetchAiDecisions(
  req: ListAiDecisionsRequest = {},
): Promise<AuditDecisionsResult> {
  try {
    const data = await post<{ decisions: AiDecision[]; nextCursor: string; totalCount: number }>(
      'list-ai-decisions', req,
    );
    return { success: true, ...data };
  } catch (err) {
    return {
      success: false,
      decisions: [],
      nextCursor: '',
      totalCount: 0,
      error: err instanceof Error ? err.message : 'Failed to fetch AI decisions',
    };
  }
}

export interface AuditSummaryResult {
  success: boolean;
  summary?: GetAuditSummaryResponse;
  error?: string;
}

export async function fetchAuditSummary(
  timeRange?: { start: number; end: number },
): Promise<AuditSummaryResult> {
  try {
    const summary = await post<GetAuditSummaryResponse>('get-audit-summary', { timeRange });
    return { success: true, summary };
  } catch (err) {
    return { success: false, error: err instanceof Error ? err.message : 'Failed' };
  }
}

/**
 * Push an OTLP JSON trace payload to the audit collector.
 * Called by local SAP AI Suite services that can reach World Monitor.
 */
export async function pushOtlpTrace(req: RecordOtlpTraceRequest): Promise<number> {
  const res = await post<{ accepted: number }>('record-otlp-trace', req);
  return res.accepted;
}

