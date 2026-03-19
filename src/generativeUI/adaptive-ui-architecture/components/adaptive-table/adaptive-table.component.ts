/**
 * Adaptive Table Component — Example of Truly Adaptive UI
 * 
 * This table CHANGES based on:
 * - User behavior (column preferences, sort patterns)
 * - Context (device, task mode, data characteristics)
 * - Learned preferences (page size, density)
 */

import { Component, Input, OnInit, OnDestroy } from '@angular/core';
import { contextProvider } from '../../core/context/context-provider';
import { adaptationEngine } from '../../core/adaptation/engine';
import type { AdaptationDecision } from '../../core/adaptation/types';
import type { AdaptiveContext } from '../../core/context/types';

interface TableColumn {
  id: string;
  label: string;
  sortable?: boolean;
  width?: string;
}

interface TableRow {
  [key: string]: unknown;
}

@Component({
  selector: 'adaptive-table',
  template: `
    <div class="adaptive-table" 
         [class.density-compact]="adaptation?.layout.density === 'compact'"
         [class.density-comfortable]="adaptation?.layout.density === 'comfortable'"
         [class.density-spacious]="adaptation?.layout.density === 'spacious'"
         role="table"
         [attr.aria-label]="ariaLabel"
         [attr.aria-busy]="loading">
      
      <!-- Suggested Filters (Adaptive) -->
      <div *ngIf="adaptation?.content.suggestedFilters?.length" 
           class="suggested-filters"
           role="region"
           aria-label="Suggested filters based on your usage patterns">
        <span class="suggestion-label">Quick filters:</span>
        <button *ngFor="let filter of adaptation?.content.suggestedFilters"
                class="filter-chip"
                (click)="applyFilter(filter)"
                [attr.aria-label]="'Apply filter: ' + filter.field + ' ' + filter.value">
          {{ filter.field }}: {{ filter.value }}
          <span class="filter-reason">{{ filter.reason }}</span>
        </button>
      </div>

      <!-- Table Header -->
      <div class="table-header" role="rowgroup">
        <div class="table-row" role="row">
          <div *ngFor="let col of visibleColumns; let i = index"
               class="table-cell header-cell"
               role="columnheader"
               [attr.aria-sort]="getSortDirection(col.id)"
               [style.width]="col.width"
               [class.sortable]="col.sortable"
               (click)="col.sortable && sort(col.id)"
               (keydown.enter)="col.sortable && sort(col.id)"
               (keydown.space)="col.sortable && sort(col.id)"
               [tabindex]="col.sortable ? 0 : -1">
            {{ col.label }}
            <span *ngIf="col.sortable" class="sort-indicator" aria-hidden="true">
              {{ getSortIcon(col.id) }}
            </span>
          </div>
        </div>
      </div>

      <!-- Table Body -->
      <div class="table-body" role="rowgroup">
        <div *ngFor="let row of paginatedData; let i = index"
             class="table-row"
             role="row"
             [tabindex]="0"
             (focus)="onRowFocus(i)">
          <div *ngFor="let col of visibleColumns"
               class="table-cell"
               role="cell"
               [style.width]="col.width">
            {{ row[col.id] }}
          </div>
        </div>
      </div>

      <!-- Pagination (Adaptive page size) -->
      <div class="pagination" role="navigation" aria-label="Table pagination">
        <span class="page-info">
          Showing {{ startIndex + 1 }}-{{ endIndex }} of {{ totalRows }}
        </span>
        <div class="page-controls">
          <button (click)="prevPage()" 
                  [disabled]="currentPage === 1"
                  aria-label="Previous page">
            ← Previous
          </button>
          <span class="page-number">Page {{ currentPage }} of {{ totalPages }}</span>
          <button (click)="nextPage()" 
                  [disabled]="currentPage === totalPages"
                  aria-label="Next page">
            Next →
          </button>
        </div>
        
        <!-- Page size (learned from user behavior) -->
        <select [(ngModel)]="pageSize" 
                (change)="onPageSizeChange()"
                aria-label="Rows per page">
          <option [value]="10">10 per page</option>
          <option [value]="25">25 per page</option>
          <option [value]="50">50 per page</option>
          <option [value]="100">100 per page</option>
        </select>
      </div>

      <!-- Onboarding hint (shown for novice users) -->
      <div *ngIf="adaptation?.feedback.showOnboardingHints && !hasInteracted"
           class="onboarding-hint"
           role="note">
        💡 Tip: Click column headers to sort. Your preferences will be remembered.
      </div>
    </div>
  `,
  styles: [`
    .adaptive-table {
      font-family: var(--font-family, system-ui);
    }
    .density-compact .table-cell { padding: 4px 8px; font-size: 13px; }
    .density-comfortable .table-cell { padding: 8px 16px; font-size: 14px; }
    .density-spacious .table-cell { padding: 12px 24px; font-size: 15px; }
    
    .suggested-filters {
      padding: 8px;
      background: var(--surface-secondary, #f5f5f5);
      border-radius: 4px;
      margin-bottom: 8px;
    }
    .filter-chip {
      padding: 4px 12px;
      border-radius: 16px;
      border: 1px solid var(--border-color, #ccc);
      background: white;
      cursor: pointer;
      margin: 0 4px;
    }
    .filter-chip:hover { background: var(--hover-bg, #eee); }
    .filter-chip:focus-visible {
      outline: 2px solid var(--focus-color, #0066cc);
      outline-offset: 2px;
    }
    .filter-reason {
      font-size: 11px;
      color: var(--text-secondary, #666);
      margin-left: 4px;
    }
    
    .table-row:focus-visible {
      outline: 2px solid var(--focus-color, #0066cc);
      outline-offset: -2px;
    }
    .header-cell.sortable { cursor: pointer; }
    .header-cell.sortable:hover { background: var(--hover-bg, #eee); }
    
    .onboarding-hint {
      padding: 12px;
      background: var(--info-bg, #e3f2fd);
      border-radius: 4px;
      margin-top: 8px;
      font-size: 13px;
    }
  `]
})
export class AdaptiveTableComponent implements OnInit, OnDestroy {
  @Input() columns: TableColumn[] = [];
  @Input() data: TableRow[] = [];
  @Input() ariaLabel = 'Data table';
  
  adaptation: AdaptationDecision | null = null;
  loading = false;
  hasInteracted = false;
  // ... additional properties would continue
}

