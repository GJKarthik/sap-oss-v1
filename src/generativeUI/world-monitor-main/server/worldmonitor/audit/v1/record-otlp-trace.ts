// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2024 SAP SE
import type {
  ServerContext,
  RecordOtlpTraceRequest,
  RecordOtlpTraceResponse,
  OtlpSpan,
  OtlpAttribute,
  AiDecision,
} from '../../../../src/generated/server/worldmonitor/audit/v1/service_server';
import { getRedis } from '../../../_shared/redis';
import {
  DECISIONS_KEY,
  MAX_DECISIONS_STORED,
  REDIS_TTL_SECONDS,
} from './_shared';

// ---------------------------------------------------------------------------
// Attribute helpers
// ---------------------------------------------------------------------------

function attr(attrs: OtlpAttribute[] | undefined, key: string): string {
  const a = attrs?.find(x => x.key === key);
  if (!a) return '';
  const v = a.value;
  return v.stringValue ?? v.intValue ?? String(v.doubleValue ?? v.boolValue ?? '');
}

function nanoToMs(nano: string): number {
  return Math.round(Number(BigInt(nano) / 1_000_000n));
}

// ---------------------------------------------------------------------------
// Span → AiDecision projection
// ---------------------------------------------------------------------------

function spanToDecision(
  span: OtlpSpan,
  resourceAttrs: OtlpAttribute[] | undefined,
  scopeName: string | undefined,
): AiDecision | null {
  // Only index spans from SAP AI Suite services
  const service = attr(resourceAttrs, 'service.name') ||
                  attr(span.attributes, 'sap.service') ||
                  scopeName || '';
  const knownServices = ['vllm', 'broker', 'mangle', 'ai-core-pal', 'ai-core-streaming',
                         'mangle-query-service', 'data-cleaning-copilot'];
  if (!knownServices.some(s => service.toLowerCase().includes(s))) return null;

  const startMs = nanoToMs(span.startTimeUnixNano);
  const endMs   = nanoToMs(span.endTimeUnixNano);

  return {
    traceId:                span.traceId,
    spanId:                 span.spanId,
    service,
    operation:              span.name,
    model:                  attr(span.attributes, 'gen_ai.request.model') ||
                            attr(span.attributes, 'vllm.model') || '',
    securityClass:          attr(span.attributes, 'sap.data.security_class') || 'unknown',
    mangleRulesEvaluated:   (attr(span.attributes, 'sap.mangle.rules_evaluated') || '')
                              .split(',').filter(Boolean),
    routingDecision:        attr(span.attributes, 'sap.mangle.routing_decision') || '',
    latencyMs:              endMs - startMs,
    ttftMs:                 Number(attr(span.attributes, 'gen_ai.server.time_to_first_token') || '0') * 1000,
    tokensIn:               Number(attr(span.attributes, 'gen_ai.usage.input_tokens')  || '0'),
    tokensOut:              Number(attr(span.attributes, 'gen_ai.usage.output_tokens') || '0'),
    acceptanceRate:         Number(attr(span.attributes, 'vllm.spec_decode.acceptance_rate') || '0'),
    gdprSubjectId:          attr(span.attributes, 'sap.gdpr.subject_id_anon') || '',
    region:                 attr(resourceAttrs, 'cloud.region') ||
                            attr(span.attributes, 'net.peer.name') || '',
    timestamp:              startMs,
    outcome:                (attr(span.attributes, 'sap.governance.outcome') as AiDecision['outcome']) || 'allowed',
  };
}

// ---------------------------------------------------------------------------
// Handler
// ---------------------------------------------------------------------------

export async function recordOtlpTrace(
  _ctx: ServerContext,
  req: RecordOtlpTraceRequest,
): Promise<RecordOtlpTraceResponse> {
  const redis = getRedis();
  const decisions: AiDecision[] = [];

  for (const rs of req.resourceSpans ?? []) {
    const resourceAttrs = rs.resource?.attributes;
    for (const ss of rs.scopeSpans ?? []) {
      const scopeName = ss.scope?.name;
      for (const span of ss.spans ?? []) {
        const d = spanToDecision(span, resourceAttrs, scopeName);
        if (d) decisions.push(d);
      }
    }
  }

  if (decisions.length > 0) {
    const pipeline = redis.pipeline();
    for (const d of decisions) {
      pipeline.zadd(DECISIONS_KEY, d.timestamp, JSON.stringify(d));
    }
    // Keep only the most recent MAX_DECISIONS_STORED entries
    pipeline.zremrangebyrank(DECISIONS_KEY, 0, -(MAX_DECISIONS_STORED + 1));
    pipeline.expire(DECISIONS_KEY, REDIS_TTL_SECONDS);
    await pipeline.exec();
  }

  return { accepted: decisions.length };
}

