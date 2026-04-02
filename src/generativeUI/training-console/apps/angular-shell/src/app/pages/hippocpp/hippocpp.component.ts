import { Component, OnInit, OnDestroy, CUSTOM_ELEMENTS_SCHEMA, ChangeDetectionStrategy, inject, signal, computed } from '@angular/core';
import { CommonModule } from '@angular/common';
import { FormsModule } from '@angular/forms';
import { Ui5WebcomponentsModule } from '@ui5/webcomponents-ngx';
import '@ui5/webcomponents-icons/dist/AllIcons.js';
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
  imports: [CommonModule, FormsModule, Ui5WebcomponentsModule],
  schemas: [CUSTOM_ELEMENTS_SCHEMA],
  changeDetection: ChangeDetectionStrategy.OnPush,
  template: `
    <ui5-page background-design="Solid">
      <ui5-bar slot="header" design="Header">
        <ui5-title slot="startContent" level="H3">HippoCPP Graph Engine</ui5-title>
        <div slot="startContent" style="margin-left: 1rem;">
          <ui5-tag [design]="stats()?.available ? 'Positive' : 'Negative'">
            {{ stats()?.available ? 'Connected' : 'Disconnected' }}
          </ui5-tag>
          <span class="db-info">KuzuDB v0.8 · Zig 0.15.1</span>
        </div>
        <ui5-button slot="endContent" icon="refresh" design="Transparent" (click)="loadStats()">
          Refresh
        </ui5-button>
      </ui5-bar>

      <div style="padding: 1.5rem; display: flex; flex-direction: column; gap: 1.5rem;">

        <!-- About -->
        <ui5-card>
          <ui5-card-header slot="header" title-text="About HippoCPP"
            subtitle-text="Multi-language Kuzu graph database port"></ui5-card-header>
          <div style="padding: 1rem;">
            <p style="margin: 0 0 0.75rem; font-size: 0.875rem;">
              <strong>HippoCPP</strong> is a multi-language port of the
              <a href="https://kuzudb.com/" target="_blank" rel="noopener">Kuzu</a> embedded graph database,
              implemented in <strong>Zig</strong> (1,251 source files) with GPU acceleration via
              <strong>Mojo</strong> and declarative invariants in <strong>Mangle</strong>.
            </p>
            <div class="tech-pills">
              <ui5-tag design="Set2">Zig 0.15.1</ui5-tag>
              <ui5-tag design="Set2">Mojo GPU</ui5-tag>
              <ui5-tag design="Set2">Mangle Datalog</ui5-tag>
              <ui5-tag design="Set2">Python bindings</ui5-tag>
            </div>
          </div>
        </ui5-card>

        <!-- Graph Stats Cards -->
        <div class="stats-grid">
          <ui5-card>
            <ui5-card-header slot="header" title-text="Nodes"></ui5-card-header>
            <div style="padding: 1rem; text-align: center;">
              <ui5-title level="H1">{{ animatedNodes() }}</ui5-title>
            </div>
          </ui5-card>
          <ui5-card>
            <ui5-card-header slot="header" title-text="Edges"></ui5-card-header>
            <div style="padding: 1rem; text-align: center;">
              <ui5-title level="H1">{{ animatedEdges() }}</ui5-title>
            </div>
          </ui5-card>
          <ui5-card>
            <ui5-card-header slot="header" title-text="Training Pairs"></ui5-card-header>
            <div style="padding: 1rem; text-align: center;">
              <ui5-title level="H1">{{ stats()?.pair_count ?? '—' }}</ui5-title>
            </div>
          </ui5-card>
          <ui5-card>
            <ui5-card-header slot="header" title-text="Labels"></ui5-card-header>
            <div style="padding: 1rem; text-align: center;">
              <ui5-title level="H1">{{ animatedLabels() }}</ui5-title>
            </div>
          </ui5-card>
        </div>

        <!-- Cypher Query Sandbox -->
        <ui5-card>
          <ui5-card-header slot="header" title-text="Cypher Query Sandbox"
            subtitle-text="Run queries against the graph"></ui5-card-header>
          <div style="padding: 1rem; display: flex; flex-direction: column; gap: 1rem;">
            <!-- Preset Cards -->
            <div class="preset-grid">
              @for (p of presets; track p.label) {
                <ui5-card class="preset-card" [class.active]="cypher === p.cypher"
                  interactive (click)="setQuery(p.cypher)">
                  <ui5-card-header slot="header" [titleText]="p.label"
                    [subtitleText]="p.description"></ui5-card-header>
                  <div style="padding: 0.5rem 1rem;">
                    <code class="preset-code">{{ p.cypher }}</code>
                  </div>
                </ui5-card>
              }
            </div>
            <!-- Code Editor (custom dark textarea) -->
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
              <ui5-button design="Emphasized" icon="play"
                (click)="runQuery()" [disabled]="!cypher.trim() || querying()">
                {{ querying() ? 'Running…' : 'Run Query' }}
              </ui5-button>
              <ui5-button design="Transparent" (click)="clearResults()">Clear</ui5-button>
            </div>
            <!-- Loading -->
            @if (querying()) {
              <ui5-busy-indicator active size="L" style="width: 100%; min-height: 100px;"></ui5-busy-indicator>
            }
            <!-- Results -->
            @if (result(); as res) {
              <div class="results-section">
                <div class="result-header">
                  <ui5-tag [design]="res.status === 'ok' ? 'Positive' : 'Negative'">
                    {{ res.status === 'ok' ? 'Success' : 'Error' }}
                  </ui5-tag>
                  <span class="row-count">{{ res.count }} row(s) returned</span>
                </div>
                @if (res.rows.length) {
                  <div class="table-wrapper">
                    <ui5-table>
                      <ui5-table-header-row slot="headerRow">
                        @for (col of resultColumns(); track col) {
                          <ui5-table-header-cell>
                            <span class="sortable-th" (click)="toggleSort(col)">
                              {{ col }}
                              @if (sortColumn() === col) {
                                <span class="sort-indicator">{{ sortDirection() === 'asc' ? '▲' : '▼' }}</span>
                              }
                            </span>
                          </ui5-table-header-cell>
                        }
                      </ui5-table-header-row>
                      @for (row of sortedRows(); track $index) {
                        <ui5-table-row>
                          @for (col of resultColumns(); track col) {
                            <ui5-table-cell><span [class]="getCellClass(row[col])">{{ formatCell(row[col]) }}</span></ui5-table-cell>
                          }
                        </ui5-table-row>
                      }
                    </ui5-table>
                  </div>
                } @else {
                  <p class="empty-results">No rows returned.</p>
                }
              </div>
            }
            <!-- Error State -->
            @if (queryError()) {
              <ui5-message-strip design="Negative" hide-close-button>
                {{ queryError() }}
              </ui5-message-strip>
              <ui5-button design="Negative" icon="refresh" (click)="runQuery()">Try Again</ui5-button>
            }
          </div>
        </ui5-card>

        <!-- Query History -->
        @if (queryHistory().length) {
          <ui5-card>
            <ui5-card-header slot="header" title-text="Query History"
              [subtitleText]="queryHistory().length + ' queries'"
              interactive (click)="historyOpen.set(!historyOpen())">
            </ui5-card-header>
            @if (historyOpen()) {
              <ui5-list>
                @for (h of queryHistory(); track h.timestamp) {
                  <ui5-list-item-standard
                    [description]="h.cypher"
                    (click)="setQuery(h.cypher)">
                    <ui5-icon slot="icon" [name]="h.status === 'ok' ? 'status-positive' : 'status-negative'"></ui5-icon>
                    {{ formatTime(h.timestamp) }} · {{ h.rowCount }} rows
                  </ui5-list-item-standard>
                }
              </ui5-list>
            }
          </ui5-card>
        }

        <!-- Architecture -->
        <ui5-card>
          <ui5-card-header slot="header" title-text="Architecture"
            subtitle-text="System layers"></ui5-card-header>
          <div style="padding: 1rem;">
            <div class="arch-grid">
              @for (layer of archLayers; track layer.name) {
                <ui5-card>
                  <div style="padding: 1rem; text-align: center;">
                    <div class="arch-icon">{{ layer.icon }}</div>
                    <ui5-title level="H6">{{ layer.name }}</ui5-title>
                    <div class="arch-desc">{{ layer.desc }}</div>
                  </div>
                </ui5-card>
              }
            </div>
          </div>
        </ui5-card>

      </div>
    </ui5-page>
  `,
  styles: [`
    /* ── Header ── */
    .db-info { color: var(--sapContent_LabelColor, #6a6d70); font-size: 0.7rem; margin-left: 0.5rem; }


    /* ── Tech Pills ── */
    .tech-pills { display: flex; flex-wrap: wrap; gap: 0.5rem; }

    /* ── Stats Grid ── */
    .stats-grid { display: grid; grid-template-columns: repeat(2, 1fr); gap: 1rem; }
    @media (min-width: 1440px) {
      :host .stats-grid { grid-template-columns: repeat(4, 1fr) !important; }
    }

    /* ── Preset Grid ── */
    .preset-grid {
      display: grid; grid-template-columns: repeat(auto-fill, minmax(200px, 1fr)); gap: 0.75rem;
    }
    .preset-card.active { outline: 2px solid var(--sapBrandColor, #0854a0); }
    .preset-code {
      display: block; font-size: 0.7rem; font-family: 'SF Mono', 'SFMono-Regular', Menlo, Consolas, monospace;
      color: var(--sapBrandColor, #0854a0); background: var(--sapBackgroundColor, #f5f5f5);
      padding: 0.25rem 0.375rem; border-radius: 0.25rem; overflow: hidden;
      text-overflow: ellipsis; white-space: nowrap;
    }

    /* ── Code Editor (custom dark theme) ── */
    .editor-wrapper {
      display: flex; border: 1px solid var(--sapTile_BorderColor, #e4e4e4);
      border-radius: 0.5rem; overflow: hidden; background: #1e1e1e;
    }
    .editor-gutter {
      display: flex; flex-direction: column; padding: 0.75rem 0;
      background: #252526; border-right: 1px solid #3c3c3c;
      min-width: 2.5rem; text-align: right; user-select: none;
    }
    .line-number {
      font-family: 'SF Mono', 'SFMono-Regular', Menlo, Consolas, monospace;
      font-size: 0.75rem; line-height: 1.5rem; padding: 0 0.5rem; color: #858585;
    }
    .editor-container { position: relative; flex: 1; }
    .editor-highlight, .query-editor {
      font-family: 'SF Mono', 'SFMono-Regular', Menlo, Consolas, monospace;
      font-size: 0.8125rem; line-height: 1.5rem; padding: 0.75rem;
      white-space: pre-wrap; word-wrap: break-word;
    }
    .editor-highlight {
      position: absolute; inset: 0; pointer-events: none; color: #d4d4d4; z-index: 1;
    }
    .query-editor {
      width: 100%; height: 100%; min-height: 7.5rem; box-sizing: border-box;
      background: transparent; color: transparent; caret-color: #d4d4d4;
      border: none; outline: none; resize: vertical; position: relative; z-index: 2;
    }

    /* ── Query Actions ── */
    .query-actions { display: flex; gap: 0.5rem; align-items: center; }

    /* ── Results ── */
    .results-section { margin-top: 0.5rem; }
    .result-header { display: flex; align-items: center; gap: 0.75rem; margin-bottom: 0.5rem; }
    .row-count { font-size: 0.8125rem; color: var(--sapContent_LabelColor, #6a6d70); }
    .table-wrapper { overflow-x: auto; }
    .sortable-th { cursor: pointer; user-select: none; &:hover { color: var(--sapBrandColor, #0854a0); } }
    .sort-indicator { margin-left: 0.25rem; font-size: 0.6rem; }
    .cell-number { font-family: monospace; }
    .cell-string { font-family: monospace; }
    .empty-results { color: var(--sapContent_LabelColor, #6a6d70); font-size: 0.8125rem; text-align: center; padding: 2rem; }

    /* ── Architecture Grid ── */
    .arch-grid {
      display: grid; grid-template-columns: repeat(auto-fill, minmax(140px, 1fr)); gap: 0.75rem;
    }
    .arch-icon { font-size: 1.75rem; margin-bottom: 0.5rem; }
    .arch-desc { font-size: 0.75rem; color: var(--sapContent_LabelColor, #6a6d70); margin-top: 0.25rem; }
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