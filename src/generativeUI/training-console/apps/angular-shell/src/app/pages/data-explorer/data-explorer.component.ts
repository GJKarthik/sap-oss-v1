import { Component, CUSTOM_ELEMENTS_SCHEMA, ChangeDetectionStrategy, signal, computed, inject, OnInit } from '@angular/core';
import { CommonModule } from '@angular/common';
import { FormsModule } from '@angular/forms';
import { HttpClient } from '@angular/common/http';
import { DomSanitizer, SafeHtml } from '@angular/platform-browser';
import { Ui5WebcomponentsModule } from '@ui5/webcomponents-ngx';
import '@ui5/webcomponents-icons/dist/AllIcons.js';
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
      </ui5-bar>

      <div style="padding: 1.5rem; display: flex; flex-direction: column; gap: 1.25rem;">
        <ui5-tabcontainer (tab-select)="onTabSelect($event)" fixed>
          <ui5-tab text="Data Assets" icon="folder-full" [selected]="activeTab() === 'assets'" data-tab-id="assets"></ui5-tab>
          <ui5-tab text="SQL Training Pairs" icon="search" [selected]="activeTab() === 'pairs'" data-tab-id="pairs"></ui5-tab>
        </ui5-tabcontainer>

        <!-- Tab: Data Assets -->
        @if (activeTab() === 'assets') {
          <div class="filter-bar">
            <ui5-input type="Text" placeholder="Filter assets…" [value]="searchTerm"
              (input)="searchTerm = $any($event).target.value" show-clear-icon>
              <ui5-icon slot="icon" name="search"></ui5-icon>
            </ui5-input>
            <ui5-select (change)="onCategoryChange($event)">
              <ui5-option value="" [selected]="!filterCategory">All categories</ui5-option>
              @for (c of categories(); track c) {
                <ui5-option [value]="c" [selected]="filterCategory === c">{{ c }}</ui5-option>
              }
            </ui5-select>
          </div>

          <div class="stats-grid">
            <ui5-card>
              <ui5-card-header slot="header" title-text="Total Assets" [subtitleText]="'' + assets.length"></ui5-card-header>
              <div class="stat-card-body">
                <ui5-title level="H1">{{ assets.length }}</ui5-title>
              </div>
            </ui5-card>
            <ui5-card>
              <ui5-card-header slot="header" title-text="Excel Files" [subtitleText]="'' + excelCount()"></ui5-card-header>
              <div class="stat-card-body">
                <ui5-title level="H1">{{ excelCount() }}</ui5-title>
              </div>
            </ui5-card>
            <ui5-card>
              <ui5-card-header slot="header" title-text="CSV Files" [subtitleText]="'' + csvCount()"></ui5-card-header>
              <div class="stat-card-body">
                <ui5-title level="H1">{{ csvCount() }}</ui5-title>
              </div>
            </ui5-card>
            <ui5-card>
              <ui5-card-header slot="header" title-text="Prompt Templates" [subtitleText]="'' + templateCount()"></ui5-card-header>
              <div class="stat-card-body">
                <ui5-title level="H1">{{ templateCount() }}</ui5-title>
              </div>
            </ui5-card>
          </div>

          <div class="asset-grid">
            @for (a of filteredAssets(); track a.name) {
              <ui5-card class="asset-card" [class.asset-card--active]="selected()?.name === a.name" (click)="select(a)">
                <ui5-card-header slot="header" [titleText]="a.name" [subtitleText]="a.description"></ui5-card-header>
                <div style="padding: 0.5rem 1rem 0.75rem; display: flex; gap: 0.375rem; align-items: center; flex-wrap: wrap;">
                  <ui5-tag design="Set2">{{ a.type.toUpperCase() }}</ui5-tag>
                  <ui5-tag>{{ a.category }}</ui5-tag>
                  <ui5-tag design="Set2">{{ a.size }}</ui5-tag>
                </div>
              </ui5-card>
            }
          </div>

          @if (!filteredAssets().length) {
            <ui5-illustrated-message name="NoData">
              <ui5-title slot="title" level="H5">No assets match your filter.</ui5-title>
            </ui5-illustrated-message>
          }

          @if (selected(); as sel) {
            <ui5-card>
              <ui5-card-header slot="header" [titleText]="sel.name" [subtitleText]="sel.type.toUpperCase()">
                <ui5-button slot="action" icon="decline" design="Transparent" (click)="clearSelection()"></ui5-button>
              </ui5-card-header>
              <div style="padding: 0;">
                <ui5-list>
                  <ui5-list-item-standard description="Type"><ui5-text>{{ sel.type.toUpperCase() }}</ui5-text></ui5-list-item-standard>
                  <ui5-list-item-standard description="Category"><ui5-text>{{ sel.category }}</ui5-text></ui5-list-item-standard>
                  <ui5-list-item-standard description="Size"><ui5-text>{{ sel.size }}</ui5-text></ui5-list-item-standard>
                  <ui5-list-item-standard description="Description"><ui5-text>{{ sel.description }}</ui5-text></ui5-list-item-standard>
                  <ui5-list-item-standard description="Location"><ui5-text>data/{{ sel.name }}</ui5-text></ui5-list-item-standard>
                </ui5-list>
              </div>
            </ui5-card>
          }
        }

        <!-- Tab: SQL Training Pairs -->
        @if (activeTab() === 'pairs') {
          <!-- Stats Cards -->
          <div class="stats-grid">
            <ui5-card>
              <ui5-card-header slot="header" title-text="Total Records" [subtitleText]="'' + pairTotal()"></ui5-card-header>
              <div class="stat-card-body">
                <ui5-icon name="bar-chart" style="font-size: 1.5rem; color: var(--sapContent_IconColor);"></ui5-icon>
                <ui5-title level="H1">{{ pairTotal() }}</ui5-title>
              </div>
            </ui5-card>
            <ui5-card>
              <ui5-card-header slot="header" title-text="Avg Difficulty" [subtitleText]="avgDifficulty()"></ui5-card-header>
              <div class="stat-card-body">
                <ui5-icon name="line-chart" style="font-size: 1.5rem; color: var(--sapContent_IconColor);"></ui5-icon>
                <ui5-title level="H1">{{ avgDifficulty() }}</ui5-title>
              </div>
            </ui5-card>
            <ui5-card>
              <ui5-card-header slot="header" title-text="Topics" [subtitleText]="'' + topicCount()"></ui5-card-header>
              <div class="stat-card-body">
                <ui5-icon name="tag" style="font-size: 1.5rem; color: var(--sapContent_IconColor);"></ui5-icon>
                <ui5-title level="H1">{{ topicCount() }}</ui5-title>
              </div>
            </ui5-card>
            <ui5-card>
              <ui5-card-header slot="header" title-text="Query Types" [subtitleText]="'' + queryTypeCount()"></ui5-card-header>
              <div class="stat-card-body">
                <ui5-icon name="electrocardiogram" style="font-size: 1.5rem; color: var(--sapContent_IconColor);"></ui5-icon>
                <ui5-title level="H1">{{ queryTypeCount() }}</ui5-title>
              </div>
            </ui5-card>
          </div>

          <!-- Difficulty Distribution Bar -->
          <ui5-card>
            <ui5-card-header slot="header" title-text="Difficulty Distribution"></ui5-card-header>
            <div style="padding: 0.875rem 1rem;">
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
          </ui5-card>

          <!-- Search + Filter -->
          <div class="pairs-controls">
            <ui5-input type="Text" placeholder="Search queries..." [value]="pairSearch()"
              (input)="onSearchChange($any($event).target.value)" show-clear-icon style="width: 260px;">
              <ui5-icon slot="icon" name="search"></ui5-icon>
            </ui5-input>
            <ui5-segmented-button (selection-change)="onDifficultySegmentChange($event)">
              <ui5-segmented-button-item [pressed]="difficultyFilter === ''" data-difficulty="">All ({{ pairTotal() }})</ui5-segmented-button-item>
              <ui5-segmented-button-item [pressed]="difficultyFilter === 'easy'" data-difficulty="easy">Easy ({{ easyCount() }})</ui5-segmented-button-item>
              <ui5-segmented-button-item [pressed]="difficultyFilter === 'medium'" data-difficulty="medium">Medium ({{ mediumCount() }})</ui5-segmented-button-item>
              <ui5-segmented-button-item [pressed]="difficultyFilter === 'hard'" data-difficulty="hard">Hard ({{ hardCount() }})</ui5-segmented-button-item>
            </ui5-segmented-button>
            @if (difficultyFilter || pairSearch()) {
              <ui5-button icon="decline" design="Transparent" (click)="clearAllFilters()">Clear all</ui5-button>
            }
          </div>

          @if (pairsLoading()) {
            <ui5-busy-indicator active size="L" style="width: 100%; min-height: 200px; display: flex; align-items: center; justify-content: center;">
            </ui5-busy-indicator>
          }

          <!-- Data Table -->
          @if (!pairsLoading() && pagedPairs().length) {
            <ui5-table>
              <ui5-table-header-row slot="headerRow">
                <ui5-table-header-cell (click)="toggleSort('id')" style="cursor: pointer;">
                  ID {{ sortIndicator('id') }}
                </ui5-table-header-cell>
                <ui5-table-header-cell (click)="toggleSort('difficulty')" style="cursor: pointer;">
                  Difficulty {{ sortIndicator('difficulty') }}
                </ui5-table-header-cell>
                <ui5-table-header-cell (click)="toggleSort('db_id')" style="cursor: pointer;">
                  Database {{ sortIndicator('db_id') }}
                </ui5-table-header-cell>
                <ui5-table-header-cell (click)="toggleSort('question')" style="cursor: pointer;">
                  Question {{ sortIndicator('question') }}
                </ui5-table-header-cell>
                <ui5-table-header-cell>SQL Query</ui5-table-header-cell>
              </ui5-table-header-row>
              @for (pair of pagedPairs(); track pair.id) {
                <ui5-table-row (click)="toggleRow(pair.id)" style="cursor: pointer;"
                  [class.row-expanded]="expandedRow() === pair.id">
                  <ui5-table-cell><code>{{ pair.id }}</code></ui5-table-cell>
                  <ui5-table-cell>
                    <ui5-tag [design]="difficultyDesign(pair.difficulty)">{{ pair.difficulty }}</ui5-tag>
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
                          <ui5-tag [design]="difficultyDesign(pair.difficulty)">{{ pair.difficulty }}</ui5-tag>
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
              <ui5-text>Showing {{ pageStart() }}–{{ pageEnd() }} of {{ filteredPairsCount() }} records</ui5-text>
              <div class="pagination-controls">
                <ui5-text style="font-size: 0.75rem;">Rows per page:</ui5-text>
                <ui5-select style="width: 70px;" (change)="onPageSizeChange($event)">
                  <ui5-option value="10" [selected]="pageSize() === 10">10</ui5-option>
                  <ui5-option value="25" [selected]="pageSize() === 25">25</ui5-option>
                  <ui5-option value="50" [selected]="pageSize() === 50">50</ui5-option>
                </ui5-select>
                <ui5-button icon="navigation-left-arrow" design="Transparent" [disabled]="currentPage() <= 1" (click)="prevPage()"></ui5-button>
                <ui5-text style="font-size: 0.75rem; min-width: 80px; text-align: center;">Page {{ currentPage() }} of {{ totalPages() }}</ui5-text>
                <ui5-button icon="navigation-right-arrow" design="Transparent" [disabled]="currentPage() >= totalPages()" (click)="nextPage()"></ui5-button>
              </div>
            </div>
          }

          <!-- Empty State -->
          @if (!pagedPairs().length && !pairsLoading()) {
            <ui5-illustrated-message name="NoData">
              <ui5-title slot="title" level="H5">No matching records</ui5-title>
              <ui5-text slot="subtitle">Try adjusting your search or filters</ui5-text>
              <ui5-button design="Emphasized" (click)="clearAllFilters()">Reset filters</ui5-button>
            </ui5-illustrated-message>
          }
        }
      </div>
    </ui5-page>
  `,
  styles: [`
    /* Layout */
    .filter-bar { display: flex; gap: 0.75rem; align-items: center; }
    .stats-grid {
      display: grid; grid-template-columns: repeat(2, 1fr); gap: 1rem;
    }
    @media (min-width: 1024px) {
      :host .stats-grid { grid-template-columns: repeat(4, 1fr); }
    }
    .stat-card-body {
      padding: 1rem; text-align: center; display: flex; flex-direction: column; align-items: center; gap: 0.5rem;
    }
    .asset-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(280px, 1fr)); gap: 0.75rem; }
    .asset-card { cursor: pointer; }
    .asset-card--active { box-shadow: 0 0 0 2px var(--sapBrandColor, #0854a0); }

    /* Difficulty Distribution */
    .difficulty-bar {
      display: flex; height: 1.25rem; border-radius: 0.625rem; overflow: hidden; background: var(--sapBackgroundColor, #f5f5f5);
    }
    .difficulty-segment {
      display: flex; align-items: center; justify-content: center; transition: width 0.4s ease;
    }
    .difficulty-segment--easy { background: #4caf50; }
    .difficulty-segment--medium { background: #ff9800; }
    .difficulty-segment--hard { background: #f44336; }
    .difficulty-segment-text { font-size: 0.625rem; font-weight: 700; color: #fff; }
    .difficulty-legend {
      display: flex; gap: 1rem; margin-top: 0.5rem; font-size: 0.75rem; color: var(--sapContent_LabelColor, #6a6d70);
    }
    .difficulty-legend-item { display: flex; align-items: center; gap: 0.25rem; }
    .difficulty-dot { width: 0.5rem; height: 0.5rem; border-radius: 50%; display: inline-block; }
    .difficulty-dot--easy { background: #4caf50; }
    .difficulty-dot--medium { background: #ff9800; }
    .difficulty-dot--hard { background: #f44336; }

    /* Controls */
    .pairs-controls {
      display: flex; flex-wrap: wrap; gap: 0.75rem; align-items: center;
    }

    /* SQL Syntax Highlighting */
    .sql-inline {
      font-family: 'SFMono-Regular', Consolas, monospace; font-size: 0.75rem;
      color: var(--sapTextColor, #32363a); background: none; white-space: nowrap;
      overflow: hidden; text-overflow: ellipsis; display: block; max-width: 320px;
    }
    :host ::ng-deep .sql-keyword { color: var(--sapBrandColor, #0854a0); font-weight: 600; }
    :host ::ng-deep .sql-string { color: #2e7d32; }
    :host ::ng-deep .sql-number { color: #e65100; }

    /* Expanded Row */
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

    /* Pagination */
    .pagination-bar {
      display: flex; align-items: center; justify-content: space-between; padding: 0.75rem 1rem;
      background: var(--sapTile_Background, #fff); border: 1px solid var(--sapTile_BorderColor, #e4e4e4);
      border-top: none; border-radius: 0 0 0.5rem 0.5rem; font-size: 0.8125rem;
    }
    .pagination-controls { display: flex; align-items: center; gap: 0.5rem; }
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

  onTabSelect(event: any) {
    const tab = event?.detail?.tab;
    const tabId = tab?.getAttribute?.('data-tab-id') as TabId;
    if (tabId) this.setTab(tabId);
  }

  onCategoryChange(event: any) {
    const val = event?.detail?.selectedOption?.getAttribute?.('value') ?? '';
    this.filterCategory = val;
  }

  onDifficultySegmentChange(event: any) {
    const item = event?.detail?.selectedItem;
    const d = item?.getAttribute?.('data-difficulty') as Difficulty ?? '';
    this.setDifficulty(d);
  }

  onPageSizeChange(event: any) {
    const val = event?.detail?.selectedOption?.getAttribute?.('value');
    if (val) this.setPageSize(Number(val));
  }

  difficultyDesign(difficulty: string): string {
    switch (difficulty) {
      case 'easy': return 'Positive';
      case 'medium': return 'Critical';
      case 'hard': return 'Negative';
      default: return 'Set2';
    }
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