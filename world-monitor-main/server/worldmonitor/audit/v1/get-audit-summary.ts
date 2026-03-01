// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2024 SAP SE
import type {
  ServerContext,
  GetAuditSummaryRequest,
  GetAuditSummaryResponse,
  AiDecision,
} from '../../../../src/generated/server/worldmonitor/audit/v1/service_server';
import { getRedis } from '../../../_shared/redis';
import { DECISIONS_KEY, SUMMARY_CACHE_KEY, SUMMARY_CACHE_TTL } from './_shared';

export async function getAuditSummary(
  _ctx: ServerContext,
  req: GetAuditSummaryRequest,
): Promise<GetAuditSummaryResponse> {
  const redis = getRedis();
  const now = Date.now();
  const windowStart = req.timeRange?.start ?? now - 3_600_000;
  const windowEnd   = req.timeRange?.end   ?? now;

  // Short-circuit with cached summary for default 1-hour window
  const isDefaultWindow = !req.timeRange;
  if (isDefaultWindow) {
    const cached = await redis.get(SUMMARY_CACHE_KEY);
    if (cached) return JSON.parse(cached) as GetAuditSummaryResponse;
  }

  // Pull all decisions in window (up to 10k for aggregation)
  const raw = await redis.zrangebyscore(DECISIONS_KEY, windowStart, windowEnd, 'LIMIT', 0, 10_000);
  const decisions: AiDecision[] = raw.map((r: string) => {
    try { return JSON.parse(r) as AiDecision; } catch { return null; }
  }).filter(Boolean) as AiDecision[];

  if (decisions.length === 0) {
    return {
      totalDecisions: 0, allowedCount: 0, blockedCount: 0, anonymisedCount: 0,
      avgLatencyMs: 0, avgTtftMs: 0, avgAcceptanceRate: 0,
      byService: {}, bySecurityClass: {}, byRegion: {},
      gdprArticle32Events: 0, windowStart, windowEnd,
    };
  }

  let latencySum = 0, ttftSum = 0, acceptanceSum = 0;
  let allowedCount = 0, blockedCount = 0, anonymisedCount = 0, gdprEvents = 0;
  const byService: Record<string, number> = {};
  const bySecurityClass: Record<string, number> = {};
  const byRegion: Record<string, number> = {};

  for (const d of decisions) {
    latencySum    += d.latencyMs;
    ttftSum       += d.ttftMs;
    acceptanceSum += d.acceptanceRate;

    if (d.outcome === 'allowed')    allowedCount++;
    if (d.outcome === 'blocked')    blockedCount++;
    if (d.outcome === 'anonymised') anonymisedCount++;

    // GDPR Art 32 event: any blocked or anonymised decision is a security-of-processing event
    if (d.outcome !== 'allowed' || d.securityClass === 'confidential') gdprEvents++;

    byService[d.service]             = (byService[d.service] ?? 0) + 1;
    bySecurityClass[d.securityClass] = (bySecurityClass[d.securityClass] ?? 0) + 1;
    if (d.region) byRegion[d.region] = (byRegion[d.region] ?? 0) + 1;
  }

  const n = decisions.length;
  const summary: GetAuditSummaryResponse = {
    totalDecisions:   n,
    allowedCount,
    blockedCount,
    anonymisedCount,
    avgLatencyMs:     Math.round(latencySum / n),
    avgTtftMs:        Math.round(ttftSum / n),
    avgAcceptanceRate: Math.round((acceptanceSum / n) * 1000) / 1000,
    byService,
    bySecurityClass,
    byRegion,
    gdprArticle32Events: gdprEvents,
    windowStart,
    windowEnd,
  };

  if (isDefaultWindow) {
    await redis.setex(SUMMARY_CACHE_KEY, SUMMARY_CACHE_TTL, JSON.stringify(summary));
  }

  return summary;
}

