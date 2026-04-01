import { Component, OnInit, OnDestroy, CUSTOM_ELEMENTS_SCHEMA, ChangeDetectionStrategy, inject, signal, computed } from '@angular/core';
import { CommonModule } from '@angular/common';
import { FormsModule } from '@angular/forms';
import { Subject, takeUntil, catchError, of } from 'rxjs';
import { ApiService } from '../../services/api.service';
import { ToastService } from '../../services/toast.service';
import { HttpErrorResponse } from '@angular/common/http';

interface GraphStats {
  available: boolean;
  pair_count: number;
}

interface QueryResult {
  status: string;
  rows: Record<string, unknown>[];
  count: number;
}

interface QueryPreset {
  label: string;
  description: string;
  cypher: string;
}

interface ArchLayer {
  icon: string;
  name: string;
  desc: string;
}

interface HistoryItem {
  cypher: string;
  timestamp: Date;
  status: string;
  rowCount: number;
}

@Component({
  selector: 'app-hippocpp',
  standalone: true,
  imports: [CommonModule, FormsModule],
  schemas: [CUSTOM_ELEMENTS_SCHEMA],
  changeDetection: ChangeDetectionStrategy.OnPush,
  template: `
    <div class="page-content">
      <!-- Header with connection status -->
      <div class="page-header">
        <div class="header-left">
          <h1 class="page-title">HippoCPP Graph Engine</h1>
          <div class="connection-status" [class.connected]="stats()?.available" [class.disconnected]="!stats()?.available">
            <span class="status-dot"></span>
            <span class="status-text">{{ stats()?.available ? 'Connected' : 'Disconnected' }}</span>
            <span class="db-info">KuzuDB v0.8 · Zig 0.15.1</span>
          </div>
        </div>
        <button class="btn-refresh" (click)="loadStats()">↻ Refresh</button>
      </div>

      <!-- About -->
      <div class="about-card">
        <p>
          <strong>HippoCPP</strong> is a multi-language port of the
          <a href="https://kuzudb.com/" target="_blank" rel="noopener">Kuzu</a> embedded graph database,
          implemented in <strong>Zig</strong> (1,251 source files) with GPU acceleration via
          <strong>Mojo</strong> and declarative invariants in <strong>Mangle</strong>.
        </p>
        <div class="tech-pills">
          <span class="pill pill--zig">Zig 0.15.1</span>
          <span class="pill pill--mojo">Mojo GPU</span>
          <span class="pill pill--mangle">Mangle Datalog</span>
          <span class="pill pill--python">Python bindings</span>
        </div>
      </div>

      <!-- Graph Stats Cards -->
      <div class="stats-grid">
        <div class="stat-card stat-animate" style="--delay: 0">
          <div class="stat-icon">🔵</div>
          <div class="stat-value">{{ animatedNodes() }}</div>
          <div class="stat-label">Nodes</div>
        </div>
        <div class="stat-card stat-animate" style="--delay: 1">
          <div class="stat-icon">🔗</div>
          <div class="stat-value">{{ animatedEdges() }}</div>
          <div class="stat-label">Edges</div>
        </div>
        <div class="stat-card stat-animate" style="--delay: 2">
          <div class="stat-icon">📊</div>
          <div class="stat-value">{{ stats()?.pair_count ?? '—' }}</div>
          <div class="stat-label">Training Pairs</div>
        </div>
        <div class="stat-card stat-animate" style="--delay: 3">
          <div class="stat-icon">🏷️</div>
          <div class="stat-value">{{ animatedLabels() }}</div>
          <div class="stat-label">Labels</div>
        </div>
      </div>

      <!-- Cypher Query Sandbox -->
      <section class="section">
        <h2 class="section-title">Cypher Query Sandbox</h2>

        <!-- Preset Cards -->
        <div class="preset-grid">
          @for (p of presets; track p.label) {
            <div class="preset-card" [class.active]="cypher === p.cypher" (click)="setQuery(p.cypher)">
              <div class="preset-title">{{ p.label }}</div>
              <div class="preset-desc">{{ p.description }}</div>
              <code class="preset-code">{{ p.cypher }}</code>
            </div>
          }
        </div>

        <!-- Code Editor -->
        <div class="editor-wrapper">
          <div class="editor-gutter" aria-hidden="true">
            @for (line of editorLines(); track $index) {
              <span class="line-number">{{ $index + 1 }}</span>
            }
          </div>
          <div class="editor-container">
            <div class="editor-highlight" aria-hidden="true" [innerHTML]="highlightedCypher()"></div>
            <textarea
              class="query-editor"
              [(ngModel)]="cypher"
              name="cypher"
              rows="5"
              placeholder="MATCH (n) RETURN n LIMIT 10"
              spellcheck="false"
            ></textarea>
          </div>
        </div>
        <div class="query-actions">
          <button class="btn-run" (click)="runQuery()" [disabled]="!cypher.trim() || querying()">
            @if (querying()) {
              <span class="spinner"></span> Running…
            } @else {
              ▶ Run Query
            }
          </button>
          <button class="btn-secondary" (click)="clearResults()">Clear</button>
        </div>

        <!-- Loading skeleton -->
        @if (querying()) {
          <div class="skeleton-table">
            <div class="skeleton-header">
              <div class="skeleton-cell"></div>
              <div class="skeleton-cell"></div>
              <div class="skeleton-cell"></div>
            </div>
            @for (i of [1,2,3,4]; track i) {
              <div class="skeleton-row">
                <div class="skeleton-cell"></div>
                <div class="skeleton-cell"></div>
                <div class="skeleton-cell"></div>
              </div>
            }
          </div>
        }

        <!-- Results -->
        @if (result(); as res) {
          <div class="results-section">
            <div class="result-header">
              <span class="result-badge" [class.success]="res.status === 'ok'" [class.error]="res.status !== 'ok'">
                {{ res.status === 'ok' ? '✓ Success' : '✗ Error' }}
              </span>
              <span class="row-count">{{ res.count }} row(s) returned</span>
            </div>
            @if (res.rows.length) {
              <div class="table-wrapper">
                <table class="data-table">
                  <thead>
                    <tr>
                      @for (col of resultColumns(); track col) {
                        <th (click)="toggleSort(col)" class="sortable-th">
                          <span>{{ col }}</span>
                          @if (sortColumn() === col) {
                            <span class="sort-indicator">{{ sortDirection() === 'asc' ? '▲' : '▼' }}</span>
                          }
                        </th>
                      }
                    </tr>
                  </thead>
                  <tbody>
                    @for (row of sortedRows(); track $index) {
                      <tr>
                        @for (col of resultColumns(); track col) {
                          <td [class]="getCellClass(row[col])">{{ formatCell(row[col]) }}</td>
                        }
                      </tr>
                    }
                  </tbody>
                </table>
              </div>
            } @else {
              <p class="empty-results">No rows returned.</p>
            }
          </div>
        }

        <!-- Error State -->
        @if (queryError()) {
          <div class="error-alert">
            <div class="error-alert-header">
              <span class="error-icon">⚠</span>
              <span class="error-title">Query Error</span>
            </div>
            <code class="error-detail">{{ queryError() }}</code>
            <button class="btn-retry" (click)="runQuery()">↻ Try Again</button>
          </div>
        }
      </section>

      <!-- Query History -->
      @if (queryHistory().length) {
        <section class="section">
          <div class="history-header" (click)="historyOpen.set(!historyOpen())">
            <h2 class="section-title" style="margin:0">
              {{ historyOpen() ? '▾' : '▸' }} Query History
              <span class="history-count">{{ queryHistory().length }}</span>
            </h2>
          </div>
          @if (historyOpen()) {
            <div class="history-list">
              @for (h of queryHistory(); track h.timestamp) {
                <div class="history-item" (click)="setQuery(h.cypher)">
                  <div class="history-meta">
                    <span class="history-status" [class.success]="h.status === 'ok'" [class.error]="h.status !== 'ok'">●</span>
                    <span class="history-time">{{ formatTime(h.timestamp) }}</span>
                    <span class="history-rows">{{ h.rowCount }} rows</span>
                  </div>
                  <code class="history-cypher">{{ h.cypher }}</code>
                </div>
              }
            </div>
          }
        </section>
      }

      <!-- Architecture -->
      <section class="section">
        <h2 class="section-title">Architecture</h2>
        <div class="arch-grid">
          @for (layer of archLayers; track layer.name) {
            <div class="arch-card">
              <div class="arch-icon">{{ layer.icon }}</div>
              <div class="arch-name">{{ layer.name }}</div>
              <div class="arch-desc">{{ layer.desc }}</div>
            </div>
          }
        </div>
      </section>
    </div>
  `,
  styles: [`
    /* ── Connection Status ── */
    .header-left { display: flex; flex-direction: column; gap: 0.25rem; }

    .connection-status {
      display: flex; align-items: center; gap: 0.5rem;
      font-size: 0.75rem; color: var(--sapContent_LabelColor, #6a6d70);
    }
    .status-dot {
      width: 8px; height: 8px; border-radius: 50%; display: inline-block;
    }
    .connected .status-dot {
      background: #2e7d32;
      box-shadow: 0 0 0 0 rgba(46,125,50,0.4);
      animation: pulse-green 2s infinite;
    }
    .disconnected .status-dot {
      background: #c62828;
      box-shadow: 0 0 0 0 rgba(198,40,40,0.4);
      animation: pulse-red 2s infinite;
    }
    .connected .status-text { color: #2e7d32; font-weight: 600; }
    .disconnected .status-text { color: #c62828; font-weight: 600; }
    .db-info { color: var(--sapContent_LabelColor, #6a6d70); font-size: 0.7rem; }

    @keyframes pulse-green {
      0% { box-shadow: 0 0 0 0 rgba(46,125,50,0.5); }
      70% { box-shadow: 0 0 0 6px rgba(46,125,50,0); }
      100% { box-shadow: 0 0 0 0 rgba(46,125,50,0); }
    }
    @keyframes pulse-red {
      0% { box-shadow: 0 0 0 0 rgba(198,40,40,0.5); }
      70% { box-shadow: 0 0 0 6px rgba(198,40,40,0); }
      100% { box-shadow: 0 0 0 0 rgba(198,40,40,0); }
    }

    /* ── About Card ── */
    .about-card {
      background: var(--sapTile_Background, #fff);
      border: 1px solid var(--sapTile_BorderColor, #e4e4e4);
      border-radius: 0.5rem; padding: 1.25rem; margin-bottom: 1.5rem;
      font-size: 0.875rem; color: var(--sapTextColor, #32363a);
      p { margin: 0 0 0.75rem; }
      a { color: var(--sapBrandColor, #0854a0); }
    }
    .tech-pills { display: flex; flex-wrap: wrap; gap: 0.5rem; }
    .pill {
      padding: 0.2rem 0.6rem; border-radius: 1rem; font-size: 0.75rem; font-weight: 500;
      &.pill--zig    { background: #fff3e0; color: #e65100; }
      &.pill--mojo   { background: #fce4ec; color: #880e4f; }
      &.pill--mangle { background: #e8f5e9; color: #1b5e20; }
      &.pill--python { background: #e3f2fd; color: #0d47a1; }
    }

    .btn-refresh {
      padding: 0.375rem 0.875rem; background: var(--sapBrandColor, #0854a0);
      color: #fff; border: none; border-radius: 0.375rem; cursor: pointer; font-size: 0.875rem;
      &:hover { background: var(--sapButton_Hover_Background, #0a6ed1); }
    }

    /* ── Stats Cards ── */
    .stats-grid {
      display: grid; grid-template-columns: repeat(auto-fill, minmax(160px, 1fr));
      gap: 0.75rem; margin-bottom: 1.5rem;
    }
    .stat-card {
      background: var(--sapTile_Background, #fff);
      border: 1px solid var(--sapTile_BorderColor, #e4e4e4);
      border-radius: 0.5rem; padding: 1.25rem; text-align: center;
      transition: transform 0.2s, box-shadow 0.2s;
      &:hover { transform: translateY(-2px); box-shadow: 0 4px 12px rgba(0,0,0,0.08); }
    }
    .stat-animate {
      animation: fadeSlideUp 0.5s ease-out both;
      animation-delay: calc(var(--delay, 0) * 0.1s);
    }
    @keyframes fadeSlideUp {
      from { opacity: 0; transform: translateY(12px); }
      to { opacity: 1; transform: translateY(0); }
    }
    .stat-icon { font-size: 1.5rem; margin-bottom: 0.25rem; }
    .stat-value { font-size: 1.75rem; font-weight: 700; color: var(--sapTextColor, #32363a); }
    .stat-label { font-size: 0.75rem; color: var(--sapContent_LabelColor, #6a6d70); margin-top: 0.25rem; }

    /* ── Section ── */
    .section { margin-bottom: 2rem; }
    .section-title {
      font-size: 1rem; font-weight: 600; margin: 0 0 0.75rem;
      color: var(--sapTextColor, #32363a);
    }

    /* ── Preset Cards ── */
    .preset-grid {
      display: grid; grid-template-columns: repeat(auto-fill, minmax(200px, 1fr));
      gap: 0.75rem; margin-bottom: 1rem;
    }
    .preset-card {
      background: var(--sapTile_Background, #fff);
      border: 1px solid var(--sapTile_BorderColor, #e4e4e4);
      border-radius: 0.5rem; padding: 0.875rem; cursor: pointer;
      transition: transform 0.15s, box-shadow 0.15s, border-color 0.15s;
      &:hover { transform: translateY(-2px); box-shadow: 0 4px 12px rgba(0,0,0,0.08); }
      &.active { border-color: var(--sapBrandColor, #0854a0); border-width: 2px; }
    }
    .preset-title { font-weight: 600; font-size: 0.8125rem; color: var(--sapTextColor, #32363a); margin-bottom: 0.25rem; }
    .preset-desc { font-size: 0.7rem; color: var(--sapContent_LabelColor, #6a6d70); margin-bottom: 0.5rem; }
    .preset-code {
      display: block; font-size: 0.7rem; font-family: 'SF Mono', 'SFMono-Regular', Menlo, Consolas, monospace;
      color: var(--sapBrandColor, #0854a0); background: var(--sapBackgroundColor, #f5f5f5);
      padding: 0.25rem 0.375rem; border-radius: 0.25rem; overflow: hidden;
      text-overflow: ellipsis; white-space: nowrap;
    }

    /* ── Code Editor ── */
    .editor-wrapper {
      display: flex; border: 1px solid var(--sapTile_BorderColor, #e4e4e4);
      border-radius: 0.5rem; overflow: hidden; margin-bottom: 0.75rem;
      background: #1e1e1e;
    }
    .editor-gutter {
      display: flex; flex-direction: column; padding: 0.75rem 0;
      background: #252526; border-right: 1px solid #3c3c3c;
      min-width: 2.5rem; text-align: right; user-select: none;
    }
    .line-number {
      font-family: 'SF Mono', 'SFMono-Regular', Menlo, Consolas, monospace;
      font-size: 0.75rem; line-height: 1.5rem; padding: 0 0.5rem;
      color: #858585;
    }
    .editor-container { position: relative; flex: 1; }
    .editor-highlight, .query-editor {
      font-family: 'SF Mono', 'SFMono-Regular', Menlo, Consolas, monospace;
      font-size: 0.8125rem; line-height: 1.5rem; padding: 0.75rem;
      white-space: pre-wrap; word-wrap: break-word;
    }
    .editor-highlight {
      position: absolute; inset: 0; pointer-events: none;
      color: #d4d4d4; z-index: 1;
    }
    .query-editor {
      width: 100%; height: 100%; min-height: 7.5rem; box-sizing: border-box;
      background: transparent; color: transparent; caret-color: #d4d4d4;
      border: none; outline: none; resize: vertical;
      position: relative; z-index: 2;
    }

    /* ── Query Actions ── */
    .query-actions { display: flex; gap: 0.5rem; align-items: center; margin-bottom: 1rem; }
    .btn-run {
      display: inline-flex; align-items: center; gap: 0.375rem;
      padding: 0.5rem 1.25rem; background: var(--sapBrandColor, #0854a0);
      color: #fff; border: none; border-radius: 0.375rem; cursor: pointer;
      font-size: 0.875rem; font-weight: 600;
      transition: background 0.15s;
      &:disabled { opacity: 0.5; cursor: default; }
      &:hover:not(:disabled) { background: var(--sapButton_Hover_Background, #0a6ed1); }
    }
    .btn-secondary {
      padding: 0.5rem 1rem; background: transparent;
      color: var(--sapTextColor, #32363a);
      border: 1px solid var(--sapTile_BorderColor, #e4e4e4);
      border-radius: 0.375rem; cursor: pointer; font-size: 0.875rem;
      &:hover { background: var(--sapBackgroundColor, #f5f5f5); }
    }

    /* ── Spinner ── */
    .spinner {
      display: inline-block; width: 14px; height: 14px;
      border: 2px solid rgba(255,255,255,0.3); border-top-color: #fff;
      border-radius: 50%; animation: spin 0.6s linear infinite;
    }
    @keyframes spin { to { transform: rotate(360deg); } }

    /* ── Skeleton Loading ── */
    .skeleton-table {
      margin-top: 1rem; border-radius: 0.5rem; overflow: hidden;
      border: 1px solid var(--sapTile_BorderColor, #e4e4e4);
    }
    .skeleton-header, .skeleton-row {
      display: grid; grid-template-columns: 1fr 1fr 1fr; gap: 0.75rem;
      padding: 0.75rem;
    }
    .skeleton-header { background: var(--sapBackgroundColor, #f5f5f5); }
    .skeleton-row { border-top: 1px solid var(--sapTile_BorderColor, #e4e4e4); }
    .skeleton-cell {
      height: 1rem; border-radius: 0.25rem;
      background: linear-gradient(90deg, var(--sapTile_BorderColor, #e4e4e4) 25%, var(--sapBackgroundColor, #f5f5f5) 50%, var(--sapTile_BorderColor, #e4e4e4) 75%);
      background-size: 200% 100%; animation: shimmer 1.5s infinite;
    }
    @keyframes shimmer { from { background-position: 200% 0; } to { background-position: -200% 0; } }

    /* ── Results Table ── */
    .results-section { margin-top: 1rem; }
    .result-header { display: flex; align-items: center; gap: 0.75rem; margin-bottom: 0.5rem; }
    .result-badge {
      padding: 0.2rem 0.6rem; border-radius: 1rem; font-size: 0.75rem; font-weight: 600;
      &.success { background: #e8f5e9; color: #2e7d32; }
      &.error { background: #ffebee; color: #c62828; }
    }
    .row-count { font-size: 0.8125rem; color: var(--sapContent_LabelColor, #6a6d70); }
    .table-wrapper {
      overflow-x: auto; border: 1px solid var(--sapTile_BorderColor, #e4e4e4);
      border-radius: 0.5rem;
    }
    .data-table {
      width: 100%; border-collapse: collapse; font-size: 0.8125rem;
      background: var(--sapTile_Background, #fff);
      th {
        padding: 0.625rem 0.75rem; background: var(--sapBackgroundColor, #f5f5f5);
        text-align: left; font-weight: 600; font-size: 0.7rem;
        text-transform: uppercase; letter-spacing: 0.04em;
        color: var(--sapContent_LabelColor, #6a6d70);
        border-bottom: 2px solid var(--sapTile_BorderColor, #e4e4e4);
        position: sticky; top: 0; z-index: 1;
      }
      td {
        padding: 0.5rem 0.75rem;
        border-bottom: 1px solid var(--sapTile_BorderColor, #e4e4e4);
        font-family: 'SF Mono', 'SFMono-Regular', Menlo, Consolas, monospace;
        font-size: 0.75rem;
      }
      tr:last-child td { border-bottom: none; }
      tbody tr:nth-child(even) { background: var(--sapBackgroundColor, #f5f5f5); }
      tbody tr:hover { background: #e3f2fd; }
    }
    .sortable-th { cursor: pointer; user-select: none; &:hover { color: var(--sapBrandColor, #0854a0); } }
    .sort-indicator { margin-left: 0.25rem; font-size: 0.6rem; }
    .cell-number { text-align: right; }
    .cell-string { text-align: left; }
    .empty-results { color: var(--sapContent_LabelColor, #6a6d70); font-size: 0.8125rem; text-align: center; padding: 2rem; }

    /* ── Error Alert ── */
    .error-alert {
      margin-top: 1rem; padding: 1rem 1.25rem; background: #ffebee;
      border: 1px solid #ef9a9a; border-radius: 0.5rem;
      border-left: 4px solid #c62828;
    }
    .error-alert-header { display: flex; align-items: center; gap: 0.5rem; margin-bottom: 0.5rem; }
    .error-icon { font-size: 1.125rem; }
    .error-title { font-weight: 600; color: #c62828; font-size: 0.875rem; }
    .error-detail {
      display: block; padding: 0.5rem 0.75rem; background: #fff;
      border: 1px solid #ef9a9a; border-radius: 0.25rem;
      font-family: 'SF Mono', 'SFMono-Regular', Menlo, Consolas, monospace;
      font-size: 0.75rem; color: #c62828; margin-bottom: 0.75rem;
      white-space: pre-wrap; word-break: break-word;
    }
    .btn-retry {
      padding: 0.375rem 0.875rem; background: #c62828; color: #fff;
      border: none; border-radius: 0.375rem; cursor: pointer; font-size: 0.8125rem;
      &:hover { background: #b71c1c; }
    }

    /* ── Query History ── */
    .history-header { cursor: pointer; margin-bottom: 0.5rem; }
    .history-count {
      display: inline-flex; align-items: center; justify-content: center;
      min-width: 1.25rem; height: 1.25rem; border-radius: 50%;
      background: var(--sapBrandColor, #0854a0); color: #fff;
      font-size: 0.65rem; font-weight: 600; margin-left: 0.5rem;
    }
    .history-list { display: flex; flex-direction: column; gap: 0.375rem; }
    .history-item {
      background: var(--sapTile_Background, #fff);
      border: 1px solid var(--sapTile_BorderColor, #e4e4e4);
      border-radius: 0.375rem; padding: 0.625rem 0.75rem; cursor: pointer;
      transition: border-color 0.15s;
      &:hover { border-color: var(--sapBrandColor, #0854a0); }
    }
    .history-meta { display: flex; align-items: center; gap: 0.5rem; margin-bottom: 0.25rem; }
    .history-status { font-size: 0.6rem; &.success { color: #2e7d32; } &.error { color: #c62828; } }
    .history-time { font-size: 0.7rem; color: var(--sapContent_LabelColor, #6a6d70); }
    .history-rows { font-size: 0.7rem; color: var(--sapContent_LabelColor, #6a6d70); }
    .history-cypher {
      display: block; font-size: 0.7rem; font-family: 'SF Mono', 'SFMono-Regular', Menlo, Consolas, monospace;
      color: var(--sapTextColor, #32363a); overflow: hidden; text-overflow: ellipsis; white-space: nowrap;
    }

    /* ── Architecture ── */
    .arch-grid {
      display: grid; grid-template-columns: repeat(auto-fill, minmax(160px, 1fr));
      gap: 0.75rem;
    }
    .arch-card {
      background: var(--sapTile_Background, #fff);
      border: 1px solid var(--sapTile_BorderColor, #e4e4e4);
      border-radius: 0.5rem; padding: 1rem; text-align: center;
      transition: transform 0.15s, box-shadow 0.15s;
      &:hover { transform: translateY(-2px); box-shadow: 0 4px 12px rgba(0,0,0,0.08); }
    }
    .arch-icon { font-size: 1.75rem; margin-bottom: 0.5rem; }
    .arch-name { font-weight: 600; font-size: 0.875rem; margin-bottom: 0.25rem; color: var(--sapTextColor, #32363a); }
    .arch-desc { font-size: 0.75rem; color: var(--sapContent_LabelColor, #6a6d70); }
  `],
})
export class HippocppComponent implements OnInit, OnDestroy {
  private readonly api = inject(ApiService);
  private readonly toast = inject(ToastService);
  private readonly destroy$ = new Subject<void>();

  readonly stats = signal<GraphStats | null>(null);
  readonly result = signal<QueryResult | null>(null);
  readonly querying = signal(false);
  readonly queryError = signal('');
  readonly sortColumn = signal('');
  readonly sortDirection = signal<'asc' | 'desc'>('asc');
  readonly queryHistory = signal<HistoryItem[]>([]);
  readonly historyOpen = signal(false);
  readonly animatedNodes = signal('—');
  readonly animatedEdges = signal('—');
  readonly animatedLabels = signal('—');

  cypher = 'MATCH (n) RETURN n LIMIT 10';

  readonly presets: QueryPreset[] = [
    { label: 'All Nodes', description: 'Return first 10 nodes from the graph', cypher: 'MATCH (n) RETURN n LIMIT 10' },
    { label: 'Training Pairs', description: 'Browse indexed training pairs', cypher: 'MATCH (p:TrainingPair) RETURN p LIMIT 20' },
    { label: 'Count Pairs', description: 'Get total count of training pairs', cypher: 'MATCH (p:TrainingPair) RETURN count(p) AS total' },
    { label: 'Relationships', description: 'Explore edges between nodes', cypher: 'MATCH (a)-[r]->(b) RETURN a, type(r), b LIMIT 15' },
    { label: 'Labels', description: 'List all distinct node labels', cypher: 'MATCH (n) RETURN DISTINCT labels(n) AS label, count(n) AS count' },
  ];

  readonly archLayers: ArchLayer[] = [
    { icon: '⚡', name: 'Parser', desc: 'Cypher query parser (Zig)' },
    { icon: '📐', name: 'Planner', desc: 'Query plan generation' },
    { icon: '🔧', name: 'Optimizer', desc: 'Cost-based optimiser' },
    { icon: '⚙', name: 'Processor', desc: 'Execution engine' },
    { icon: '💾', name: 'Storage', desc: 'WAL + MVCC buffer mgr' },
    { icon: '🗂', name: 'Catalog', desc: 'Schema & type catalog' },
    { icon: '🚀', name: 'Mojo GPU', desc: 'SIMD page acceleration' },
    { icon: '📜', name: 'Mangle', desc: 'Datalog invariants' },
  ];

  readonly resultColumns = computed(() => {
    const res = this.result();
    if (!res?.rows?.length) return [];
    return Object.keys(res.rows[0]);
  });

  readonly editorLines = computed(() => {
    const lines = this.cypher.split('\n');
    return lines.length < 5 ? [...lines, ...Array(5 - lines.length).fill('')] : lines;
  });

  readonly highlightedCypher = computed(() => this.highlightSyntax(this.cypher));

  readonly sortedRows = computed(() => {
    const res = this.result();
    if (!res?.rows?.length) return [];
    const col = this.sortColumn();
    const dir = this.sortDirection();
    if (!col) return res.rows;
    return [...res.rows].sort((a, b) => {
      const va = a[col]; const vb = b[col];
      if (va === vb) return 0;
      if (va === null || va === undefined) return 1;
      if (vb === null || vb === undefined) return -1;
      const cmp = typeof va === 'number' && typeof vb === 'number'
        ? va - vb : String(va).localeCompare(String(vb));
      return dir === 'asc' ? cmp : -cmp;
    });
  });

  ngOnInit(): void {
    this.loadStats();
  }

  ngOnDestroy(): void {
    this.destroy$.next();
    this.destroy$.complete();
  }

  loadStats(): void {
    this.api.get<GraphStats>('/graph/stats')
      .pipe(
        takeUntil(this.destroy$),
        catchError((err: HttpErrorResponse) => {
          this.toast.warning('Graph stats unavailable', 'Graph');
          console.warn('Graph stats failed:', err);
          return of(null);
        })
      )
      .subscribe({
        next: (s: GraphStats | null) => {
          this.stats.set(s);
          if (s) this.animateCounters(s);
        },
      });
  }

  setQuery(q: string): void {
    this.cypher = q;
  }

  runQuery(): void {
    if (!this.cypher.trim()) return;
    this.querying.set(true);
    this.queryError.set('');
    this.result.set(null);
    this.sortColumn.set('');

    const queryCypher = this.cypher;
    this.api.post<QueryResult>('/graph/query', { cypher: queryCypher })
      .pipe(takeUntil(this.destroy$))
      .subscribe({
        next: (r: QueryResult) => {
          this.result.set(r);
          this.querying.set(false);
          this.addToHistory(queryCypher, r.status, r.count);
          if (r.status === 'ok') {
            this.toast.success(`Query returned ${r.count} row(s)`, 'Query Complete');
          }
        },
        error: (e: HttpErrorResponse) => {
          const detail = (e.error as { detail?: string })?.detail ?? 'Query failed';
          this.queryError.set(detail);
          this.addToHistory(queryCypher, 'error', 0);
          this.toast.error(detail, 'Query Error');
          console.error('Query failed:', e);
          this.querying.set(false);
        },
      });
  }

  clearResults(): void {
    this.result.set(null);
    this.queryError.set('');
    this.sortColumn.set('');
  }

  toggleSort(col: string): void {
    if (this.sortColumn() === col) {
      this.sortDirection.set(this.sortDirection() === 'asc' ? 'desc' : 'asc');
    } else {
      this.sortColumn.set(col);
      this.sortDirection.set('asc');
    }
  }

  formatCell(val: unknown): string {
    if (val === null || val === undefined) return '—';
    if (typeof val === 'object') return JSON.stringify(val);
    return String(val);
  }

  getCellClass(val: unknown): string {
    if (typeof val === 'number') return 'cell-number';
    return 'cell-string';
  }

  formatTime(d: Date): string {
    return d.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', second: '2-digit' });
  }

  private addToHistory(cypher: string, status: string, rowCount: number): void {
    const history = [{ cypher, timestamp: new Date(), status, rowCount }, ...this.queryHistory()];
    this.queryHistory.set(history.slice(0, 5));
  }

  private animateCounters(s: GraphStats): void {
    const nodeTarget = s.pair_count * 2;
    const edgeTarget = s.pair_count;
    const labelTarget = 4;
    this.countUp(nodeTarget, (v) => this.animatedNodes.set(v.toLocaleString()));
    this.countUp(edgeTarget, (v) => this.animatedEdges.set(v.toLocaleString()));
    this.countUp(labelTarget, (v) => this.animatedLabels.set(v.toLocaleString()));
  }

  private countUp(target: number, setter: (v: number) => void): void {
    const duration = 800;
    const steps = 30;
    const increment = target / steps;
    let current = 0;
    let step = 0;
    const interval = setInterval(() => {
      step++;
      current = Math.min(Math.round(increment * step), target);
      setter(current);
      if (step >= steps) clearInterval(interval);
    }, duration / steps);
  }

  private highlightSyntax(code: string): string {
    return code
      .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
      .replace(/\/\/.*/g, '<span style="color:#6a9955">$&</span>')
      .replace(/\b(MATCH|RETURN|WHERE|CREATE|DELETE|SET|MERGE|WITH|ORDER BY|LIMIT|SKIP|DISTINCT|AS|AND|OR|NOT|IN|IS|NULL|TRUE|FALSE|count|labels|type|UNWIND)\b/gi,
        '<span style="color:#569cd6">$&</span>')
      .replace(/'[^']*'|"[^"]*"/g, '<span style="color:#ce9178">$&</span>')
      .replace(/\b(\d+)\b/g, '<span style="color:#b5cea8">$&</span>');
  }
}