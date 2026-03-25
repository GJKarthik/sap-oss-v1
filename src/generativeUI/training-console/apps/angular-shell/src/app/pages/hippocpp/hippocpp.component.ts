import { Component, OnInit, CUSTOM_ELEMENTS_SCHEMA } from '@angular/core';
import { CommonModule } from '@angular/common';
import { FormsModule } from '@angular/forms';
import { ApiService } from '../../services/api.service';

interface GraphStats {
  available: boolean;
  pair_count: number;
}

interface QueryResult {
  status: string;
  rows: Record<string, unknown>[];
  count: number;
}

@Component({
  selector: 'app-hippocpp',
  standalone: true,
  imports: [CommonModule, FormsModule],
  schemas: [CUSTOM_ELEMENTS_SCHEMA],
  template: `
    <div class="page-content">
      <div class="page-header">
        <h1 class="page-title">HippoCPP Graph Engine</h1>
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

      <!-- Stats -->
      <div class="stats-grid" style="margin-bottom: 1.5rem;">
        <div class="stat-card">
          <div class="stat-value">
            <span class="status-badge {{ stats?.available ? 'status-success' : 'status-error' }}">
              {{ stats?.available ? 'Available' : 'Unavailable' }}
            </span>
          </div>
          <div class="stat-label">Graph Store</div>
        </div>
        <div class="stat-card">
          <div class="stat-value">{{ stats?.pair_count ?? '—' }}</div>
          <div class="stat-label">Training Pairs Indexed</div>
        </div>
        <div class="stat-card">
          <div class="stat-value">1,251</div>
          <div class="stat-label">Zig Source Files</div>
        </div>
      </div>

      <!-- Cypher Query Sandbox -->
      <section class="section">
        <h2 class="section-title">Cypher Query Sandbox</h2>
        <div class="query-card">
          <div class="query-presets">
            <span class="preset-label">Presets:</span>
            <button class="preset-btn" (click)="setQuery(p.cypher)" *ngFor="let p of presets">{{ p.label }}</button>
          </div>
          <textarea
            class="query-editor"
            [(ngModel)]="cypher"
            name="cypher"
            rows="4"
            placeholder="MATCH (n) RETURN n LIMIT 10"
          ></textarea>
          <div class="query-actions">
            <button class="btn-primary" (click)="runQuery()" [disabled]="!cypher.trim() || querying">
              {{ querying ? 'Running…' : '▶ Execute' }}
            </button>
            <button class="btn-secondary" (click)="clearResults()">Clear</button>
          </div>
        </div>

        <!-- Results -->
        <div class="results-section" *ngIf="result">
          <div class="result-header">
            <span class="status-badge {{ result.status === 'ok' ? 'status-success' : 'status-error' }}">
              {{ result.status }}
            </span>
            <span class="text-small text-muted">{{ result.count }} row(s)</span>
          </div>
          <div class="table-wrapper" *ngIf="result.rows.length">
            <table class="data-table">
              <thead>
                <tr>
                  <th *ngFor="let col of resultColumns">{{ col }}</th>
                </tr>
              </thead>
              <tbody>
                <tr *ngFor="let row of result.rows">
                  <td *ngFor="let col of resultColumns" class="text-small mono">
                    {{ formatCell(row[col]) }}
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
          <p class="text-muted text-small" *ngIf="!result.rows.length">No rows returned.</p>
        </div>

        <div class="error-banner" *ngIf="queryError">⚠ {{ queryError }}</div>
      </section>

      <!-- Architecture -->
      <section class="section">
        <h2 class="section-title">Architecture</h2>
        <div class="arch-grid">
          <div class="arch-card" *ngFor="let layer of archLayers">
            <div class="arch-icon">{{ layer.icon }}</div>
            <div class="arch-name">{{ layer.name }}</div>
            <div class="arch-desc text-small text-muted">{{ layer.desc }}</div>
          </div>
        </div>
      </section>
    </div>
  `,
  styles: [`
    .about-card {
      background: var(--sapTile_Background, #fff);
      border: 1px solid var(--sapTile_BorderColor, #e4e4e4);
      border-radius: 0.5rem;
      padding: 1.25rem;
      margin-bottom: 1.5rem;
      font-size: 0.875rem;
      color: var(--sapTextColor, #32363a);

      p { margin: 0 0 0.75rem; }
      a { color: var(--sapLinkColor, #0854a0); }
    }

    .tech-pills { display: flex; flex-wrap: wrap; gap: 0.5rem; }

    .pill {
      padding: 0.2rem 0.6rem;
      border-radius: 1rem;
      font-size: 0.75rem;
      font-weight: 500;

      &.pill--zig    { background: #fff3e0; color: #e65100; }
      &.pill--mojo   { background: #fce4ec; color: #880e4f; }
      &.pill--mangle { background: #e8f5e9; color: #1b5e20; }
      &.pill--python { background: #e3f2fd; color: #0d47a1; }
    }

    .btn-refresh {
      padding: 0.375rem 0.875rem;
      background: var(--sapBrandColor, #0854a0);
      color: #fff;
      border: none;
      border-radius: 0.25rem;
      cursor: pointer;
      font-size: 0.875rem;
      &:hover { background: var(--sapButton_Hover_Background, #0a6ed1); }
    }

    .section { margin-bottom: 2rem; }

    .section-title {
      font-size: 1rem;
      font-weight: 600;
      margin: 0 0 0.75rem;
      color: var(--sapTextColor, #32363a);
    }

    .query-card {
      background: var(--sapTile_Background, #fff);
      border: 1px solid var(--sapTile_BorderColor, #e4e4e4);
      border-radius: 0.5rem;
      padding: 1.25rem;
      margin-bottom: 1rem;
    }

    .query-presets {
      display: flex;
      align-items: center;
      gap: 0.5rem;
      margin-bottom: 0.5rem;
      flex-wrap: wrap;
    }

    .preset-label { font-size: 0.75rem; color: var(--sapContent_LabelColor, #6a6d70); }

    .preset-btn {
      padding: 0.15rem 0.5rem;
      background: var(--sapList_Background, #f5f5f5);
      border: 1px solid var(--sapField_BorderColor, #89919a);
      border-radius: 0.25rem;
      cursor: pointer;
      font-size: 0.75rem;
      color: var(--sapTextColor, #32363a);
      &:hover { background: var(--sapList_Hover_Background, #e8e8e8); }
    }

    .query-editor {
      width: 100%;
      box-sizing: border-box;
      padding: 0.625rem;
      border: 1px solid var(--sapField_BorderColor, #89919a);
      border-radius: 0.25rem;
      font-family: 'SFMono-Regular', Consolas, monospace;
      font-size: 0.8125rem;
      background: var(--sapField_Background, #fafafa);
      color: var(--sapTextColor, #32363a);
      resize: vertical;
      margin-bottom: 0.75rem;
    }

    .query-actions { display: flex; gap: 0.5rem; align-items: center; }

    .btn-primary {
      padding: 0.375rem 0.875rem;
      background: var(--sapBrandColor, #0854a0);
      color: #fff;
      border: none;
      border-radius: 0.25rem;
      cursor: pointer;
      font-size: 0.875rem;
      &:disabled { opacity: 0.5; cursor: default; }
      &:hover:not(:disabled) { background: var(--sapButton_Hover_Background, #0a6ed1); }
    }

    .btn-secondary {
      padding: 0.375rem 0.875rem;
      background: transparent;
      color: var(--sapTextColor, #32363a);
      border: 1px solid var(--sapField_BorderColor, #89919a);
      border-radius: 0.25rem;
      cursor: pointer;
      font-size: 0.875rem;
      &:hover { background: var(--sapList_Hover_Background, #f5f5f5); }
    }

    .results-section { margin-top: 1rem; }

    .result-header {
      display: flex;
      align-items: center;
      gap: 0.75rem;
      margin-bottom: 0.5rem;
    }

    .table-wrapper { overflow-x: auto; }

    .data-table {
      width: 100%;
      border-collapse: collapse;
      font-size: 0.8125rem;
      background: var(--sapTile_Background, #fff);
      border: 1px solid var(--sapTile_BorderColor, #e4e4e4);
      border-radius: 0.5rem;
      overflow: hidden;

      th {
        padding: 0.5rem 0.75rem;
        background: var(--sapList_HeaderBackground, #f5f5f5);
        text-align: left;
        font-weight: 600;
        font-size: 0.7rem;
        text-transform: uppercase;
        letter-spacing: 0.04em;
        color: var(--sapContent_LabelColor, #6a6d70);
        border-bottom: 1px solid var(--sapList_BorderColor, #e4e4e4);
      }

      td {
        padding: 0.4rem 0.75rem;
        border-bottom: 1px solid var(--sapList_BorderColor, #e4e4e4);
      }

      tr:last-child td { border-bottom: none; }
    }

    .mono { font-family: 'SFMono-Regular', Consolas, monospace; }

    .error-banner {
      padding: 0.75rem 1rem;
      background: #ffebee;
      color: #c62828;
      border-radius: 0.25rem;
      font-size: 0.875rem;
      margin-top: 0.5rem;
    }

    .arch-grid {
      display: grid;
      grid-template-columns: repeat(auto-fill, minmax(180px, 1fr));
      gap: 0.75rem;
    }

    .arch-card {
      background: var(--sapTile_Background, #fff);
      border: 1px solid var(--sapTile_BorderColor, #e4e4e4);
      border-radius: 0.5rem;
      padding: 1rem;
      text-align: center;
    }

    .arch-icon { font-size: 1.75rem; margin-bottom: 0.5rem; }
    .arch-name { font-weight: 600; font-size: 0.875rem; margin-bottom: 0.25rem; }
    .arch-desc { font-size: 0.75rem; }
  `],
})
export class HippocppComponent implements OnInit {
  stats: GraphStats | null = null;
  cypher = 'MATCH (n) RETURN n LIMIT 10';
  result: QueryResult | null = null;
  querying = false;
  queryError = '';

  presets = [
    { label: 'All nodes', cypher: 'MATCH (n) RETURN n LIMIT 10' },
    { label: 'Training pairs', cypher: 'MATCH (p:TrainingPair) RETURN p LIMIT 20' },
    { label: 'Count pairs', cypher: 'MATCH (p:TrainingPair) RETURN count(p) AS total' },
  ];

  archLayers = [
    { icon: '⚡', name: 'Parser', desc: 'Cypher query parser (Zig)' },
    { icon: '📐', name: 'Planner', desc: 'Query plan generation' },
    { icon: '🔧', name: 'Optimizer', desc: 'Cost-based optimiser' },
    { icon: '⚙', name: 'Processor', desc: 'Execution engine' },
    { icon: '💾', name: 'Storage', desc: 'WAL + MVCC buffer mgr' },
    { icon: '🗂', name: 'Catalog', desc: 'Schema & type catalog' },
    { icon: '🚀', name: 'Mojo GPU', desc: 'SIMD page acceleration' },
    { icon: '📜', name: 'Mangle', desc: 'Datalog invariants' },
  ];

  constructor(private api: ApiService) {}

  ngOnInit(): void {
    this.loadStats();
  }

  loadStats(): void {
    this.api.get<GraphStats>('/graph/stats').subscribe({
      next: (s) => (this.stats = s),
      error: () => {},
    });
  }

  setQuery(q: string): void {
    this.cypher = q;
  }

  runQuery(): void {
    if (!this.cypher.trim()) return;
    this.querying = true;
    this.queryError = '';
    this.result = null;
    this.api.post<QueryResult>('/graph/query', { cypher: this.cypher }).subscribe({
      next: (r) => {
        this.result = r;
        this.querying = false;
      },
      error: (e) => {
        this.queryError = e?.error?.detail ?? 'Query failed';
        this.querying = false;
      },
    });
  }

  clearResults(): void {
    this.result = null;
    this.queryError = '';
  }

  get resultColumns(): string[] {
    if (!this.result?.rows?.length) return [];
    return Object.keys(this.result.rows[0]);
  }

  formatCell(val: unknown): string {
    if (val === null || val === undefined) return '—';
    if (typeof val === 'object') return JSON.stringify(val);
    return String(val);
  }
}
