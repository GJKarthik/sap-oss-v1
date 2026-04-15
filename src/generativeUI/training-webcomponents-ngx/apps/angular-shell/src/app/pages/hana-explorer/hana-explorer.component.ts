import { Component, OnInit, OnDestroy, CUSTOM_ELEMENTS_SCHEMA, ChangeDetectionStrategy, inject, signal } from '@angular/core';
import { CommonModule } from '@angular/common';
import { FormsModule } from '@angular/forms';
import { Subject, takeUntil, catchError, of } from 'rxjs';
import { ApiError, ApiService } from '../../services/api.service';
import { ToastService } from '../../services/toast.service';
import { I18nService } from '../../services/i18n.service';
import { CrossAppLinkComponent } from '../../shared';

interface HanaStats {
  available: boolean;
  pair_count: number;
  mode?: 'live' | 'preview';
  reason?: 'credentials_missing' | 'reconnecting';
}

interface QueryResult {
  status: string;
  rows: Record<string, unknown>[];
  count: number;
  mode?: 'live' | 'preview';
  reason?: 'credentials_missing' | 'reconnecting';
}

interface QueryPreset {
  label: string;
  sql: string;
}

interface ArchLayer {
  icon: string;
  name: string;
  desc: string;
}

@Component({
  selector: 'app-hana-explorer',
  standalone: true,
  imports: [CommonModule, FormsModule, CrossAppLinkComponent],
  schemas: [CUSTOM_ELEMENTS_SCHEMA],
  changeDetection: ChangeDetectionStrategy.OnPush,
  template: `
    <div class="page-content" role="main" aria-label="HANA Cloud Explorer">
      <div class="page-header">
        <h1 class="page-title">{{ i18n.t('hanaExplorer.title') }}</h1>
        <ui5-button design="Default" (click)="loadStats()" aria-label="Refresh stats">{{ i18n.t('hanaExplorer.refresh') }}</ui5-button>
      </div>

      <app-cross-app-link
        targetApp="training"
        targetRoute="/lineage"
        targetLabelKey="nav.lineage"
        icon="journey-change">
      </app-cross-app-link>

      <!-- About -->
      <div class="about-card glass-panel">
        <p>{{ i18n.t('hanaExplorer.about') }}</p>
        <div class="tech-pills">
          <span class="pill pill--hana">SAP HANA Cloud</span>
          <span class="pill pill--python">Python hdbcli</span>
          <span class="pill pill--vector">Vector Engine</span>
          <span class="pill pill--sql">SQL Console</span>
        </div>
      </div>

      <!-- Stats -->
      <div class="stats-grid" role="region" aria-label="HANA Cloud statistics">
        <div class="stat-card">
          <div class="stat-value">
            <span class="status-badge {{ stats()?.available ? 'status-success' : 'status-error' }}">
              {{ stats()?.available ? i18n.t('hanaExplorer.available') : i18n.t('hanaExplorer.unavailable') }}
            </span>
          </div>
          <div class="stat-label">{{ i18n.t('hanaExplorer.hanaConnection') }}</div>
        </div>
        <div class="stat-card">
          <div class="stat-value">{{ stats()?.pair_count ?? '—' }}</div>
          <div class="stat-label">{{ i18n.t('hanaExplorer.pairsStored') }}</div>
        </div>
        <div class="stat-card">
          <div class="stat-value">7</div>
          <div class="stat-label">Governance Tables</div>
        </div>
      </div>

      @if (stats()?.mode === 'preview') {
        <div class="info-banner">{{ hanaNotice(stats()?.reason) }}</div>
      }

      <!-- SQL Query Sandbox -->
      <section class="section">
        <h2 class="section-title">{{ i18n.t('hanaExplorer.querySandbox') }}</h2>
        <div class="query-card glass-panel">
          <div class="query-presets">
            <span class="preset-label">{{ i18n.t('hanaExplorer.presets') }}</span>
            @for (p of presets; track p.label) {
              <ui5-button design="Default" (click)="setQuery(p.sql)">{{ p.label }}</ui5-button>
            }
          </div>
          <textarea
            class="query-editor"
            [(ngModel)]="sql"
            name="sql"
            aria-label="SQL query editor"
            rows="6"
            placeholder="SELECT * FROM TRAINING_PAIRS LIMIT 10"
          ></textarea>
          <div class="query-actions">
            <ui5-button design="Emphasized" (click)="runQuery()" [disabled]="!sql.trim() || querying()">
              {{ querying() ? i18n.t('hanaExplorer.running') : i18n.t('hanaExplorer.execute') }}
            </ui5-button>
            <ui5-button design="Transparent" (click)="clearResults()">{{ i18n.t('hanaExplorer.clear') }}</ui5-button>
          </div>
        </div>

        <!-- Results -->
        @if (result(); as res) {
          <div class="results-section fadeIn">
            <div class="result-header">
              <span class="status-badge {{ res.status === 'ok' ? 'status-success' : 'status-error' }}">
                {{ res.status }}
              </span>
              <span class="text-small text-muted">{{ res.count }} {{ i18n.t('hanaExplorer.row') }}</span>
            </div>
            @if (res.mode === 'preview') {
              <div class="info-banner">{{ hanaNotice(res.reason) }}</div>
            }
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
              <p class="text-muted text-small">{{ i18n.t('hanaExplorer.noRows') }}</p>
            }
          </div>
        }

        @if (queryError()) {
          <div class="error-banner">{{ queryError() }}</div>
        }
      </section>

      <!-- Architecture -->
      <section class="section">
        <h2 class="section-title">{{ i18n.t('hanaExplorer.architecture') }}</h2>
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
    .page-content { 
      padding: clamp(1.5rem, 4vw, 4rem); 
      display: flex; flex-direction: column; gap: 2.5rem;
      background: radial-gradient(circle at 0% 100%, rgba(0, 112, 242, 0.08), transparent 40rem);
    }

    .page-header { display: flex; justify-content: space-between; align-items: center; }
    .page-title { font-size: 2.5rem; font-weight: 800; letter-spacing: -0.02em; margin: 0; }

    .about-card {
      background: var(--liquid-glass-bg);
      backdrop-filter: var(--liquid-glass-blur);
      border: var(--liquid-glass-border);
      box-shadow: var(--liquid-glass-shadow);
      border-radius: 24px;
      padding: 2rem;
      font-size: 1.1rem;
      color: #424245;
      line-height: 1.5;

      p { margin: 0 0 1.25rem; }
    }

    .tech-pills { display: flex; flex-wrap: wrap; gap: 0.75rem; }

    .pill {
      padding: 0.35rem 1rem;
      border-radius: 999px;
      font-size: 0.8125rem;
      font-weight: 600;
      text-transform: uppercase;
      letter-spacing: 0.05em;

      &.pill--hana   { background: rgba(var(--color-primary-rgb), 0.1); color: var(--color-primary); }
      &.pill--python { background: rgba(var(--color-success-rgb), 0.1); color: var(--color-success); }
      &.pill--vector { background: rgba(var(--color-warning-rgb), 0.1); color: var(--color-warning); }
      &.pill--sql    { background: rgba(123, 97, 255, 0.1); color: #7b61ff; }
    }

    .stats-grid { 
      display: grid; 
      grid-template-columns: repeat(auto-fit, minmax(240px, 1fr)); 
      gap: 1.5rem; 
    }

    .stat-card {
      padding: 2rem;
      background: #fff;
      border-radius: 24px;
      border: 1px solid rgba(0, 0, 0, 0.04);
      display: flex;
      flex-direction: column;
      gap: 0.5rem;
      transition: all 0.2s;

      &:hover { transform: translateY(-2px); box-shadow: 0 10px 30px rgba(0, 0, 0, 0.05); }
    }

    .stat-value { font-size: 2.5rem; font-weight: 800; color: var(--text-primary); letter-spacing: -0.02em; }
    .stat-label { font-size: 0.875rem; font-weight: 600; color: var(--text-secondary); text-transform: uppercase; letter-spacing: 0.05em; }

    .query-card {
      padding: 2rem;
      display: flex;
      flex-direction: column;
      gap: 1.5rem;
    }

    .query-presets { display: flex; align-items: center; gap: 1rem; flex-wrap: wrap; }
    .preset-label { font-size: 0.75rem; font-weight: 700; text-transform: uppercase; color: var(--text-secondary); }

    .query-editor {
      width: 100%;
      background: var(--code-bg);
      color: var(--code-text);
      border: none;
      border-radius: 16px;
      padding: 1.5rem;
      font-family: var(--sapFontFamilyMono, monospace);
      font-size: 0.9rem;
      line-height: 1.6;
      resize: vertical;
      box-shadow: inset 0 2px 10px rgba(0, 0, 0, 0.2);
    }

    .query-actions { display: flex; gap: 1rem; }

    .results-section {
      margin-top: 2rem;
      padding: 2rem;
      background: #fff;
      border-radius: 28px;
      border: 1px solid rgba(0, 0, 0, 0.05);
    }

    .result-header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 1.5rem; }

    .table-wrapper { overflow-x: auto; border-radius: 16px; border: 1px solid rgba(0, 0, 0, 0.05); }
    .data-table { 
      width: 100%; border-collapse: collapse; 
      th { text-align: left; padding: 1rem; font-size: 0.75rem; font-weight: 700; text-transform: uppercase; color: var(--text-secondary); border-bottom: 1px solid rgba(0, 0, 0, 0.05); }
      td { padding: 1rem; font-size: 0.875rem; border-bottom: 1px solid rgba(0, 0, 0, 0.03); }
    }

    .arch-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(280px, 1fr)); gap: 1.5rem; }
    .arch-card {
      padding: 2rem;
      background: var(--bg-primary);
      border-radius: 24px;
      border: 1px solid rgba(0, 0, 0, 0.03);
      display: flex;
      flex-direction: column;
      gap: 1rem;
      transition: all 0.2s;

      &:hover { background: #fff; transform: scale(1.02); box-shadow: 0 10px 30px rgba(0, 0, 0, 0.05); }
    }

    .arch-icon { width: 3.5rem; height: 3.5rem; border-radius: 12px; background: rgba(var(--color-primary-rgb), 0.08); display: flex; align-items: center; justify-content: center; color: var(--color-primary); font-size: 1.5rem; }
    .arch-name { font-size: 1.1rem; font-weight: 700; color: var(--text-primary); }
    .arch-desc { font-size: 0.875rem; line-height: 1.5; color: var(--text-secondary); }

    .status-badge {
      font-size: 0.75rem; font-weight: 700; padding: 0.25rem 0.75rem; border-radius: 999px;
      &.status-success { background: rgba(var(--color-success-rgb), 0.1); color: var(--color-success); }
      &.status-error { background: rgba(var(--color-error-rgb), 0.1); color: var(--color-error); }
    }

    .section-title { font-size: 1.75rem; font-weight: 800; letter-spacing: -0.02em; margin-bottom: 1.5rem; }

    .mono { font-family: var(--sapFontFamilyMono, monospace); }

    .info-banner {
      padding: 1rem 1.5rem; background: rgba(var(--color-primary-rgb), 0.05); color: var(--color-primary);
      border-radius: 16px; font-size: 0.95rem; margin: 0 0 1.5rem; font-weight: 500;
    }

    .error-banner {
      padding: 1rem 1.5rem; background: rgba(var(--color-error-rgb), 0.05); color: var(--color-error);
      border-radius: 16px; font-size: 0.95rem; margin-top: 1rem; font-weight: 500;
    }

    @media (max-width: 768px) {
      .arch-grid { grid-template-columns: 1fr; }
    }
  `],
})
export class HanaExplorerComponent implements OnInit, OnDestroy {
  private readonly api = inject(ApiService);
  private readonly toast = inject(ToastService);
  readonly i18n = inject(I18nService);
  private readonly destroy$ = new Subject<void>();

  readonly stats = signal<HanaStats | null>(null);
  readonly result = signal<QueryResult | null>(null);
  readonly querying = signal(false);
  readonly queryError = signal('');

  sql = 'SELECT * FROM TRAINING_RUNS LIMIT 10';

  readonly presets: QueryPreset[] = [
    { label: this.i18n.t('hanaExplorer.presetAllTables'), sql: 'SELECT TABLE_NAME, SCHEMA_NAME FROM SYS.TABLES WHERE SCHEMA_NAME NOT LIKE \'SYS%\' LIMIT 20' },
    { label: this.i18n.t('hanaExplorer.presetTrainingPairs'), sql: 'SELECT * FROM TRAINING_PAIRS LIMIT 20' },
    { label: this.i18n.t('hanaExplorer.presetCountPairs'), sql: 'SELECT COUNT(*) AS total FROM TRAINING_PAIRS' },
    { label: 'Training runs', sql: 'SELECT ID, WORKFLOW_TYPE, STATUS, RISK_TIER, GATE_STATUS FROM TRAINING_RUNS LIMIT 20' },
    { label: 'Approvals', sql: 'SELECT ID, RUN_ID, STATUS, RISK_LEVEL FROM TRAINING_APPROVALS LIMIT 20' },
    { label: 'Gate checks', sql: 'SELECT RUN_ID, GATE_KEY, STATUS, CATEGORY FROM TRAINING_GATE_CHECKS LIMIT 20' },
    { label: 'Metric snapshots', sql: 'SELECT RUN_ID, METRIC_KEY, VALUE, STAGE FROM TRAINING_METRIC_SNAPSHOTS LIMIT 20' },
  ];

  readonly archLayers: ArchLayer[] = [
    { icon: 'database', name: this.i18n.t('hanaExplorer.archColumnStore'), desc: this.i18n.t('hanaExplorer.archColumnStoreDesc') },
    { icon: 'search', name: this.i18n.t('hanaExplorer.archVectorEngine'), desc: this.i18n.t('hanaExplorer.archVectorEngineDesc') },
    { icon: 'process', name: this.i18n.t('hanaExplorer.archSqlEngine'), desc: this.i18n.t('hanaExplorer.archSqlEngineDesc') },
    { icon: 'tags', name: this.i18n.t('hanaExplorer.archSchemaRegistry'), desc: this.i18n.t('hanaExplorer.archSchemaRegistryDesc') },
    { icon: 'folder', name: this.i18n.t('hanaExplorer.archPersistence'), desc: this.i18n.t('hanaExplorer.archPersistenceDesc') },
    { icon: 'shield', name: this.i18n.t('hanaExplorer.archSecurity'), desc: this.i18n.t('hanaExplorer.archSecurityDesc') },
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
    this.api.get<HanaStats>('/hana/stats')
      .pipe(
        takeUntil(this.destroy$),
        catchError(() => {
          this.toast.warning(this.i18n.t('hanaExplorer.statsUnavailable'), 'HANA Cloud');
          return of(null);
        })
      )
      .subscribe({
        next: (s: HanaStats | null) => this.stats.set(s),
      });
  }

  setQuery(q: string): void {
    this.sql = q;
  }

  hanaNotice(reason?: 'credentials_missing' | 'reconnecting'): string {
    return reason === 'credentials_missing'
      ? this.i18n.t('hanaExplorer.previewCredentials')
      : this.i18n.t('hanaExplorer.previewReconnect');
  }

  runQuery(): void {
    if (!this.sql.trim()) return;
    this.querying.set(true);
    this.queryError.set('');
    this.result.set(null);

    this.api.post<QueryResult>('/hana/query', { sql: this.sql })
      .pipe(takeUntil(this.destroy$))
      .subscribe({
        next: (r: QueryResult) => {
          this.result.set(r);
          this.querying.set(false);
          if (r.status === 'ok' && r.mode !== 'preview') {
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
