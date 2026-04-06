import { Component, OnInit, OnDestroy, CUSTOM_ELEMENTS_SCHEMA, ChangeDetectionStrategy, inject, signal } from '@angular/core';
import { CommonModule } from '@angular/common';
import { FormsModule } from '@angular/forms';
import { Subject, takeUntil, catchError, of } from 'rxjs';
import { ApiError, ApiService } from '../../services/api.service';
import { ToastService } from '../../services/toast.service';
import { I18nService } from '../../services/i18n.service';

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
  cypher: string;
}

interface ArchLayer {
  icon: string;
  name: string;
  desc: string;
}

@Component({
  selector: 'app-hippocpp',
  standalone: true,
  imports: [CommonModule, FormsModule],
  schemas: [CUSTOM_ELEMENTS_SCHEMA],
  changeDetection: ChangeDetectionStrategy.OnPush,
  template: `
    <div class="page-content">
      <div class="page-header">
        <h1 class="page-title">{{ i18n.t('hippocpp.title') }}</h1>
        <button class="btn-refresh" (click)="loadStats()">{{ i18n.t('hippocpp.refresh') }}</button>
      </div>

      <!-- About -->
      <div class="about-card">
        <p>{{ i18n.t('hippocpp.about') }}</p>
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
            <span class="status-badge {{ stats()?.available ? 'status-success' : 'status-error' }}">
              {{ stats()?.available ? i18n.t('hippocpp.available') : i18n.t('hippocpp.unavailable') }}
            </span>
          </div>
          <div class="stat-label">{{ i18n.t('hippocpp.graphStore') }}</div>
        </div>
        <div class="stat-card">
          <div class="stat-value">{{ stats()?.pair_count ?? '—' }}</div>
          <div class="stat-label">{{ i18n.t('hippocpp.pairsIndexed') }}</div>
        </div>
        <div class="stat-card">
          <div class="stat-value">1,251</div>
          <div class="stat-label">{{ i18n.t('hippocpp.zigFiles') }}</div>
        </div>
      </div>

      <!-- Cypher Query Sandbox -->
      <section class="section">
        <h2 class="section-title">{{ i18n.t('hippocpp.querySandbox') }}</h2>
        <div class="query-card">
          <div class="query-presets">
            <span class="preset-label">{{ i18n.t('hippocpp.presets') }}</span>
            @for (p of presets; track p.label) {
              <button class="preset-btn" (click)="setQuery(p.cypher)">{{ p.label }}</button>
            }
          </div>
          <textarea
            class="query-editor"
            [(ngModel)]="cypher"
            name="cypher"
            rows="4"
            placeholder="MATCH (n) RETURN n LIMIT 10"
          ></textarea>
          <div class="query-actions">
            <button class="btn-primary" (click)="runQuery()" [disabled]="!cypher.trim() || querying()">
              {{ querying() ? i18n.t('hippocpp.running') : i18n.t('hippocpp.execute') }}
            </button>
            <button class="btn-secondary" (click)="clearResults()">{{ i18n.t('hippocpp.clear') }}</button>
          </div>
        </div>

        <!-- Results -->
        @if (result(); as res) {
          <div class="results-section">
            <div class="result-header">
              <span class="status-badge {{ res.status === 'ok' ? 'status-success' : 'status-error' }}">
                {{ res.status }}
              </span>
              <span class="text-small text-muted">{{ res.count }} {{ i18n.t('hippocpp.row') }}</span>
            </div>
            @if (res.rows.length) {
              <div class="table-wrapper">
                <table class="data-table">
                  <thead>
                    <tr>
                      @for (col of resultColumns(); track col) {
                        <th>{{ col }}</th>
                      }
                    </tr>
                  </thead>
                  <tbody>
                    @for (row of res.rows; track $index) {
                      <tr>
                        @for (col of resultColumns(); track col) {
                          <td class="text-small mono">{{ formatCell(row[col]) }}</td>
                        }
                      </tr>
                    }
                  </tbody>
                </table>
              </div>
            } @else {
              <p class="text-muted text-small">{{ i18n.t('hippocpp.noRows') }}</p>
            }
          </div>
        }

        @if (queryError()) {
          <div class="error-banner">{{ queryError() }}</div>
        }
      </section>

      <!-- Architecture -->
      <section class="section">
        <h2 class="section-title">{{ i18n.t('hippocpp.architecture') }}</h2>
        <div class="arch-grid">
          @for (layer of archLayers; track layer.name) {
            <div class="arch-card">
              <div class="arch-icon"><ui5-icon [name]="layer.icon"></ui5-icon></div>
              <div class="arch-name">{{ layer.name }}</div>
              <div class="arch-desc text-small text-muted">{{ layer.desc }}</div>
            </div>
          }
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
        text-align: start;
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
export class HippocppComponent implements OnInit, OnDestroy {
  private readonly api = inject(ApiService);
  private readonly toast = inject(ToastService);
  readonly i18n = inject(I18nService);
  private readonly destroy$ = new Subject<void>();

  readonly stats = signal<GraphStats | null>(null);
  readonly result = signal<QueryResult | null>(null);
  readonly querying = signal(false);
  readonly queryError = signal('');

  cypher = 'MATCH (n) RETURN n LIMIT 10';

  readonly presets: QueryPreset[] = [
    { label: 'All nodes', cypher: 'MATCH (n) RETURN n LIMIT 10' },
    { label: 'Training pairs', cypher: 'MATCH (p:TrainingPair) RETURN p LIMIT 20' },
    { label: 'Count pairs', cypher: 'MATCH (p:TrainingPair) RETURN count(p) AS total' },
  ];

  readonly archLayers: ArchLayer[] = [
    { icon: 'edit', name: 'Parser', desc: 'Cypher query parser (Zig)' },
    { icon: 'compare', name: 'Planner', desc: 'Query plan generation' },
    { icon: 'process', name: 'Optimizer', desc: 'Cost-based optimiser' },
    { icon: 'tags', name: 'Processor', desc: 'Execution engine' },
    { icon: 'folder', name: 'Storage', desc: 'WAL + MVCC buffer mgr' },
    { icon: 'folder', name: 'Catalog', desc: 'Schema & type catalog' },
    { icon: 'machine', name: 'Mojo GPU', desc: 'SIMD page acceleration' },
    { icon: 'document', name: 'Mangle', desc: 'Datalog invariants' },
  ];

  readonly resultColumns = () => {
    const res = this.result();
    if (!res?.rows?.length) return [];
    return Object.keys(res.rows[0]);
  };

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
        catchError(() => {
          this.toast.warning('Graph stats unavailable', 'Graph');
          return of(null);
        })
      )
      .subscribe({
        next: (s: GraphStats | null) => this.stats.set(s),
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

    this.api.post<QueryResult>('/graph/query', { cypher: this.cypher })
      .pipe(takeUntil(this.destroy$))
      .subscribe({
        next: (r: QueryResult) => {
          this.result.set(r);
          this.querying.set(false);
          if (r.status === 'ok') {
            this.toast.success(`Query returned ${r.count} row(s)`, 'Query Complete');
          }
        },
        error: (e: ApiError | { error?: { detail?: string } }) => {
          const detail = e instanceof ApiError
            ? e.detail
            : e.error?.detail ?? 'Query failed';
          this.queryError.set(detail);
          this.toast.error(detail, 'Query Error');
          this.querying.set(false);
        },
      });
  }

  clearResults(): void {
    this.result.set(null);
    this.queryError.set('');
  }

  formatCell(val: unknown): string {
    if (val === null || val === undefined) return '—';
    if (typeof val === 'object') return JSON.stringify(val);
    return String(val);
  }
}
