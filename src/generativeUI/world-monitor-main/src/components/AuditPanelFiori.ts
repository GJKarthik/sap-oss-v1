// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2024 SAP SE
/**
 * AuditPanelFiori - POC Migration to UI5 Web Components
 * 
 * This component demonstrates migrating World Monitor panels to SAP Fiori
 * UI5 Web Components while preserving WCAG AA accessibility.
 * 
 * UI5 Components Used:
 * - ui5-card: Panel container with built-in header
 * - ui5-segmented-button: Filter toolbar (replaces custom toggle buttons)
 * - ui5-table: Data grid with sorting/selection
 * - ui5-badge: Status indicators
 * - ui5-busy-indicator: Loading state
 * - ui5-message-strip: Error states
 * 
 * Accessibility Features Preserved:
 * - ARIA live regions for dynamic content
 * - Keyboard navigation via UI5 built-in support
 * - Screen reader announcements
 * - Color-independent indicators
 * - Focus management
 */

// Import UI5 Web Components (side-effect imports register custom elements)
import '@anthropic/ui5-webcomponents/dist/Card.js';
import '@anthropic/ui5-webcomponents/dist/CardHeader.js';
import '@anthropic/ui5-webcomponents/dist/Table.js';
import '@anthropic/ui5-webcomponents/dist/TableHeaderRow.js';
import '@anthropic/ui5-webcomponents/dist/TableHeaderCell.js';
import '@anthropic/ui5-webcomponents/dist/TableRow.js';
import '@anthropic/ui5-webcomponents/dist/TableCell.js';
import '@anthropic/ui5-webcomponents/dist/SegmentedButton.js';
import '@anthropic/ui5-webcomponents/dist/SegmentedButtonItem.js';
import '@anthropic/ui5-webcomponents/dist/Badge.js';
import '@anthropic/ui5-webcomponents/dist/BusyIndicator.js';
import '@anthropic/ui5-webcomponents/dist/MessageStrip.js';
import '@anthropic/ui5-webcomponents/dist/Label.js';

import { fetchAiDecisions } from '@/services/audit';
import type { AiDecision, GetAuditSummaryResponse } from '@/generated/server/worldmonitor/audit/v1/service_server';

type Filter = 'all' | 'allowed' | 'blocked' | 'anonymised';

// Design tokens mapping - would be replaced by UI5 theming in production
const OUTCOME_DESIGN: Record<AiDecision['outcome'], string> = {
  allowed: 'Positive',
  blocked: 'Negative', 
  anonymised: 'Critical',
};

const SEC_BADGE_DESIGN: Record<string, string> = {
  confidential: 'Set1',
  internal: 'Set2',
  public: 'Set3',
  unknown: 'Set4',
};

function fmt(ms: number): string {
  return ms < 1000 ? `${ms}ms` : `${(ms / 1000).toFixed(1)}s`;
}

function buildSummary(decisions: AiDecision[]): GetAuditSummaryResponse {
  const now = Date.now();
  if (decisions.length === 0) {
    return {
      totalDecisions: 0, allowedCount: 0, blockedCount: 0, anonymisedCount: 0,
      avgLatencyMs: 0, avgTtftMs: 0, avgAcceptanceRate: 0,
      byService: {}, bySecurityClass: {}, byRegion: {},
      gdprArticle32Events: 0, windowStart: now - 3_600_000, windowEnd: now,
    };
  }

  let latencySum = 0, ttftSum = 0, acceptanceSum = 0;
  let allowedCount = 0, blockedCount = 0, anonymisedCount = 0, gdprArticle32Events = 0;
  const byService: Record<string, number> = {};
  const bySecurityClass: Record<string, number> = {};
  const byRegion: Record<string, number> = {};

  for (const d of decisions) {
    latencySum += d.latencyMs;
    ttftSum += d.ttftMs;
    acceptanceSum += d.acceptanceRate;
    if (d.outcome === 'allowed') allowedCount++;
    if (d.outcome === 'blocked') blockedCount++;
    if (d.outcome === 'anonymised') anonymisedCount++;
    if (d.outcome !== 'allowed' || d.securityClass === 'confidential') gdprArticle32Events++;
    byService[d.service] = (byService[d.service] ?? 0) + 1;
    bySecurityClass[d.securityClass] = (bySecurityClass[d.securityClass] ?? 0) + 1;
    if (d.region) byRegion[d.region] = (byRegion[d.region] ?? 0) + 1;
  }

  const timestamps = decisions.map(d => d.timestamp);
  const total = decisions.length;
  return {
    totalDecisions: total, allowedCount, blockedCount, anonymisedCount,
    avgLatencyMs: Math.round(latencySum / total),
    avgTtftMs: Math.round(ttftSum / total),
    avgAcceptanceRate: Math.round((acceptanceSum / total) * 1000) / 1000,
    byService, bySecurityClass, byRegion, gdprArticle32Events,
    windowStart: Math.min(...timestamps), windowEnd: Math.max(...timestamps),
  };
}

/**
 * AuditPanelFiori - UI5 Web Components version of AuditPanel
 * 
 * This is a POC demonstrating migration from custom DOM to Fiori components.
 * Key differences from original:
 * 1. Uses ui5-card instead of custom Panel class
 * 2. Uses ui5-segmented-button for filters (built-in a11y)
 * 3. Uses ui5-table with native keyboard navigation
 * 4. Uses ui5-badge for status indicators
 * 5. Uses ui5-busy-indicator for loading states
 * 6. Uses ui5-message-strip for errors
 */
export class AuditPanelFiori {
  private element: HTMLElement;
  private decisions: AiDecision[] = [];
  private summary: GetAuditSummaryResponse | null = null;
  private loading = true;
  private error: string | null = null;
  private filter: Filter = 'all';
  private refreshInterval: ReturnType<typeof setInterval> | null = null;

  constructor() {
    this.element = document.createElement('div');
    this.element.className = 'audit-panel-fiori';
    this.element.setAttribute('role', 'region');
    this.element.setAttribute('aria-label', 'AI Audit & Compliance');
    
    void this.refresh();
    this.refreshInterval = setInterval(() => this.refresh(), 30_000);
    this.render();
  }

  public getElement(): HTMLElement {
    return this.element;
  }

  public destroy(): void {
    if (this.refreshInterval) {
      clearInterval(this.refreshInterval);
      this.refreshInterval = null;
    }
  }

  private async refresh(): Promise<void> {
    try {
      const result = await fetchAiDecisions({ pageSize: 100 });
      if (!result.success) throw new Error(result.error);
      this.decisions = result.decisions;
      this.summary = buildSummary(result.decisions);
      this.error = null;
    } catch (err) {
      this.error = err instanceof Error ? err.message : 'Fetch failed';
    } finally {
      this.loading = false;
      this.render();
    }
  }

  private get filtered(): AiDecision[] {
    if (this.filter === 'all') return this.decisions;
    return this.decisions.filter(d => d.outcome === this.filter);
  }

  private handleFilterChange(e: Event): void {
    const target = e.target as HTMLElement & { selectedItem?: HTMLElement };
    const selected = target.selectedItem?.getAttribute('data-filter') as Filter;
    if (selected) {
      this.filter = selected;
      this.render();
    }
  }

  private render(): void {
    this.element.innerHTML = '';

    // UI5 Card container
    const card = document.createElement('ui5-card');
    card.className = 'audit-card';

    // Card header
    const header = document.createElement('ui5-card-header');
    header.setAttribute('title-text', 'AI Audit & Compliance');
    header.setAttribute('subtitle-text', `${this.decisions.length} decisions`);
    header.setAttribute('slot', 'header');
    card.appendChild(header);

    // Loading state
    if (this.loading) {
      const busy = document.createElement('ui5-busy-indicator');
      busy.setAttribute('active', '');
      busy.setAttribute('size', 'M');
      busy.setAttribute('text', 'Loading audit data…');
      busy.setAttribute('aria-live', 'polite');
      card.appendChild(busy);
      this.element.appendChild(card);
      return;
    }

    // Error state
    if (this.error) {
      const msg = document.createElement('ui5-message-strip');
      msg.setAttribute('design', 'Negative');
      msg.setAttribute('hide-close-button', '');
      msg.textContent = `Error: ${this.error}`;
      msg.setAttribute('role', 'alert');
      msg.setAttribute('aria-live', 'assertive');
      card.appendChild(msg);
      this.element.appendChild(card);
      return;
    }

    // Summary badges
    const summaryDiv = document.createElement('div');
    summaryDiv.className = 'audit-summary-fiori';
    summaryDiv.setAttribute('role', 'region');
    summaryDiv.setAttribute('aria-label', 'Audit summary statistics');

    if (this.summary) {
      const stats = [
        { label: `${this.summary.totalDecisions} decisions`, design: '' },
        { label: `${this.summary.allowedCount} allowed`, design: 'Positive' },
        { label: `${this.summary.blockedCount} blocked`, design: 'Negative' },
        { label: `${this.summary.anonymisedCount} anonymised`, design: 'Critical' },
        { label: `avg ${fmt(this.summary.avgLatencyMs)} E2E`, design: '' },
        { label: `GDPR Art 32: ${this.summary.gdprArticle32Events}`, design: 'Set2' },
      ];
      for (const stat of stats) {
        const badge = document.createElement('ui5-badge');
        if (stat.design) badge.setAttribute('design', stat.design);
        badge.textContent = stat.label;
        summaryDiv.appendChild(badge);
      }
    }
    card.appendChild(summaryDiv);

    // Filter segmented button (replaces custom toggle buttons)
    // UI5 segmented-button has built-in ARIA and keyboard navigation
    const filterBar = document.createElement('div');
    filterBar.className = 'audit-filters-fiori';

    const segBtn = document.createElement('ui5-segmented-button');
    segBtn.setAttribute('accessible-name', 'Filter decisions by outcome');
    segBtn.addEventListener('selection-change', (e) => this.handleFilterChange(e));

    const filters: Filter[] = ['all', 'allowed', 'blocked', 'anonymised'];
    for (const f of filters) {
      const item = document.createElement('ui5-segmented-button-item');
      item.setAttribute('data-filter', f);
      item.textContent = f.charAt(0).toUpperCase() + f.slice(1);
      if (f === this.filter) item.setAttribute('pressed', '');
      segBtn.appendChild(item);
    }
    filterBar.appendChild(segBtn);
    card.appendChild(filterBar);

    // Status announcement (screen reader)
    const status = document.createElement('div');
    status.className = 'sr-only';
    status.setAttribute('role', 'status');
    status.setAttribute('aria-live', 'polite');
    status.textContent = `Showing ${this.filtered.length} of ${this.decisions.length} decisions`;
    card.appendChild(status);

    // UI5 Table with built-in accessibility
    const table = document.createElement('ui5-table');
    table.setAttribute('accessible-name', 'AI decision audit log');
    table.setAttribute('overflow-mode', 'Popin');
    table.className = 'audit-table-fiori';

    // Header row
    const headerRow = document.createElement('ui5-table-header-row');
    headerRow.setAttribute('slot', 'headerRow');
    const cols = ['Time', 'Service', 'Operation', 'Model', 'Security', 'Outcome', 'Latency', 'Accept%', 'Mangle', 'Region'];
    for (const col of cols) {
      const cell = document.createElement('ui5-table-header-cell');
      cell.textContent = col;
      headerRow.appendChild(cell);
    }
    table.appendChild(headerRow);

    // Data rows
    for (const d of this.filtered) {
      const row = document.createElement('ui5-table-row');

      // Time
      const timeCell = document.createElement('ui5-table-cell');
      timeCell.textContent = new Date(d.timestamp).toISOString().slice(11, 19);
      row.appendChild(timeCell);

      // Service (badge)
      const svcCell = document.createElement('ui5-table-cell');
      const svcBadge = document.createElement('ui5-badge');
      svcBadge.textContent = d.service;
      svcCell.appendChild(svcBadge);
      row.appendChild(svcCell);

      // Operation
      const opCell = document.createElement('ui5-table-cell');
      opCell.textContent = d.operation;
      row.appendChild(opCell);

      // Model
      const modelCell = document.createElement('ui5-table-cell');
      modelCell.textContent = d.model || '—';
      row.appendChild(modelCell);

      // Security (badge with design)
      const secCell = document.createElement('ui5-table-cell');
      const secBadge = document.createElement('ui5-badge');
      secBadge.setAttribute('design', SEC_BADGE_DESIGN[d.securityClass] ?? 'Set4');
      secBadge.textContent = d.securityClass;
      secCell.appendChild(secBadge);
      row.appendChild(secCell);

      // Outcome (badge with semantic design)
      const outcomeCell = document.createElement('ui5-table-cell');
      const outcomeBadge = document.createElement('ui5-badge');
      outcomeBadge.setAttribute('design', OUTCOME_DESIGN[d.outcome]);
      outcomeBadge.textContent = d.outcome;
      // Add text decoration for color-blind accessibility
      if (d.outcome === 'blocked') {
        outcomeBadge.style.textDecoration = 'underline wavy';
      } else if (d.outcome === 'anonymised') {
        outcomeBadge.style.textDecoration = 'underline dotted';
      }
      outcomeCell.appendChild(outcomeBadge);
      row.appendChild(outcomeCell);

      // Latency
      const latCell = document.createElement('ui5-table-cell');
      latCell.textContent = fmt(d.latencyMs);
      row.appendChild(latCell);

      // Acceptance rate
      const accCell = document.createElement('ui5-table-cell');
      accCell.textContent = d.acceptanceRate > 0 ? `${Math.round(d.acceptanceRate * 100)}%` : '—';
      row.appendChild(accCell);

      // Mangle rules
      const mangleCell = document.createElement('ui5-table-cell');
      mangleCell.textContent = d.mangleRulesEvaluated.length > 0
        ? `${d.mangleRulesEvaluated.length} rules`
        : '—';
      if (d.mangleRulesEvaluated.length > 0) {
        mangleCell.setAttribute('title', d.mangleRulesEvaluated.join(', '));
      }
      row.appendChild(mangleCell);

      // Region
      const regionCell = document.createElement('ui5-table-cell');
      regionCell.textContent = d.region || '—';
      row.appendChild(regionCell);

      table.appendChild(row);
    }

    card.appendChild(table);
    this.element.appendChild(card);
  }
}

