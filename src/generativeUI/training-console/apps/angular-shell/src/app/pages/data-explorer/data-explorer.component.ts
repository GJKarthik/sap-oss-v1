import { Component, CUSTOM_ELEMENTS_SCHEMA, ChangeDetectionStrategy, signal, computed, inject, OnInit } from '@angular/core';
import { CommonModule } from '@angular/common';
import { FormsModule } from '@angular/forms';
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

      <!-- Tab: SQL Training Pairs -->
      @if (activeTab() === 'pairs') {
        <!-- Stats Cards -->
        <div class="pairs-stats-row">
          <div class="pairs-stat-card">
            <div class="pairs-stat-icon">📊</div>
            <div class="pairs-stat-body">
              <div class="pairs-stat-value">{{ pairTotal() }}</div>
              <div class="pairs-stat-label">Total Records</div>
            </div>
          </div>
          <div class="pairs-stat-card">
            <div class="pairs-stat-icon">📈</div>
            <div class="pairs-stat-body">
              <div class="pairs-stat-value">{{ avgDifficulty() }}</div>
              <div class="pairs-stat-label">Avg Difficulty</div>
            </div>
          </div>
          <div class="pairs-stat-card">
            <div class="pairs-stat-icon">🏷️</div>
            <div class="pairs-stat-body">
              <div class="pairs-stat-value">{{ topicCount() }}</div>
              <div class="pairs-stat-label">Topics</div>
            </div>
          </div>
          <div class="pairs-stat-card">
            <div class="pairs-stat-icon">⚡</div>
            <div class="pairs-stat-body">
              <div class="pairs-stat-value">{{ queryTypeCount() }}</div>
              <div class="pairs-stat-label">Query Types</div>
            </div>
          </div>
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
          <div class="search-wrap">
            <span class="search-icon">🔍</span>
            <input class="pairs-search" [ngModel]="pairSearch()" (ngModelChange)="onSearchChange($event)" placeholder="Search queries..." />
            @if (pairSearch()) {
              <button class="search-clear" (click)="clearSearch()">×</button>
            }
          </div>
          <div class="chip-group">
            <button class="chip" [class.chip--active]="difficultyFilter === ''" (click)="setDifficulty('')">
              All <span class="chip-count">{{ pairTotal() }}</span>
            </button>
            <button class="chip chip--easy" [class.chip--active]="difficultyFilter === 'easy'" (click)="setDifficulty('easy')">
              Easy <span class="chip-count">{{ easyCount() }}</span>
            </button>
            <button class="chip chip--medium" [class.chip--active]="difficultyFilter === 'medium'" (click)="setDifficulty('medium')">
              Medium <span class="chip-count">{{ mediumCount() }}</span>
            </button>
            <button class="chip chip--hard" [class.chip--active]="difficultyFilter === 'hard'" (click)="setDifficulty('hard')">
              Hard <span class="chip-count">{{ hardCount() }}</span>
            </button>
            @if (difficultyFilter || pairSearch()) {
              <button class="chip chip--clear" (click)="clearAllFilters()">✕ Clear all</button>
            }
          </div>
        </div>

        @if (pairsLoading()) {
          <div class="loading-indicator">
            <div class="loading-spinner"></div>
            <span>Loading SQL pairs from the pipeline…</span>
          </div>
        }

        <!-- Data Table -->
        @if (!pairsLoading() && pagedPairs().length) {
          <div class="table-container">
            <table class="data-table">
              <thead>
                <tr>
                  <th class="col-id" (click)="toggleSort('id')">
                    ID <span class="sort-indicator">{{ sortIndicator('id') }}</span>
                  </th>
                  <th class="col-difficulty" (click)="toggleSort('difficulty')">
                    Difficulty <span class="sort-indicator">{{ sortIndicator('difficulty') }}</span>
                  </th>
                  <th class="col-db" (click)="toggleSort('db_id')">
                    Database <span class="sort-indicator">{{ sortIndicator('db_id') }}</span>
                  </th>
                  <th class="col-question" (click)="toggleSort('question')">
                    Question <span class="sort-indicator">{{ sortIndicator('question') }}</span>
                  </th>
                  <th class="col-query">SQL Query</th>
                </tr>
              </thead>
              <tbody>
                @for (pair of pagedPairs(); track pair.id; let i = $index) {
                  <tr [class.row-alt]="i % 2 === 1" [class.row-expanded]="expandedRow() === pair.id" (click)="toggleRow(pair.id)">
                    <td class="col-id cell-mono">{{ pair.id }}</td>
                    <td class="col-difficulty">
                      <span class="difficulty-pill difficulty-pill--{{ pair.difficulty }}">{{ pair.difficulty }}</span>
                    </td>
                    <td class="col-db"><span class="db-badge">{{ pair.db_id }}</span></td>
                    <td class="col-question">{{ pair.question }}</td>
                    <td class="col-query"><code class="sql-inline" [innerHTML]="highlightSql(pair.query)"></code></td>
                  </tr>
                  @if (expandedRow() === pair.id) {
                    <tr class="expanded-detail-row">
                      <td colspan="5">
                        <div class="expanded-sql-block">
                          <div class="expanded-sql-header">
                            <span>Full SQL Query</span>
                            <span class="badge badge--{{ pair.difficulty }}">{{ pair.difficulty }}</span>
                          </div>
                          <pre class="expanded-sql-code" [innerHTML]="highlightSql(pair.query)"></pre>
                        </div>
                      </td>
                    </tr>
                  }
                }
              </tbody>
            </table>
          </div>

          <!-- Pagination -->
          <div class="pagination-bar">
            <div class="pagination-info">
              Showing {{ pageStart() }}–{{ pageEnd() }} of {{ filteredPairsCount() }} records
            </div>
            <div class="pagination-controls">
              <label class="rows-label">Rows per page:</label>
              <select class="rows-select" [ngModel]="pageSize()" (ngModelChange)="setPageSize($event)">
                <option [ngValue]="10">10</option>
                <option [ngValue]="25">25</option>
                <option [ngValue]="50">50</option>
              </select>
              <button class="page-btn" [disabled]="currentPage() <= 1" (click)="prevPage()">‹ Prev</button>
              <span class="page-num">Page {{ currentPage() }} of {{ totalPages() }}</span>
              <button class="page-btn" [disabled]="currentPage() >= totalPages()" (click)="nextPage()">Next ›</button>
            </div>
          </div>
        }

        <!-- Empty State -->
        @if (!pagedPairs().length && !pairsLoading()) {
          <div class="empty-state">
            <div class="empty-state-icon">
              <svg width="64" height="64" viewBox="0 0 64 64" fill="none">
                <rect x="8" y="12" width="48" height="40" rx="4" stroke="#c4c4c4" stroke-width="2" fill="#f5f5f5"/>
                <line x1="16" y1="24" x2="48" y2="24" stroke="#d9d9d9" stroke-width="2"/>
                <line x1="16" y1="32" x2="48" y2="32" stroke="#d9d9d9" stroke-width="2"/>
                <line x1="16" y1="40" x2="38" y2="40" stroke="#d9d9d9" stroke-width="2"/>
                <circle cx="48" cy="48" r="12" fill="#fff" stroke="#c4c4c4" stroke-width="2"/>
                <line x1="44" y1="48" x2="52" y2="48" stroke="#c4c4c4" stroke-width="2" stroke-linecap="round"/>
              </svg>
            </div>
            <h3 class="empty-state-title">No matching records</h3>
            <p class="empty-state-subtitle">Try adjusting your search or filters</p>
            <button class="empty-state-btn" (click)="clearAllFilters()">Reset filters</button>
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

    /* === SQL Pairs Tab === */

    /* Stats Cards */
    .pairs-stats-row {
      display: grid; grid-template-columns: repeat(4, 1fr); gap: 0.75rem; margin-bottom: 1.25rem;
    }
    .pairs-stat-card {
      display: flex; align-items: center; gap: 0.75rem;
      background: var(--sapTile_Background, #fff); border: 1px solid var(--sapTile_BorderColor, #e4e4e4);
      border-radius: 0.5rem; padding: 0.875rem 1rem;
    }
    .pairs-stat-icon { font-size: 1.5rem; }
    .pairs-stat-body { display: flex; flex-direction: column; }
    .pairs-stat-value { font-size: 1.25rem; font-weight: 700; color: var(--sapTextColor, #32363a); }
    .pairs-stat-label { font-size: 0.75rem; color: var(--sapContent_LabelColor, #6a6d70); }

    /* Difficulty Distribution */
    .difficulty-bar-container {
      background: var(--sapTile_Background, #fff); border: 1px solid var(--sapTile_BorderColor, #e4e4e4);
      border-radius: 0.5rem; padding: 0.875rem 1rem; margin-bottom: 1rem;
    }
    .difficulty-bar-label { font-size: 0.75rem; font-weight: 600; color: var(--sapContent_LabelColor, #6a6d70); margin-bottom: 0.5rem; display: block; }
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
    .difficulty-dot {
      width: 0.5rem; height: 0.5rem; border-radius: 50%; display: inline-block;
    }
    .difficulty-dot--easy { background: #4caf50; }
    .difficulty-dot--medium { background: #ff9800; }
    .difficulty-dot--hard { background: #f44336; }

    /* Search + Filter Chips */
    .pairs-controls {
      display: flex; flex-wrap: wrap; gap: 0.75rem; align-items: center; margin-bottom: 1rem;
    }
    .search-wrap {
      position: relative; display: flex; align-items: center;
    }
    .search-icon {
      position: absolute; left: 0.5rem; font-size: 0.875rem; pointer-events: none; opacity: 0.5;
    }
    .pairs-search {
      padding: 0.5rem 2rem 0.5rem 1.75rem; border: 1px solid var(--sapField_BorderColor, #89919a);
      border-radius: 1rem; font-size: 0.8125rem; width: 240px;
      background: var(--sapField_Background, #fff); color: var(--sapTextColor, #32363a);
      transition: border-color 0.15s, box-shadow 0.15s;
      &:focus { outline: none; border-color: var(--sapBrandColor, #0854a0); box-shadow: 0 0 0 2px rgba(8, 84, 160, 0.12); }
    }
    .search-clear {
      position: absolute; right: 0.5rem; background: none; border: none; cursor: pointer;
      font-size: 1rem; color: var(--sapContent_LabelColor, #6a6d70); line-height: 1;
      &:hover { color: var(--sapTextColor, #32363a); }
    }
    .chip-group { display: flex; gap: 0.375rem; flex-wrap: wrap; }
    .chip {
      display: inline-flex; align-items: center; gap: 0.25rem;
      padding: 0.3rem 0.75rem; border-radius: 1rem; font-size: 0.75rem; font-weight: 500;
      border: 1px solid var(--sapTile_BorderColor, #e4e4e4); background: var(--sapTile_Background, #fff);
      color: var(--sapTextColor, #32363a); cursor: pointer; transition: all 0.15s;
      &:hover { border-color: var(--sapBrandColor, #0854a0); }
      &.chip--active { background: var(--sapBrandColor, #0854a0); color: #fff; border-color: var(--sapBrandColor, #0854a0); }
    }
    .chip--easy.chip--active { background: #4caf50; border-color: #4caf50; }
    .chip--medium.chip--active { background: #ff9800; border-color: #ff9800; }
    .chip--hard.chip--active { background: #f44336; border-color: #f44336; }
    .chip--clear {
      background: none; border: 1px dashed var(--sapContent_LabelColor, #6a6d70); color: var(--sapContent_LabelColor, #6a6d70);
      &:hover { color: var(--sapTextColor, #32363a); border-color: var(--sapTextColor, #32363a); }
    }
    .chip-count {
      background: rgba(0,0,0,0.08); border-radius: 0.5rem; padding: 0 0.35rem; font-size: 0.6875rem;
    }
    .chip--active .chip-count { background: rgba(255,255,255,0.25); }

    /* Loading */
    .loading-indicator {
      display: flex; align-items: center; gap: 0.75rem; padding: 2rem; justify-content: center;
      color: var(--sapContent_LabelColor, #6a6d70); font-size: 0.875rem;
    }
    .loading-spinner {
      width: 1.25rem; height: 1.25rem; border: 2px solid var(--sapTile_BorderColor, #e4e4e4);
      border-top-color: var(--sapBrandColor, #0854a0); border-radius: 50%;
      animation: spin 0.8s linear infinite;
    }
    @keyframes spin { to { transform: rotate(360deg); } }

    /* Data Table */
    .table-container {
      background: var(--sapTile_Background, #fff); border: 1px solid var(--sapTile_BorderColor, #e4e4e4);
      border-radius: 0.5rem; overflow: hidden;
    }
    .data-table {
      width: 100%; border-collapse: collapse; font-size: 0.8125rem;
    }
    .data-table thead {
      position: sticky; top: 0; z-index: 1;
    }
    .data-table th {
      background: var(--sapBackgroundColor, #f5f5f5); color: var(--sapContent_LabelColor, #6a6d70);
      font-weight: 600; font-size: 0.75rem; text-transform: uppercase; letter-spacing: 0.03em;
      padding: 0.625rem 0.75rem; text-align: left; border-bottom: 2px solid var(--sapTile_BorderColor, #e4e4e4);
      cursor: pointer; user-select: none; white-space: nowrap;
      &:hover { color: var(--sapTextColor, #32363a); }
    }
    .data-table td {
      padding: 0.625rem 0.75rem; border-bottom: 1px solid var(--sapTile_BorderColor, #e4e4e4);
      vertical-align: top; color: var(--sapTextColor, #32363a);
    }
    .data-table tbody tr {
      transition: background 0.1s;
      cursor: pointer;
      &:hover { background: var(--sapList_Hover_Background, #f5f5f5); }
      &.row-alt { background: rgba(0,0,0,0.015); }
      &.row-alt:hover { background: var(--sapList_Hover_Background, #f5f5f5); }
      &.row-expanded { background: var(--sapList_SelectionBackgroundColor, #e8f2ff); }
    }
    .sort-indicator { font-size: 0.625rem; margin-left: 0.25rem; opacity: 0.5; }
    .col-id { width: 60px; }
    .col-difficulty { width: 90px; }
    .col-db { width: 120px; }
    .col-question { width: 35%; }
    .col-query { min-width: 200px; }
    .cell-mono { font-family: 'SFMono-Regular', Consolas, monospace; font-size: 0.75rem; }
    .difficulty-pill {
      display: inline-block; padding: 0.125rem 0.5rem; border-radius: 1rem; font-size: 0.6875rem;
      font-weight: 600; text-transform: capitalize;
    }
    .difficulty-pill--easy { background: #e8f5e9; color: #2e7d32; }
    .difficulty-pill--medium { background: #fff8e1; color: #f57f17; }
    .difficulty-pill--hard { background: #ffebee; color: #c62828; }
    .db-badge {
      display: inline-block; padding: 0.125rem 0.5rem; border-radius: 0.25rem;
      background: #e8eaf6; color: #283593; font-size: 0.6875rem; font-weight: 500;
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
    .expanded-detail-row td { padding: 0; background: var(--sapBackgroundColor, #f5f5f5); }
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
    .pagination-info { color: var(--sapContent_LabelColor, #6a6d70); }
    .pagination-controls { display: flex; align-items: center; gap: 0.5rem; }
    .rows-label { color: var(--sapContent_LabelColor, #6a6d70); font-size: 0.75rem; }
    .rows-select {
      padding: 0.25rem 0.375rem; border: 1px solid var(--sapField_BorderColor, #89919a);
      border-radius: 0.25rem; font-size: 0.75rem; background: var(--sapField_Background, #fff);
    }
    .page-btn {
      padding: 0.3rem 0.625rem; border: 1px solid var(--sapField_BorderColor, #89919a);
      border-radius: 0.25rem; background: var(--sapTile_Background, #fff); color: var(--sapTextColor, #32363a);
      cursor: pointer; font-size: 0.75rem; transition: all 0.12s;
      &:hover:not(:disabled) { background: var(--sapList_Hover_Background, #f5f5f5); border-color: var(--sapBrandColor, #0854a0); }
      &:disabled { opacity: 0.4; cursor: default; }
    }
    .page-num { font-size: 0.75rem; color: var(--sapContent_LabelColor, #6a6d70); min-width: 80px; text-align: center; }

    /* Empty State */
    .empty-state {
      display: flex; flex-direction: column; align-items: center; justify-content: center;
      padding: 3rem 2rem; background: var(--sapTile_Background, #fff);
      border: 1px solid var(--sapTile_BorderColor, #e4e4e4); border-radius: 0.5rem;
    }
    .empty-state-icon { margin-bottom: 1rem; opacity: 0.6; }
    .empty-state-title { margin: 0 0 0.25rem; font-size: 1rem; font-weight: 600; color: var(--sapTextColor, #32363a); }
    .empty-state-subtitle { margin: 0 0 1rem; font-size: 0.8125rem; color: var(--sapContent_LabelColor, #6a6d70); }
    .empty-state-btn {
      padding: 0.4rem 1rem; border: 1px solid var(--sapBrandColor, #0854a0); border-radius: 0.25rem;
      background: transparent; color: var(--sapBrandColor, #0854a0); cursor: pointer; font-size: 0.8125rem;
      transition: all 0.12s;
      &:hover { background: var(--sapBrandColor, #0854a0); color: #fff; }
    }
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