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

function resolveHanaToolkitBase(): string {
  const envValue = (import.meta as { env?: Record<string, unknown> }).env?.VITE_HANA_TOOLKIT_URL;
  if (typeof envValue === 'string' && envValue.trim()) {
    return envValue.replace(/\/$/, '');
  }
  return 'http://127.0.0.1:9130';
}

function toNumber(value: unknown, fallback = 0): number {
  if (typeof value === 'number' && Number.isFinite(value)) return value;
  if (typeof value === 'string' && value.trim()) {
    const parsed = Number(value);
    if (Number.isFinite(parsed)) return parsed;
  }
  return fallback;
}

function toStringArray(value: unknown): string[] {
  if (Array.isArray(value)) return value.map(item => String(item));
  if (typeof value === 'string' && value.trim()) {
    try {
      const parsed = JSON.parse(value) as unknown;
      return Array.isArray(parsed) ? parsed.map(item => String(item)) : [value];
    } catch {
      return value.split(',').map(item => item.trim()).filter(Boolean);
    }
  }
  return [];
}

function normalizeOutcome(value: unknown): AiDecision['outcome'] {
  const raw = String(value ?? 'allowed').toLowerCase();
  if (raw === 'blocked' || raw === 'anonymised') return raw;
  return 'allowed';
}

function mapDecision(row: Record<string, unknown>): AiDecision {
  const timestampValue = row.timestamp ?? row.timestamp_ms;
  const timestamp = typeof timestampValue === 'string' && Number.isNaN(Number(timestampValue))
    ? Date.parse(timestampValue)
    : toNumber(timestampValue, Date.now());
  return {
    traceId: String(row.traceId ?? row.trace_id ?? ''),
    spanId: String(row.spanId ?? row.span_id ?? ''),
    service: String(row.service ?? 'world-monitor'),
    operation: String(row.operation ?? 'unknown'),
    model: String(row.model ?? ''),
    securityClass: String(row.securityClass ?? row.security_class ?? 'internal'),
    mangleRulesEvaluated: toStringArray(row.mangleRulesEvaluated ?? row.mangle_rules_evaluated ?? row.mangle_rules_json),
    routingDecision: String(row.routingDecision ?? row.routing_decision ?? ''),
    latencyMs: toNumber(row.latencyMs ?? row.latency_ms),
    ttftMs: toNumber(row.ttftMs ?? row.ttft_ms),
    tokensIn: toNumber(row.tokensIn ?? row.tokens_in),
    tokensOut: toNumber(row.tokensOut ?? row.tokens_out),
    acceptanceRate: toNumber(row.acceptanceRate ?? row.acceptance_rate),
    gdprSubjectId: String(row.gdprSubjectId ?? row.gdpr_subject_id ?? ''),
    region: String(row.region ?? ''),
    timestamp: Number.isFinite(timestamp) ? timestamp : Date.now(),
    outcome: normalizeOutcome(row.outcome),
  };
}

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

async function fetchHanaAuditDecisions(req: ListAiDecisionsRequest): Promise<AuditDecisionsResult> {
  const url = new URL('/audit/logs', resolveHanaToolkitBase());
  if (req.pageSize) url.searchParams.set('limit', String(req.pageSize));
  if (req.serviceFilter) url.searchParams.set('service', req.serviceFilter);
  if (req.timeRange?.start) url.searchParams.set('sinceMs', String(req.timeRange.start));
  if (req.timeRange?.end) url.searchParams.set('untilMs', String(req.timeRange.end));

  const res = await fetch(url.toString(), { headers: { Accept: 'application/json' } });
  if (!res.ok) throw new Error(`hana-toolkit audit/logs: ${res.status}`);
  const payload = await res.json() as {
    decisions?: Record<string, unknown>[];
    logs?: Record<string, unknown>[];
    count?: number;
  };
  const rawRows = Array.isArray(payload.decisions) ? payload.decisions : Array.isArray(payload.logs) ? payload.logs : [];
  const decisions = rawRows.map(mapDecision);
  return {
    success: true,
    decisions,
    nextCursor: '',
    totalCount: typeof payload.count === 'number' ? payload.count : decisions.length,
  };
}

export async function fetchAiDecisions(
  req: ListAiDecisionsRequest = {},
): Promise<AuditDecisionsResult> {
  try {
    return await fetchHanaAuditDecisions(req);
  } catch {
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

