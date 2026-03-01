// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2024 SAP SE
import type {
  ServerContext,
  ListAiDecisionsRequest,
  ListAiDecisionsResponse,
  AiDecision,
} from '../../../../src/generated/server/worldmonitor/audit/v1/service_server';
import { getRedis } from '../../../_shared/redis';
import { DECISIONS_KEY } from './_shared';

export async function listAiDecisions(
  _ctx: ServerContext,
  req: ListAiDecisionsRequest,
): Promise<ListAiDecisionsResponse> {
  const redis = getRedis();
  const pageSize = Math.min(req.pageSize ?? 50, 200);
  const now = Date.now();
  const windowStart = req.timeRange?.start ?? now - 3_600_000; // default: last 1 h
  const windowEnd   = req.timeRange?.end   ?? now;

  // Decode cursor (base64 of "timestamp:spanId" for stable pagination)
  let cursorScore = windowEnd;
  let cursorSpanId = '';
  if (req.cursor) {
    try {
      const decoded = atob(req.cursor);
      const parts = decoded.split(':');
      cursorScore  = Number(parts[0]);
      cursorSpanId = parts[1] ?? '';
    } catch { /* ignore invalid cursor */ }
  }

  // ZREVRANGEBYSCORE: most recent first, within time window
  const raw = await redis.zrevrangebyscore(
    DECISIONS_KEY,
    cursorScore,
    windowStart,
    'WITHSCORES',
    'LIMIT', 0, pageSize + 1,
  );

  // Parse: raw = [member, score, member, score, ...]
  const all: AiDecision[] = [];
  for (let i = 0; i < raw.length - 1; i += 2) {
    try {
      const d = JSON.parse(raw[i] as string) as AiDecision;
      // Skip cursor entry itself (avoid re-sending the last item of previous page)
      if (cursorSpanId && d.spanId === cursorSpanId) continue;
      all.push(d);
    } catch { /* skip malformed */ }
  }

  // Apply filters
  let filtered = all;
  if (req.serviceFilter) {
    filtered = filtered.filter(d => d.service.toLowerCase().includes(req.serviceFilter!.toLowerCase()));
  }
  if (req.securityClass) {
    filtered = filtered.filter(d => d.securityClass === req.securityClass);
  }

  const page = filtered.slice(0, pageSize);
  const hasMore = filtered.length > pageSize;

  let nextCursor = '';
  if (hasMore && page.length > 0) {
    const last = page[page.length - 1];
    nextCursor = btoa(`${last.timestamp}:${last.spanId}`);
  }

  // Total count in window (approximate: count all members in score range)
  const totalCount = await redis.zcount(DECISIONS_KEY, windowStart, windowEnd);

  return { decisions: page, nextCursor, totalCount };
}

