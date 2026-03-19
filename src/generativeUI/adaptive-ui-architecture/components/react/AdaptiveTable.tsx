/**
 * Adaptive Table — React Component
 * 
 * A table that adapts to user behavior, context, and preferences.
 * 
 * Features:
 * - Learns column preferences from user behavior
 * - Adapts density based on device/preference
 * - Shows suggested filters from capture patterns
 * - Accessible with WCAG AA compliance
 */

import React, { useState, useMemo, useCallback, useEffect } from 'react';
import { useAdaptation, useAdaptiveLayout } from '../../core/adaptation/react/use-adaptation';
import { createCaptureHooks } from '../../core/capture/capture-service';
import './AdaptiveTable.css';

// ============================================================================
// TYPES
// ============================================================================

export interface Column {
  id: string;
  label: string;
  sortable?: boolean;
  width?: string;
  align?: 'left' | 'center' | 'right';
}

export interface AdaptiveTableProps {
  columns: Column[];
  data: Record<string, unknown>[];
  tableId: string;
  ariaLabel?: string;
  onSort?: (columnId: string, direction: 'asc' | 'desc') => void;
  onFilter?: (field: string, value: unknown) => void;
  onRowSelect?: (row: Record<string, unknown>, index: number) => void;
}

// ============================================================================
// COMPONENT
// ============================================================================

export function AdaptiveTable({
  columns,
  data,
  tableId,
  ariaLabel = 'Data table',
  onSort,
  onFilter,
  onRowSelect,
}: AdaptiveTableProps) {
  const { content, interaction, confidence } = useAdaptation();
  const { spacing, densityClass } = useAdaptiveLayout();
  
  // Capture hooks for learning
  const capture = useMemo(
    () => createCaptureHooks({ componentType: 'table', componentId: tableId }),
    [tableId]
  );
  
  // State
  const [sortColumn, setSortColumn] = useState<string | null>(null);
  const [sortDirection, setSortDirection] = useState<'asc' | 'desc'>('asc');
  const [currentPage, setCurrentPage] = useState(1);
  const [hasInteracted, setHasInteracted] = useState(false);
  
  // Adaptive page size from learned preferences
  const pageSize = content.pageSize || 25;
  
  // Column visibility from learned preferences
  const visibleColumns = useMemo(() => {
    if (content.visibleColumns?.length > 0) {
      return columns.filter(col => content.visibleColumns.includes(col.id));
    }
    return columns;
  }, [columns, content.visibleColumns]);
  
  // Column order from learned preferences
  const orderedColumns = useMemo(() => {
    if (content.columnOrder?.length > 0) {
      return [...visibleColumns].sort((a, b) => {
        const aIndex = content.columnOrder.indexOf(a.id);
        const bIndex = content.columnOrder.indexOf(b.id);
        if (aIndex === -1) return 1;
        if (bIndex === -1) return -1;
        return aIndex - bIndex;
      });
    }
    return visibleColumns;
  }, [visibleColumns, content.columnOrder]);
  
  // Sorting
  const handleSort = useCallback((columnId: string) => {
    setHasInteracted(true);
    const newDirection = sortColumn === columnId && sortDirection === 'asc' ? 'desc' : 'asc';
    setSortColumn(columnId);
    setSortDirection(newDirection);
    
    // Capture for learning
    capture.captureSort(columnId, newDirection);
    onSort?.(columnId, newDirection);
  }, [sortColumn, sortDirection, capture, onSort]);
  
  // Pagination
  const totalPages = Math.ceil(data.length / pageSize);
  const paginatedData = useMemo(() => {
    const start = (currentPage - 1) * pageSize;
    return data.slice(start, start + pageSize);
  }, [data, currentPage, pageSize]);
  
  // Filter chips from learned patterns
  const suggestedFilters = content.suggestedFilters || [];
  
  const handleFilterClick = useCallback((filter: { field: string; value: unknown }) => {
    capture.captureFilter(filter.field, filter.value);
    onFilter?.(filter.field, filter.value);
  }, [capture, onFilter]);
  
  // Row selection
  const handleRowClick = useCallback((row: Record<string, unknown>, index: number) => {
    capture.captureClick(`row-${index}`);
    onRowSelect?.(row, index);
  }, [capture, onRowSelect]);

  // Keyboard navigation
  const handleKeyDown = useCallback((
    e: React.KeyboardEvent,
    rowIndex: number
  ) => {
    if (e.key === 'ArrowDown' && rowIndex < paginatedData.length - 1) {
      e.preventDefault();
      const nextRow = document.querySelector(
        `[data-row-index="${rowIndex + 1}"]`
      ) as HTMLElement;
      nextRow?.focus();
    } else if (e.key === 'ArrowUp' && rowIndex > 0) {
      e.preventDefault();
      const prevRow = document.querySelector(
        `[data-row-index="${rowIndex - 1}"]`
      ) as HTMLElement;
      prevRow?.focus();
    }
  }, [paginatedData.length]);

  return (
    <div 
      className={`adaptive-table ${densityClass}`}
      style={{ '--spacing': `${spacing}px` } as React.CSSProperties}
    >
      {/* Suggested Filters */}
      {suggestedFilters.length > 0 && confidence > 0.3 && (
        <div className="suggested-filters" role="region" aria-label="Quick filters">
          <span className="filter-label">Quick filters:</span>
          {suggestedFilters.map((filter, i) => (
            <button
              key={i}
              className="filter-chip"
              onClick={() => handleFilterClick(filter)}
              aria-label={`Filter by ${filter.field}: ${filter.value}`}
            >
              {filter.field}: {String(filter.value)}
              {filter.reason && (
                <span className="filter-reason">{filter.reason}</span>
              )}
            </button>
          ))}
        </div>
      )}

      {/* Table */}
      <table role="table" aria-label={ariaLabel}>
        <thead>
          <tr>
            {orderedColumns.map(col => (
              <th
                key={col.id}
                scope="col"
                style={{ width: col.width, textAlign: col.align || 'left' }}
                className={col.sortable ? 'sortable' : ''}
                aria-sort={
                  sortColumn === col.id
                    ? sortDirection === 'asc' ? 'ascending' : 'descending'
                    : undefined
                }
                onClick={() => col.sortable && handleSort(col.id)}
                onKeyDown={(e) => {
                  if (col.sortable && (e.key === 'Enter' || e.key === ' ')) {
                    e.preventDefault();
                    handleSort(col.id);
                  }
                }}
                tabIndex={col.sortable ? 0 : -1}
              >
                {col.label}
                {col.sortable && sortColumn === col.id && (
                  <span className="sort-indicator" aria-hidden="true">
                    {sortDirection === 'asc' ? ' ↑' : ' ↓'}
                  </span>
                )}
              </th>
            ))}
          </tr>
        </thead>
        <tbody>
          {paginatedData.map((row, rowIndex) => (
            <tr
              key={rowIndex}
              data-row-index={rowIndex}
              tabIndex={0}
              onClick={() => handleRowClick(row, rowIndex)}
              onKeyDown={(e) => handleKeyDown(e, rowIndex)}
              className="table-row"
            >
              {orderedColumns.map(col => (
                <td
                  key={col.id}
                  style={{ textAlign: col.align || 'left' }}
                >
                  {String(row[col.id] ?? '')}
                </td>
              ))}
            </tr>
          ))}
        </tbody>
      </table>

      {/* Pagination */}
      <nav className="pagination" aria-label="Table pagination">
        <span className="page-info">
          {(currentPage - 1) * pageSize + 1}–{Math.min(currentPage * pageSize, data.length)} of {data.length}
        </span>
        <div className="page-controls">
          <button
            onClick={() => setCurrentPage(p => Math.max(1, p - 1))}
            disabled={currentPage === 1}
            aria-label="Previous page"
          >
            ← Prev
          </button>
          <span className="page-number">
            Page {currentPage} of {totalPages}
          </span>
          <button
            onClick={() => setCurrentPage(p => Math.min(totalPages, p + 1))}
            disabled={currentPage === totalPages}
            aria-label="Next page"
          >
            Next →
          </button>
        </div>
      </nav>

      {/* Onboarding hint for low-confidence users */}
      {!hasInteracted && confidence < 0.3 && (
        <div className="onboarding-hint" role="note">
          💡 Tip: Click column headers to sort. Your preferences will be remembered.
        </div>
      )}
    </div>
  );
}

