import { Component, CUSTOM_ELEMENTS_SCHEMA, ChangeDetectionStrategy, signal, computed, inject, OnInit } from '@angular/core';
import { CommonModule } from '@angular/common';
import { FormsModule } from '@angular/forms';
import { HttpClient } from '@angular/common/http';
import { environment } from '../../../environments/environment';

type AssetType = 'xlsx' | 'csv' | 'template';
type TabId = 'assets' | 'pairs';
type Difficulty = '' | 'easy' | 'medium' | 'hard';

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
  imports: [CommonModule, FormsModule],
  schemas: [CUSTOM_ELEMENTS_SCHEMA],
  changeDetection: ChangeDetectionStrategy.OnPush,
  template: `
    <div class="page-content">
      <div class="page-header">
        <h1 class="page-title">Data Explorer</h1>
        <div class="tab-bar">
          <button class="tab-btn" [class.active]="activeTab() === 'assets'" (click)="setTab('assets')">📂 Data Assets</button>
          <button class="tab-btn" [class.active]="activeTab() === 'pairs'" (click)="setTab('pairs')">🔍 SQL Training Pairs</button>
        </div>
      </div>

      <!-- Tab: Data Assets -->
      @if (activeTab() === 'assets') {
        <div class="filter-bar" style="margin-bottom: 1rem;">
          <input class="search-input" [(ngModel)]="searchTerm" placeholder="Filter assets…" />
          <select class="filter-select" [(ngModel)]="filterCategory">
            <option value="">All categories</option>
            @for (c of categories(); track c) {
              <option [value]="c">{{ c }}</option>
            }
          </select>
        </div>

        <div class="stats-grid" style="margin-bottom:1.5rem">
          <div class="stat-card">
            <div class="stat-value">{{ assets.length }}</div>
            <div class="stat-label">Total Assets</div>
          </div>
          <div class="stat-card">
            <div class="stat-value">{{ excelCount() }}</div>
            <div class="stat-label">Excel Files</div>
          </div>
          <div class="stat-card">
            <div class="stat-value">{{ csvCount() }}</div>
            <div class="stat-label">CSV Files</div>
          </div>
          <div class="stat-card">
            <div class="stat-value">{{ templateCount() }}</div>
            <div class="stat-label">Prompt Templates</div>
          </div>
        </div>

        <div class="asset-grid">
          @for (a of filteredAssets(); track a.name) {
            <div class="asset-card" (click)="select(a)" [class.asset-card--active]="selected()?.name === a.name">
              <div class="asset-icon">{{ iconFor(a.type) }}</div>
              <div class="asset-info">
                <div class="asset-name">{{ a.name }}</div>
                <div class="asset-desc text-muted text-small">{{ a.description }}</div>
                <div class="asset-meta">
                  <span class="badge badge--{{ a.type }}">{{ a.type.toUpperCase() }}</span>
                  <span class="badge">{{ a.category }}</span>
                  <span class="text-small text-muted">{{ a.size }}</span>
                </div>
              </div>
            </div>
          }
        </div>

        @if (!filteredAssets().length) {
          <p class="text-muted text-small">No assets match your filter.</p>
        }

        @if (selected(); as sel) {
          <div class="detail-panel">
            <div class="detail-header">
              <span class="detail-icon">{{ iconFor(sel.type) }}</span>
              <h2 class="detail-title">{{ sel.name }}</h2>
              <button class="close-btn" (click)="clearSelection()">✕</button>
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
        }
      }

      <!-- Tab: SQL Training Pairs (Human-in-the-loop audit) -->
      @if (activeTab() === 'pairs') {
        <div class="pairs-toolbar">
          <div class="stats-grid" style="margin-bottom: 1rem;">
            <div class="stat-card">
              <div class="stat-value">{{ pairTotal() }}</div>
              <div class="stat-label">Total Pairs</div>
            </div>
            <div class="stat-card">
              <div class="stat-value" style="color: #4caf50;">{{ easyCount() }}</div>
              <div class="stat-label">Easy</div>
            </div>
            <div class="stat-card">
              <div class="stat-value" style="color: #ff9800;">{{ mediumCount() }}</div>
              <div class="stat-label">Medium</div>
            </div>
            <div class="stat-card">
              <div class="stat-value" style="color: #f44336;">{{ hardCount() }}</div>
              <div class="stat-label">Hard</div>
            </div>
          </div>

          <div style="display: flex; gap: 0.75rem; align-items: center; margin-bottom: 1rem;">
            <label style="font-size: 0.875rem; font-weight: 600;">Filter Difficulty:</label>
            <select class="filter-select" [(ngModel)]="difficultyFilter" (ngModelChange)="loadPairs()">
              <option value="">All</option>
              <option value="easy">Easy</option>
              <option value="medium">Medium</option>
              <option value="hard">Hard</option>
            </select>
            <span class="text-small text-muted">Source: {{ pairSource() }}</span>
          </div>
        </div>

        @if (pairsLoading()) {
          <p class="text-muted text-small">Loading SQL pairs from the pipeline…</p>
        }

        <div class="pairs-list">
          @for (pair of pairs(); track pair.id) {
            <div class="pair-card">
              <div class="pair-header">
                <span class="pair-id text-small text-muted">#{{ pair.id }}</span>
                <span class="badge badge--{{ pair.difficulty }}">{{ pair.difficulty }}</span>
                <span class="badge" style="background: #e8eaf6; color: #283593;">{{ pair.db_id }}</span>
              </div>
              <p class="pair-question">{{ pair.question }}</p>
              <pre class="pair-sql">{{ pair.query }}</pre>
            </div>
          }
        </div>

        @if (!pairs().length && !pairsLoading()) {
          <div style="text-align: center; padding: 3rem; color: #999;">
            <div style="font-size: 2rem; margin-bottom: 0.5rem;">🗄</div>
            <p>No training pairs found. Run the Pipeline first.</p>
          </div>
        }
      }
    </div>
  `,
  styles: [`
    .tab-bar { display: flex; gap: 0.5rem; }
    .tab-btn {
      padding: 0.375rem 0.875rem; border-radius: 0.25rem; cursor: pointer; font-size: 0.875rem;
      border: 1px solid var(--sapField_BorderColor, #89919a); background: transparent; color: var(--sapTextColor, #32363a);
      &.active { background: var(--sapBrandColor, #0854a0); color: #fff; border-color: var(--sapBrandColor); font-weight: 600; }
      &:hover:not(.active) { background: var(--sapList_Hover_Background, #f5f5f5); }
    }
    .filter-bar { display: flex; gap: 0.5rem; align-items: center; }
    .search-input, .filter-select {
      padding: 0.375rem 0.625rem; border: 1px solid var(--sapField_BorderColor, #89919a);
      border-radius: 0.25rem; font-size: 0.875rem; background: var(--sapField_Background, #fff); color: var(--sapTextColor, #32363a);
    }
    .search-input { width: 200px; }
    .asset-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(280px, 1fr)); gap: 0.75rem; margin-bottom: 1.5rem; }
    .asset-card {
      display: flex; gap: 0.75rem; background: var(--sapTile_Background, #fff);
      border: 1px solid var(--sapTile_BorderColor, #e4e4e4); border-radius: 0.5rem; padding: 0.875rem;
      cursor: pointer; transition: border-color 0.12s;
      &:hover { border-color: var(--sapBrandColor, #0854a0); }
      &.asset-card--active { border-color: var(--sapBrandColor, #0854a0); box-shadow: 0 0 0 2px rgba(8, 84, 160, 0.15); }
    }
    .asset-icon { font-size: 1.5rem; flex-shrink: 0; }
    .asset-info { display: flex; flex-direction: column; gap: 0.3rem; min-width: 0; }
    .asset-name { font-size: 0.8125rem; font-weight: 600; color: var(--sapTextColor, #32363a); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
    .asset-meta { display: flex; gap: 0.375rem; align-items: center; flex-wrap: wrap; }
    .badge {
      padding: 0.1rem 0.4rem; background: var(--sapList_Background, #f5f5f5); border-radius: 0.25rem;
      font-size: 0.7rem; color: var(--sapContent_LabelColor, #6a6d70);
      &.badge--xlsx { background: #e8f5e9; color: #2e7d32; }
      &.badge--csv  { background: #e3f2fd; color: #1565c0; }
      &.badge--template { background: #fff3e0; color: #e65100; }
      &.badge--easy { background: #e8f5e9; color: #2e7d32; }
      &.badge--medium { background: #fff8e1; color: #f57f17; }
      &.badge--hard { background: #ffebee; color: #c62828; }
    }
    .detail-panel { background: var(--sapTile_Background, #fff); border: 1px solid var(--sapTile_BorderColor, #e4e4e4); border-radius: 0.5rem; padding: 1.25rem; margin-top: 1rem; }
    .detail-header { display: flex; align-items: center; gap: 0.75rem; margin-bottom: 1rem; }
    .detail-icon { font-size: 1.5rem; }
    .detail-title { flex: 1; font-size: 0.9375rem; font-weight: 600; margin: 0; }
    .close-btn { background: transparent; border: none; cursor: pointer; font-size: 1rem; color: var(--sapContent_LabelColor, #6a6d70); padding: 0.25rem; }
    .info-table { width: 100%; border-collapse: collapse; font-size: 0.8125rem;
      td { padding: 0.3rem 0.5rem; border-bottom: 1px solid var(--sapList_BorderColor, #e4e4e4);
        &:first-child { color: var(--sapContent_LabelColor, #6a6d70); width: 30%; font-weight: 500; }
      }
      tr:last-child td { border-bottom: none; }
    }
    /* SQL Pairs */
    .pairs-list { display: flex; flex-direction: column; gap: 1rem; }
    .pair-card { background: #fff; border: 1px solid #e4e4e4; border-radius: 0.5rem; overflow: hidden; }
    .pair-header { display: flex; align-items: center; gap: 0.5rem; padding: 0.75rem 1rem; background: #fafafa; border-bottom: 1px solid #e4e4e4; }
    .pair-id { font-family: monospace; }
    .pair-question { margin: 0.75rem 1rem 0.5rem; font-size: 0.875rem; color: #333; font-weight: 500; }
    .pair-sql {
      margin: 0; padding: 0.75rem 1rem; background: #1e1e1e; color: #9cdcfe; font-size: 0.8rem;
      font-family: 'SFMono-Regular', Consolas, monospace; overflow-x: auto; white-space: pre-wrap; word-break: break-all;
    }
  `],
})
export class DataExplorerComponent implements OnInit {
  private readonly http = inject(HttpClient);

  searchTerm = '';
  filterCategory = '';
  difficultyFilter: Difficulty = '';
  readonly activeTab = signal<TabId>('assets');
  readonly selected = signal<DataAsset | null>(null);
  readonly pairs = signal<SqlPair[]>([]);
  readonly pairTotal = signal(0);
  readonly pairSource = signal('synthetic');
  readonly pairsLoading = signal(false);

  readonly easyCount = computed(() => this.pairs().filter(p => p.difficulty === 'easy').length);
  readonly mediumCount = computed(() => this.pairs().filter(p => p.difficulty === 'medium').length);
  readonly hardCount = computed(() => this.pairs().filter(p => p.difficulty === 'hard').length);

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