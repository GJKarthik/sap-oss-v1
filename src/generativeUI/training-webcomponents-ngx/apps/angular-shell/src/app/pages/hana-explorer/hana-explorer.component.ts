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
}

interface QueryResult {
  status: string;
  rows: Record<string, unknown>[];
  count: number;
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
      <div class="about-card">
        <p>{{ i18n.t('hanaExplorer.about') }}</p>
        <div class="tech-pills">
          <span class="pill pill--hana">SAP HANA Cloud</span>
          <span class="pill pill--python">Python hdbcli</span>
          <span class="pill pill--vector">Vector Engine</span>
          <span class="pill pill--sql">SQL Console</span>
        </div>
      </div>

      <!-- Stats -->
      <div class="stats-grid" style="margin-bottom: 1.5rem;" role="region" aria-label="HANA Cloud statistics">
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
          <div class="stat-value">6</div>
          <div class="stat-label">{{ i18n.t('hanaExplorer.schemas') }}</div>
        </div>
      </div>

      <!-- SQL Query Sandbox -->
      <section class="section">
        <h2 class="section-title">{{ i18n.t('hanaExplorer.querySandbox') }}</h2>
        <div class="query-card">
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
            rows="4"
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
          <div class="results-section">
            <div class="result-header">
              <span class="status-badge {{ res.status === 'ok' ? 'status-success' : 'status-error' }}">
                {{ res.status }}
              </span>
              <span class="text-small text-muted">{{ res.count }} {{ i18n.t('hanaExplorer.row') }}</span>
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

      &.pill--hana   { background: var(--sapInformationBackground, #e3f2fd); color: var(--sapInformativeColor, #0d47a1); }
      &.pill--python { background: var(--sapSuccessBackground, #e8f5e9); color: var(--sapPositiveColor, #1b5e20); }
      &.pill--vector { background: var(--sapWarningBackground, #fff3e0); color: var(--sapCriticalColor, #e65100); }
      &.pill--sql    { background: var(--sapNeutralBackground, #f5f5f5); color: var(--sapTextColor, #32363a); }
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
      background: var(--sapErrorBackground, #ffebee);
      color: var(--sapNegativeColor, #c62828);
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

  sql = 'SELECT * FROM TRAINING_PAIRS LIMIT 10';

  readonly presets: QueryPreset[] = [
    { label: this.i18n.t('hanaExplorer.presetAllTables'), sql: 'SELECT TABLE_NAME, SCHEMA_NAME FROM SYS.TABLES WHERE SCHEMA_NAME NOT LIKE \'SYS%\' LIMIT 20' },
    { label: this.i18n.t('hanaExplorer.presetTrainingPairs'), sql: 'SELECT * FROM TRAINING_PAIRS LIMIT 20' },
    { label: this.i18n.t('hanaExplorer.presetCountPairs'), sql: 'SELECT COUNT(*) AS total FROM TRAINING_PAIRS' },
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
