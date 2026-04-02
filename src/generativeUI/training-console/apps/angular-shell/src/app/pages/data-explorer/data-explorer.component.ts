import { Component, CUSTOM_ELEMENTS_SCHEMA, ChangeDetectionStrategy, signal, computed, inject, OnInit } from '@angular/core';
import { CommonModule } from '@angular/common';
import { FormsModule } from '@angular/forms';
import { Ui5WebcomponentsModule } from '@ui5/webcomponents-ngx';
import '@ui5/webcomponents-icons/dist/AllIcons.js';
import { HttpClient } from '@angular/common/http';
import { DomSanitizer, SafeHtml } from '@angular/platform-browser';
import { environment } from '../../../environments/environment';

type AssetType = 'xlsx' | 'csv' | 'template';
type TabId = 'assets' | 'pairs';
type Difficulty = '' | 'easy' | 'medium' | 'hard';
type SortField = 'id' | 'difficulty' | 'db_id' | 'question';
type SortDir = 'asc' | 'desc';

interface DataAsset {
  name: string;
  type: AssetType;
  size: string;
  description: string;
  category: string;
}

interface SqlPair {
  id: string;
  difficulty: string;
  db_id: string;
  question: string;
  query: string;
}

@Component({
  selector: 'app-data-explorer',
  standalone: true,
  imports: [CommonModule, FormsModule, Ui5WebcomponentsModule],
  schemas: [CUSTOM_ELEMENTS_SCHEMA],
  changeDetection: ChangeDetectionStrategy.OnPush,
  template: `
    <ui5-page background-design="Solid">
      <ui5-bar slot="header" design="Header">
        <ui5-title slot="startContent" level="H3">Data Explorer</ui5-title>
        <div slot="endContent">
          <ui5-segmented-button>
            <ui5-segmented-button-item [pressed]="activeTab() === 'assets'" (click)="setTab('assets')">📂 Data Assets</ui5-segmented-button-item>
            <ui5-segmented-button-item [pressed]="activeTab() === 'pairs'" (click)="setTab('pairs')">🔍 SQL Training Pairs</ui5-segmented-button-item>
          </ui5-segmented-button>
        </div>
      </ui5-bar>

      <div style="padding: 1.5rem; display: flex; flex-direction: column; gap: 1.5rem;">

      <!-- Tab: Data Assets -->
      @if (activeTab() === 'assets') {
        <div class="filter-bar">
          <ui5-input type="Text" placeholder="Filter assets…" [value]="searchTerm" (input)="searchTerm = $any($event).target.value" icon="search" style="width: 200px;"></ui5-input>
          <ui5-select (change)="filterCategory = $any($event).detail.selectedOption.value">
            <ui5-option value="">All categories</ui5-option>
            @for (c of categories(); track c) {
              <ui5-option [value]="c">{{ c }}</ui5-option>
            }
          </ui5-select>
        </div>

        <div class="stats-grid">
          <ui5-card>
            <ui5-card-header slot="header" title-text="Total Assets"></ui5-card-header>
            <div style="padding: 1rem; text-align: center;">
              <ui5-title level="H1">{{ assets.length }}</ui5-title>
            </div>
          </ui5-card>
          <ui5-card>
            <ui5-card-header slot="header" title-text="Excel Files"></ui5-card-header>
            <div style="padding: 1rem; text-align: center;">
              <ui5-title level="H1">{{ excelCount() }}</ui5-title>
            </div>
          </ui5-card>
          <ui5-card>
            <ui5-card-header slot="header" title-text="CSV Files"></ui5-card-header>
            <div style="padding: 1rem; text-align: center;">
              <ui5-title level="H1">{{ csvCount() }}</ui5-title>
            </div>
          </ui5-card>
          <ui5-card>
            <ui5-card-header slot="header" title-text="Prompt Templates"></ui5-card-header>
            <div style="padding: 1rem; text-align: center;">
              <ui5-title level="H1">{{ templateCount() }}</ui5-title>
            </div>
          </ui5-card>
        </div>

        <div class="asset-grid">
          @for (a of filteredAssets(); track a.name) {
            <ui5-card interactive (click)="select(a)" [class.asset-card--active]="selected()?.name === a.name">
              <ui5-card-header slot="header" [titleText]="a.name" [subtitleText]="a.description"></ui5-card-header>
              <div style="padding: 0.75rem 1rem;">
                <div class="asset-meta">
                  <ui5-tag [design]="a.type === 'xlsx' ? 'Positive' : a.type === 'csv' ? 'Information' : 'Set2'">{{ a.type.toUpperCase() }}</ui5-tag>
                  <ui5-tag design="Set2">{{ a.category }}</ui5-tag>
                  <span class="text-small text-muted">{{ a.size }}</span>
                </div>
              </div>
            </ui5-card>
          }
        </div>

        @if (!filteredAssets().length) {
          <ui5-message-strip design="Information" hide-close-button>No assets match your filter.</ui5-message-strip>
        }

        @if (selected(); as sel) {
          <ui5-card>
            <ui5-card-header slot="header" [titleText]="sel.name" [subtitleText]="sel.description">
            </ui5-card-header>
            <div style="padding: 1rem;">
              <div class="detail-header">
                <span class="detail-icon">{{ iconFor(sel.type) }}</span>
                <ui5-button design="Transparent" icon="decline" (click)="clearSelection()" style="margin-left: auto;"></ui5-button>
              </div>
              <table class="info-table">
                <tbody>
                  <tr><td>Type</td><td>{{ sel.type.toUpperCase() }}</td></tr>
                  <tr><td>Category</td><td>{{ sel.category }}</td></tr>
                  <tr><td>Size</td><td>{{ sel.size }}</td></tr>
                  <tr><td>Description</td><td>{{ sel.description }}</td></tr>
                  <tr><td>Location</td><td><code>data/{{ sel.name }}</code></td></tr>
                </tbody>
              </table>
            </div>
          </ui5-card>
        }
      }

      <!-- Tab: SQL Training Pairs -->
      @if (activeTab() === 'pairs') {
        <!-- Stats Cards -->
        <div class="stats-grid">
          <ui5-card>
            <ui5-card-header slot="header" title-text="Total Records"></ui5-card-header>
            <div style="padding: 1rem; text-align: center;">
              <ui5-title level="H1">{{ pairTotal() }}</ui5-title>
            </div>
          </ui5-card>
          <ui5-card>
            <ui5-card-header slot="header" title-text="Avg Difficulty"></ui5-card-header>
            <div style="padding: 1rem; text-align: center;">
              <ui5-title level="H1">{{ avgDifficulty() }}</ui5-title>
            </div>
          </ui5-card>
          <ui5-card>
            <ui5-card-header slot="header" title-text="Topics"></ui5-card-header>
            <div style="padding: 1rem; text-align: center;">
              <ui5-title level="H1">{{ topicCount() }}</ui5-title>
            </div>
          </ui5-card>
          <ui5-card>
            <ui5-card-header slot="header" title-text="Query Types"></ui5-card-header>
            <div style="padding: 1rem; text-align: center;">
              <ui5-title level="H1">{{ queryTypeCount() }}</ui5-title>
            </div>
          </ui5-card>
        </div>

        <!-- Difficulty Distribution Bar -->
        <div class="difficulty-bar-container">
          <span class="difficulty-bar-label">Difficulty Distribution</span>
          <div class="difficulty-bar">
            @if (easyPct() > 0) {
              <div class="difficulty-segment difficulty-segment--easy" [style.width.%]="easyPct()">
                <span class="difficulty-segment-text">{{ easyPct() }}%</span>
              </div>
            }
            @if (mediumPct() > 0) {
              <div class="difficulty-segment difficulty-segment--medium" [style.width.%]="mediumPct()">
                <span class="difficulty-segment-text">{{ mediumPct() }}%</span>
              </div>
            }
            @if (hardPct() > 0) {
              <div class="difficulty-segment difficulty-segment--hard" [style.width.%]="hardPct()">
                <span class="difficulty-segment-text">{{ hardPct() }}%</span>
              </div>
            }
          </div>
          <div class="difficulty-legend">
            <span class="difficulty-legend-item"><span class="difficulty-dot difficulty-dot--easy"></span> Easy ({{ easyCount() }})</span>
            <span class="difficulty-legend-item"><span class="difficulty-dot difficulty-dot--medium"></span> Medium ({{ mediumCount() }})</span>
            <span class="difficulty-legend-item"><span class="difficulty-dot difficulty-dot--hard"></span> Hard ({{ hardCount() }})</span>
          </div>
        </div>

        <!-- Search + Filter Chips -->
        <div class="pairs-controls">
          <ui5-input type="Text" placeholder="Search queries..." icon="search" [value]="pairSearch()" (input)="onSearchChange($any($event).target.value)" style="width: 260px;"></ui5-input>
          <ui5-segmented-button>
            <ui5-segmented-button-item [pressed]="difficultyFilter === ''" (click)="setDifficulty('')">All ({{ pairTotal() }})</ui5-segmented-button-item>
            <ui5-segmented-button-item [pressed]="difficultyFilter === 'easy'" (click)="setDifficulty('easy')">Easy ({{ easyCount() }})</ui5-segmented-button-item>
            <ui5-segmented-button-item [pressed]="difficultyFilter === 'medium'" (click)="setDifficulty('medium')">Medium ({{ mediumCount() }})</ui5-segmented-button-item>
            <ui5-segmented-button-item [pressed]="difficultyFilter === 'hard'" (click)="setDifficulty('hard')">Hard ({{ hardCount() }})</ui5-segmented-button-item>
          </ui5-segmented-button>
          @if (difficultyFilter || pairSearch()) {
            <ui5-button design="Transparent" icon="decline" (click)="clearAllFilters()">Clear all</ui5-button>
          }
        </div>

        @if (pairsLoading()) {
          <ui5-busy-indicator active size="L" style="width: 100%; min-height: 100px;"></ui5-busy-indicator>
        }

        <!-- Data Table -->
        @if (!pairsLoading() && pagedPairs().length) {
          <ui5-table>
            <ui5-table-header-row slot="headerRow">
              <ui5-table-header-cell><span class="sortable-th" (click)="toggleSort('id')">ID {{ sortIndicator('id') }}</span></ui5-table-header-cell>
              <ui5-table-header-cell><span class="sortable-th" (click)="toggleSort('difficulty')">Difficulty {{ sortIndicator('difficulty') }}</span></ui5-table-header-cell>
              <ui5-table-header-cell><span class="sortable-th" (click)="toggleSort('db_id')">Database {{ sortIndicator('db_id') }}</span></ui5-table-header-cell>
              <ui5-table-header-cell><span class="sortable-th" (click)="toggleSort('question')">Question {{ sortIndicator('question') }}</span></ui5-table-header-cell>
              <ui5-table-header-cell>SQL Query</ui5-table-header-cell>
            </ui5-table-header-row>
            @for (pair of pagedPairs(); track pair.id) {
              <ui5-table-row (click)="toggleRow(pair.id)">
                <ui5-table-cell><span class="cell-mono">{{ pair.id }}</span></ui5-table-cell>
                <ui5-table-cell>
                  <ui5-tag [design]="pair.difficulty === 'easy' ? 'Positive' : pair.difficulty === 'medium' ? 'Critical' : 'Negative'">{{ pair.difficulty }}</ui5-tag>
                </ui5-table-cell>
                <ui5-table-cell><ui5-tag design="Set2">{{ pair.db_id }}</ui5-tag></ui5-table-cell>
                <ui5-table-cell>{{ pair.question }}</ui5-table-cell>
                <ui5-table-cell><code class="sql-inline" [innerHTML]="highlightSql(pair.query)"></code></ui5-table-cell>
              </ui5-table-row>
              @if (expandedRow() === pair.id) {
                <ui5-table-row>
                  <ui5-table-cell colspan="5">
                    <div class="expanded-sql-block">
                      <div class="expanded-sql-header">
                        <span>Full SQL Query</span>
                        <ui5-tag [design]="pair.difficulty === 'easy' ? 'Positive' : pair.difficulty === 'medium' ? 'Critical' : 'Negative'">{{ pair.difficulty }}</ui5-tag>
                      </div>
                      <pre class="expanded-sql-code" [innerHTML]="highlightSql(pair.query)"></pre>
                    </div>
                  </ui5-table-cell>
                </ui5-table-row>
              }
            }
          </ui5-table>

          <!-- Pagination -->
          <div class="pagination-bar">
            <div class="pagination-info">
              Showing {{ pageStart() }}–{{ pageEnd() }} of {{ filteredPairsCount() }} records
            </div>
            <div class="pagination-controls">
              <span class="rows-label">Rows per page:</span>
              <ui5-select (change)="setPageSize(+$any($event).detail.selectedOption.value)">
                <ui5-option value="10" [selected]="pageSize() === 10">10</ui5-option>
                <ui5-option value="25" [selected]="pageSize() === 25">25</ui5-option>
                <ui5-option value="50" [selected]="pageSize() === 50">50</ui5-option>
              </ui5-select>
              <ui5-button design="Transparent" icon="navigation-left-arrow" [disabled]="currentPage() <= 1" (click)="prevPage()">Prev</ui5-button>
              <span class="page-num">Page {{ currentPage() }} of {{ totalPages() }}</span>
              <ui5-button design="Transparent" icon="navigation-right-arrow" icon-end [disabled]="currentPage() >= totalPages()" (click)="nextPage()">Next</ui5-button>
            </div>
          </div>
        }

        <!-- Empty State -->
        @if (!pagedPairs().length && !pairsLoading()) {
          <ui5-illustrated-message name="NoData">
            <ui5-button design="Emphasized" (click)="clearAllFilters()">Reset filters</ui5-button>
          </ui5-illustrated-message>
        }
      }

      </div>
    </ui5-page>
  `,
  styles: [`
    /* ── Layout ── */
    .filter-bar { display: flex; gap: 0.5rem; align-items: center; }
    .asset-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(280px, 1fr)); gap: 0.75rem; }
    .asset-card--active { outline: 2px solid var(--sapBrandColor, #0854a0); }
    .asset-meta { display: flex; gap: 0.375rem; align-items: center; flex-wrap: wrap; }
    .text-small { font-size: 0.75rem; }
    .text-muted { color: var(--sapContent_LabelColor, #6a6d70); }

    /* ── Detail Panel ── */
    .detail-header { display: flex; align-items: center; gap: 0.75rem; margin-bottom: 1rem; }
    .detail-icon { font-size: 1.5rem; }
    .info-table { width: 100%; border-collapse: collapse; font-size: 0.8125rem;
      td { padding: 0.3rem 0.5rem; border-bottom: 1px solid var(--sapList_BorderColor, #e4e4e4);
        &:first-child { color: var(--sapContent_LabelColor, #6a6d70); width: 30%; font-weight: 500; }
      }
      tr:last-child td { border-bottom: none; }
    }

    /* ── Stats Grid ── */
    .stats-grid { display: grid; grid-template-columns: repeat(2, 1fr); gap: 1rem; }
    @media (min-width: 1440px) {
      :host .stats-grid { grid-template-columns: repeat(4, 1fr) !important; }
    }

    /* ── Difficulty Distribution ── */
    .difficulty-bar-container {
      background: var(--sapTile_Background, #fff); border: 1px solid var(--sapTile_BorderColor, #e4e4e4);
      border-radius: 0.5rem; padding: 0.875rem 1rem;
    }
    .difficulty-bar-label { font-size: 0.75rem; font-weight: 600; color: var(--sapContent_LabelColor, #6a6d70); margin-bottom: 0.5rem; display: block; }
    .difficulty-bar {
      display: flex; height: 1.25rem; border-radius: 0.625rem; overflow: hidden; background: var(--sapBackgroundColor, #f5f5f5);
    }
    .difficulty-segment { display: flex; align-items: center; justify-content: center; transition: width 0.4s ease; }
    .difficulty-segment--easy { background: #4caf50; }
    .difficulty-segment--medium { background: #ff9800; }
    .difficulty-segment--hard { background: #f44336; }
    .difficulty-segment-text { font-size: 0.625rem; font-weight: 700; color: #fff; }
    .difficulty-legend { display: flex; gap: 1rem; margin-top: 0.5rem; font-size: 0.75rem; color: var(--sapContent_LabelColor, #6a6d70); }
    .difficulty-legend-item { display: flex; align-items: center; gap: 0.25rem; }
    .difficulty-dot { width: 0.5rem; height: 0.5rem; border-radius: 50%; display: inline-block; }
    .difficulty-dot--easy { background: #4caf50; }
    .difficulty-dot--medium { background: #ff9800; }
    .difficulty-dot--hard { background: #f44336; }

    /* ── Controls ── */
    .pairs-controls { display: flex; flex-wrap: wrap; gap: 0.75rem; align-items: center; }

    /* ── Table ── */
    .sortable-th { cursor: pointer; user-select: none; &:hover { color: var(--sapBrandColor, #0854a0); } }
    .cell-mono { font-family: 'SFMono-Regular', Consolas, monospace; font-size: 0.75rem; }

    /* ── SQL Syntax Highlighting ── */
    .sql-inline {
      font-family: 'SFMono-Regular', Consolas, monospace; font-size: 0.75rem;
      color: var(--sapTextColor, #32363a); background: none; white-space: nowrap;
      overflow: hidden; text-overflow: ellipsis; display: block; max-width: 320px;
    }
    :host ::ng-deep .sql-keyword { color: var(--sapBrandColor, #0854a0); font-weight: 600; }
    :host ::ng-deep .sql-string { color: #2e7d32; }
    :host ::ng-deep .sql-number { color: #e65100; }

    /* ── Expanded Row ── */
    .expanded-sql-block { padding: 1rem; }
    .expanded-sql-header {
      display: flex; align-items: center; justify-content: space-between; margin-bottom: 0.5rem;
      font-size: 0.75rem; font-weight: 600; color: var(--sapContent_LabelColor, #6a6d70);
    }
    .expanded-sql-code {
      margin: 0; padding: 0.875rem 1rem; background: #1e1e1e; color: #d4d4d4; border-radius: 0.375rem;
      font-family: 'SFMono-Regular', Consolas, monospace; font-size: 0.8rem;
      overflow-x: auto; white-space: pre-wrap; word-break: break-all; line-height: 1.5;
    }
    :host ::ng-deep .expanded-sql-code .sql-keyword { color: #569cd6; font-weight: 600; }
    :host ::ng-deep .expanded-sql-code .sql-string { color: #ce9178; }
    :host ::ng-deep .expanded-sql-code .sql-number { color: #b5cea8; }

    /* ── Pagination ── */
    .pagination-bar {
      display: flex; align-items: center; justify-content: space-between; padding: 0.75rem 1rem;
      font-size: 0.8125rem;
    }
    .pagination-info { color: var(--sapContent_LabelColor, #6a6d70); }
    .pagination-controls { display: flex; align-items: center; gap: 0.5rem; }
    .rows-label { color: var(--sapContent_LabelColor, #6a6d70); font-size: 0.75rem; }
    .page-num { font-size: 0.75rem; color: var(--sapContent_LabelColor, #6a6d70); min-width: 80px; text-align: center; }
  `],
})
export class DataExplorerComponent implements OnInit {
  private readonly http = inject(HttpClient);
  private readonly sanitizer = inject(DomSanitizer);

  searchTerm = '';
  filterCategory = '';
  difficultyFilter: Difficulty = '';
  readonly activeTab = signal<TabId>('assets');
  readonly selected = signal<DataAsset | null>(null);
  readonly pairs = signal<SqlPair[]>([]);
  readonly pairTotal = signal(0);
  readonly pairSource = signal('synthetic');
  readonly pairsLoading = signal(false);

  // Pairs tab: search, sort, pagination, expanded row
  readonly pairSearch = signal('');
  readonly sortField = signal<SortField>('id');
  readonly sortDir = signal<SortDir>('asc');
  readonly currentPage = signal(1);
  readonly pageSize = signal(10);
  readonly expandedRow = signal<string | null>(null);

  private searchTimer: ReturnType<typeof setTimeout> | null = null;

  readonly easyCount = computed(() => this.pairs().filter(p => p.difficulty === 'easy').length);
  readonly mediumCount = computed(() => this.pairs().filter(p => p.difficulty === 'medium').length);
  readonly hardCount = computed(() => this.pairs().filter(p => p.difficulty === 'hard').length);

  // Stats
  readonly avgDifficulty = computed(() => {
    const p = this.pairs();
    if (!p.length) return '—';
    const map: Record<string, number> = { easy: 1, medium: 2, hard: 3 };
    const avg = p.reduce((s, x) => s + (map[x.difficulty] || 2), 0) / p.length;
    return avg <= 1.5 ? 'Easy' : avg <= 2.5 ? 'Medium' : 'Hard';
  });
  readonly topicCount = computed(() => new Set(this.pairs().map(p => p.db_id)).size);
  readonly queryTypeCount = computed(() => {
    const types = new Set<string>();
    for (const p of this.pairs()) {
      const m = p.query.trim().match(/^(\w+)/i);
      if (m) types.add(m[1].toUpperCase());
    }
    return types.size || 1;
  });

  // Difficulty percentages
  readonly easyPct = computed(() => {
    const t = this.pairs().length;
    return t ? Math.round((this.easyCount() / t) * 100) : 0;
  });
  readonly mediumPct = computed(() => {
    const t = this.pairs().length;
    return t ? Math.round((this.mediumCount() / t) * 100) : 0;
  });
  readonly hardPct = computed(() => {
    const t = this.pairs().length;
    return t ? Math.round((this.hardCount() / t) * 100) : 0;
  });

  // Filtered + sorted pairs
  readonly filteredPairs = computed(() => {
    let list = this.pairs();
    const q = this.pairSearch().toLowerCase();
    if (q) {
      list = list.filter(p =>
        p.query.toLowerCase().includes(q) ||
        p.question.toLowerCase().includes(q) ||
        p.db_id.toLowerCase().includes(q) ||
        p.id.toLowerCase().includes(q)
      );
    }
    const field = this.sortField();
    const dir = this.sortDir() === 'asc' ? 1 : -1;
    return [...list].sort((a, b) => {
      const va = (a[field] || '').toLowerCase();
      const vb = (b[field] || '').toLowerCase();
      return va < vb ? -dir : va > vb ? dir : 0;
    });
  });

  readonly filteredPairsCount = computed(() => this.filteredPairs().length);
  readonly totalPages = computed(() => Math.max(1, Math.ceil(this.filteredPairsCount() / this.pageSize())));
  readonly pageStart = computed(() => Math.min((this.currentPage() - 1) * this.pageSize() + 1, this.filteredPairsCount()));
  readonly pageEnd = computed(() => Math.min(this.currentPage() * this.pageSize(), this.filteredPairsCount()));

  readonly pagedPairs = computed(() => {
    const start = (this.currentPage() - 1) * this.pageSize();
    return this.filteredPairs().slice(start, start + this.pageSize());
  });

  readonly assets: DataAsset[] = [
    { name: 'DATA_DICTIONARY.xlsx', type: 'xlsx', size: '225 KB', description: 'Master data dictionary for banking schemas', category: 'Reference' },
    { name: 'ESG_DATA_DICTIONARY.xlsx', type: 'xlsx', size: '238 KB', description: 'ESG-specific data dictionary', category: 'Reference' },
    { name: 'ESG_Prompt_samples.xlsx', type: 'xlsx', size: '12 KB', description: 'ESG prompt sample set', category: 'Prompts' },
    { name: 'NFRP_Account_AM.xlsx', type: 'xlsx', size: '76 KB', description: 'NFRP Account dimension (banking)', category: 'NFRP' },
    { name: 'NFRP_Cost_AM.xlsx', type: 'xlsx', size: '102 KB', description: 'NFRP Cost dimension', category: 'NFRP' },
    { name: 'NFRP_Location_AM.xlsx', type: 'xlsx', size: '91 KB', description: 'NFRP Location dimension', category: 'NFRP' },
    { name: 'NFRP_Product_AM.xlsx', type: 'xlsx', size: '68 KB', description: 'NFRP Product dimension', category: 'NFRP' },
    { name: 'NFRP_Segment_AM.xlsx', type: 'xlsx', size: '16 KB', description: 'NFRP Segment dimension', category: 'NFRP' },
    { name: 'Performance (BPC) - sample prompts.xlsx', type: 'xlsx', size: '14 KB', description: 'BPC performance prompt samples', category: 'Prompts' },
    { name: 'Performance CRD - Fact table.xlsx', type: 'xlsx', size: '12 KB', description: 'CRD fact table schema', category: 'Reference' },
    { name: 'Prompt_samples.xlsx', type: 'xlsx', size: '12 KB', description: 'General prompt samples', category: 'Prompts' },
    { name: '1_register.csv', type: 'csv', size: '116 KB', description: 'Stage 1: Schema register output', category: 'Pipeline Output' },
    { name: '2_stagingschema.csv', type: 'csv', size: '1.4 MB', description: 'Stage 2: Staging schema CSV', category: 'Pipeline Output' },
    { name: '2_stagingschema_logs.csv', type: 'csv', size: '1.1 MB', description: 'Stage 2: Staging schema logs', category: 'Pipeline Output' },
    { name: '2_stagingschema_nonstagingschema.csv', type: 'csv', size: '5.1 MB', description: 'Stage 2: Non-staging schema pairs', category: 'Pipeline Output' },
    { name: '3_validations.csv', type: 'csv', size: '1.7 KB', description: 'Stage 3: Validation results', category: 'Pipeline Output' },
  ];

  readonly categories = computed(() => [...new Set(this.assets.map(a => a.category))].sort());
  readonly filteredAssets = computed(() => this.assets.filter(a => {
    const matchSearch = !this.searchTerm || a.name.toLowerCase().includes(this.searchTerm.toLowerCase()) || a.description.toLowerCase().includes(this.searchTerm.toLowerCase());
    const matchCat = !this.filterCategory || a.category === this.filterCategory;
    return matchSearch && matchCat;
  }));
  readonly excelCount = computed(() => this.assets.filter(a => a.type === 'xlsx').length);
  readonly csvCount = computed(() => this.assets.filter(a => a.type === 'csv').length);
  readonly templateCount = computed(() => this.assets.filter(a => a.type === 'template').length);

  ngOnInit() {
    this.loadPairs();
  }

  setTab(tab: TabId) {
    this.activeTab.set(tab);
    if (tab === 'pairs') this.loadPairs();
  }

  loadPairs() {
    this.pairsLoading.set(true);
    const url = `${environment.apiBaseUrl}/data/preview${this.difficultyFilter ? '?difficulty=' + this.difficultyFilter : ''}`;
    this.http.get<{total: number, pairs: SqlPair[], source: string}>(url, {
      headers: { 'X-Skip-Error-Toast': 'true' }
    }).subscribe({
      next: (res) => {
        this.pairs.set(res.pairs);
        this.pairTotal.set(res.total);
        this.pairSource.set(res.source);
        this.pairsLoading.set(false);
      },
      error: () => this.pairsLoading.set(false)
    });
  }

  // --- Pairs tab methods ---

  onSearchChange(val: string) {
    if (this.searchTimer) clearTimeout(this.searchTimer);
    this.searchTimer = setTimeout(() => {
      this.pairSearch.set(val);
      this.currentPage.set(1);
    }, 250);
  }

  clearSearch() {
    this.pairSearch.set('');
    this.currentPage.set(1);
  }

  setDifficulty(d: Difficulty) {
    this.difficultyFilter = d;
    this.currentPage.set(1);
    this.loadPairs();
  }

  clearAllFilters() {
    this.pairSearch.set('');
    this.difficultyFilter = '';
    this.currentPage.set(1);
    this.loadPairs();
  }

  toggleSort(field: SortField) {
    if (this.sortField() === field) {
      this.sortDir.set(this.sortDir() === 'asc' ? 'desc' : 'asc');
    } else {
      this.sortField.set(field);
      this.sortDir.set('asc');
    }
  }

  sortIndicator(field: SortField): string {
    if (this.sortField() !== field) return '⇅';
    return this.sortDir() === 'asc' ? '▲' : '▼';
  }

  toggleRow(id: string) {
    this.expandedRow.set(this.expandedRow() === id ? null : id);
  }

  setPageSize(size: number) {
    this.pageSize.set(size);
    this.currentPage.set(1);
  }

  prevPage() {
    if (this.currentPage() > 1) this.currentPage.set(this.currentPage() - 1);
  }

  nextPage() {
    if (this.currentPage() < this.totalPages()) this.currentPage.set(this.currentPage() + 1);
  }

  highlightSql(sql: string): SafeHtml {
    const keywords = /\b(SELECT|FROM|WHERE|JOIN|LEFT|RIGHT|INNER|OUTER|CROSS|ON|AND|OR|NOT|IN|AS|GROUP\s+BY|ORDER\s+BY|HAVING|LIMIT|OFFSET|INSERT|UPDATE|DELETE|CREATE|DROP|ALTER|TABLE|INTO|VALUES|SET|DISTINCT|UNION|ALL|EXISTS|BETWEEN|LIKE|IS|NULL|COUNT|SUM|AVG|MIN|MAX|CASE|WHEN|THEN|ELSE|END|WITH|OVER|PARTITION|BY|ASC|DESC)\b/gi;
    const strings = /('(?:[^'\\]|\\.)*')/g;
    const numbers = /\b(\d+(?:\.\d+)?)\b/g;
    let result = sql
      .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
      .replace(strings, '<span class="sql-string">$1</span>')
      .replace(keywords, '<span class="sql-keyword">$1</span>')
      .replace(numbers, '<span class="sql-number">$1</span>');
    return this.sanitizer.bypassSecurityTrustHtml(result);
  }

  iconFor(type: AssetType): string {
    const icons: Record<AssetType, string> = { xlsx: '📊', csv: '📋', template: '📝' };
    return icons[type] ?? '📄';
  }

  select(a: DataAsset): void {
    this.selected.set(this.selected()?.name === a.name ? null : a);
  }

  clearSelection(): void {
    this.selected.set(null);
  }
}