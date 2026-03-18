// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2024 SAP SE
import { Panel } from './Panel';
import { h, replaceChildren, type DomChild } from '@/utils/dom-utils';
import { fetchAiDecisions } from '@/services/audit';
import type { AiDecision, GetAuditSummaryResponse } from '@/generated/server/worldmonitor/audit/v1/service_server';

type Filter = 'all' | 'allowed' | 'blocked' | 'anonymised';

const OUTCOME_COLOUR: Record<AiDecision['outcome'], string> = {
  allowed:    '#22c55e',
  blocked:    '#ef4444',
  anonymised: '#f59e0b',
};
const SEC_BADGE: Record<string, string> = {
  confidential: '#7c3aed',
  internal:     '#2563eb',
  public:       '#16a34a',
  unknown:      '#6b7280',
};

function fmt(ms: number): string { return ms < 1000 ? `${ms}ms` : `${(ms / 1000).toFixed(1)}s`; }

function buildSummary(decisions: AiDecision[]): GetAuditSummaryResponse {
  const now = Date.now();
  if (decisions.length === 0) {
    return {
      totalDecisions: 0,
      allowedCount: 0,
      blockedCount: 0,
      anonymisedCount: 0,
      avgLatencyMs: 0,
      avgTtftMs: 0,
      avgAcceptanceRate: 0,
      byService: {},
      bySecurityClass: {},
      byRegion: {},
      gdprArticle32Events: 0,
      windowStart: now - 3_600_000,
      windowEnd: now,
    };
  }

  let latencySum = 0;
  let ttftSum = 0;
  let acceptanceSum = 0;
  let allowedCount = 0;
  let blockedCount = 0;
  let anonymisedCount = 0;
  let gdprArticle32Events = 0;
  const byService: Record<string, number> = {};
  const bySecurityClass: Record<string, number> = {};
  const byRegion: Record<string, number> = {};

  for (const decision of decisions) {
    latencySum += decision.latencyMs;
    ttftSum += decision.ttftMs;
    acceptanceSum += decision.acceptanceRate;
    if (decision.outcome === 'allowed') allowedCount += 1;
    if (decision.outcome === 'blocked') blockedCount += 1;
    if (decision.outcome === 'anonymised') anonymisedCount += 1;
    if (decision.outcome !== 'allowed' || decision.securityClass === 'confidential') gdprArticle32Events += 1;
    byService[decision.service] = (byService[decision.service] ?? 0) + 1;
    bySecurityClass[decision.securityClass] = (bySecurityClass[decision.securityClass] ?? 0) + 1;
    if (decision.region) byRegion[decision.region] = (byRegion[decision.region] ?? 0) + 1;
  }

  const timestamps = decisions.map(decision => decision.timestamp);
  const total = decisions.length;
  return {
    totalDecisions: total,
    allowedCount,
    blockedCount,
    anonymisedCount,
    avgLatencyMs: Math.round(latencySum / total),
    avgTtftMs: Math.round(ttftSum / total),
    avgAcceptanceRate: Math.round((acceptanceSum / total) * 1000) / 1000,
    byService,
    bySecurityClass,
    byRegion,
    gdprArticle32Events,
    windowStart: Math.min(...timestamps),
    windowEnd: Math.max(...timestamps),
  };
}

export class AuditPanel extends Panel {
  private decisions: AiDecision[] = [];
  private summary: GetAuditSummaryResponse | null = null;
  private loading = true;
  private error: string | null = null;
  private filter: Filter = 'all';
  private refreshInterval: ReturnType<typeof setInterval> | null = null;

  constructor() {
    super({ id: 'audit', title: 'AI Audit & Compliance', showCount: true });
    void this.refresh();
    this.refreshInterval = setInterval(() => this.refresh(), 30_000);
  }

  public destroy(): void {
    if (this.refreshInterval) { clearInterval(this.refreshInterval); this.refreshInterval = null; }
    super.destroy();
  }

  private async refresh(): Promise<void> {
    try {
      const decisionsResult = await fetchAiDecisions({ pageSize: 100 });
      if (!decisionsResult.success) throw new Error(decisionsResult.error);
      this.decisions = decisionsResult.decisions;
      this.summary = buildSummary(decisionsResult.decisions);
      this.error     = null;
    } catch (err) {
      this.error = err instanceof Error ? err.message : 'Fetch failed';
    } finally {
      this.loading = false;
      this.setCount(this.decisions.length);
      this.render();
    }
  }

  private get filtered(): AiDecision[] {
    if (this.filter === 'all') return this.decisions;
    return this.decisions.filter(d => d.outcome === this.filter);
  }

  protected renderContent(): DomChild[] {
    if (this.loading) return [h('p', { class: 'panel-empty' }, 'Loading…')];
    if (this.error)   return [h('p', { class: 'panel-empty' }, `Error: ${this.error}`)];

    const s = this.summary;
    const summaryBar = s ? h('div', { class: 'audit-summary' },
      h('span', { class: 'audit-stat' }, `${s.totalDecisions} decisions`),
      h('span', { class: 'audit-stat', style: `color:${OUTCOME_COLOUR.allowed}` },   `${s.allowedCount} allowed`),
      h('span', { class: 'audit-stat', style: `color:${OUTCOME_COLOUR.blocked}` },   `${s.blockedCount} blocked`),
      h('span', { class: 'audit-stat', style: `color:${OUTCOME_COLOUR.anonymised}` },`${s.anonymisedCount} anonymised`),
      h('span', { class: 'audit-stat' }, `avg ${fmt(s.avgLatencyMs)} E2E`),
      h('span', { class: 'audit-stat' }, `avg TTFT ${fmt(s.avgTtftMs)}`),
      h('span', { class: 'audit-stat' }, `GDPR Art 32 events: ${s.gdprArticle32Events}`),
    ) : null;

    const filterBar = h('div', { class: 'audit-filters' },
      ...(['all', 'allowed', 'blocked', 'anonymised'] as Filter[]).map(f =>
        h('button', {
          class: `audit-filter-btn${this.filter === f ? ' active' : ''}`,
          onclick: () => { this.filter = f; this.render(); },
        }, f),
      ),
    );

    const rows = this.filtered.map(d =>
      h('tr', { class: 'audit-row' },
        h('td', {}, new Date(d.timestamp).toISOString().slice(11, 19)),
        h('td', {}, h('span', { class: 'audit-svc-badge' }, d.service)),
        h('td', {}, d.operation),
        h('td', {}, d.model || '—'),
        h('td', {},
          h('span', { class: 'audit-sec-badge', style: `background:${SEC_BADGE[d.securityClass] ?? SEC_BADGE.unknown}` }, d.securityClass),
        ),
        h('td', {},
          h('span', { class: 'audit-outcome', style: `color:${OUTCOME_COLOUR[d.outcome]}` }, d.outcome),
        ),
        h('td', {}, fmt(d.latencyMs)),
        h('td', {}, d.acceptanceRate > 0 ? `${Math.round(d.acceptanceRate * 100)}%` : '—'),
        h('td', { class: 'audit-rules', title: d.mangleRulesEvaluated.join(', ') },
          d.mangleRulesEvaluated.length > 0 ? `${d.mangleRulesEvaluated.length} rules` : '—',
        ),
        h('td', {}, d.region || '—'),
      ),
    );

    const table = h('table', { class: 'audit-table' },
      h('thead', {},
        h('tr', {},
          ...['Time', 'Service', 'Operation', 'Model', 'Security', 'Outcome',
              'Latency', 'Accept%', 'Mangle', 'Region'].map(c => h('th', {}, c)),
        ),
      ),
      h('tbody', {}, ...rows),
    );

    return [summaryBar, filterBar, table].filter(Boolean) as DomChild[];
  }

  protected render(): void {
    replaceChildren(this.content, ...this.renderContent());
  }
}

