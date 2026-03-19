/**
 * Adaptive Table Tests
 * 
 * Tests for accessibility, keyboard navigation, and adaptive behavior.
 */

import { describe, it, expect, vi, beforeEach } from 'vitest';
import { render, screen, fireEvent } from '@testing-library/react';
import { AdaptiveTable } from '../components/react/AdaptiveTable';

// Mock the adaptation hooks
vi.mock('../../core/adaptation/react/use-adaptation', () => ({
  useAdaptation: () => ({
    decision: null,
    layout: {
      density: 'comfortable',
      gridColumns: 12,
      spacingScale: 1,
      sidebarState: 'expanded',
      panelOrder: [],
      autoExpandPanels: [],
      autoCollapsePanels: [],
    },
    content: {
      visibleColumns: [],
      columnOrder: [],
      pageSize: 25,
      preAppliedFilters: {},
      suggestedFilters: [],
      preloadData: [],
    },
    interaction: {
      touchTargetScale: 1,
      enableKeyboardShortcuts: false,
      showShortcutHints: false,
      enableDragDrop: true,
      hoverDelayMs: 200,
      tooltipDelayMs: 500,
      animationScale: 1,
    },
    confidence: 0.5,
    isReady: true,
  }),
  useAdaptiveLayout: () => ({
    density: 'comfortable',
    spacing: 8,
    densityClass: 'density-comfortable',
    gridStyle: { display: 'grid', gap: '8px' },
  }),
}));

// Mock capture service
vi.mock('../../core/capture/capture-service', () => ({
  createCaptureHooks: () => ({
    captureClick: vi.fn(),
    captureSort: vi.fn(),
    captureFilter: vi.fn(),
    captureExpand: vi.fn(),
    captureCollapse: vi.fn(),
  }),
}));

const mockColumns = [
  { id: 'name', label: 'Name', sortable: true },
  { id: 'email', label: 'Email', sortable: true },
  { id: 'status', label: 'Status', sortable: false },
];

const mockData = [
  { name: 'Alice', email: 'alice@example.com', status: 'Active' },
  { name: 'Bob', email: 'bob@example.com', status: 'Inactive' },
  { name: 'Charlie', email: 'charlie@example.com', status: 'Active' },
];

describe('AdaptiveTable', () => {
  describe('accessibility', () => {
    it('should have accessible table role', () => {
      render(
        <AdaptiveTable
          tableId="test-table"
          columns={mockColumns}
          data={mockData}
          ariaLabel="Test data table"
        />
      );
      
      const table = screen.getByRole('table');
      expect(table).toHaveAttribute('aria-label', 'Test data table');
    });

    it('should have column headers with scope', () => {
      render(
        <AdaptiveTable
          tableId="test-table"
          columns={mockColumns}
          data={mockData}
        />
      );
      
      const headers = screen.getAllByRole('columnheader');
      headers.forEach(header => {
        expect(header).toHaveAttribute('scope', 'col');
      });
    });

    it('should have aria-sort on sorted columns', () => {
      render(
        <AdaptiveTable
          tableId="test-table"
          columns={mockColumns}
          data={mockData}
        />
      );
      
      const nameHeader = screen.getByText('Name').closest('th');
      
      // Initially no sort
      expect(nameHeader).not.toHaveAttribute('aria-sort');
      
      // Click to sort
      fireEvent.click(nameHeader!);
      expect(nameHeader).toHaveAttribute('aria-sort', 'ascending');
      
      // Click again
      fireEvent.click(nameHeader!);
      expect(nameHeader).toHaveAttribute('aria-sort', 'descending');
    });
  });

  describe('keyboard navigation', () => {
    it('should allow sorting with Enter key', () => {
      const onSort = vi.fn();
      
      render(
        <AdaptiveTable
          tableId="test-table"
          columns={mockColumns}
          data={mockData}
          onSort={onSort}
        />
      );
      
      const nameHeader = screen.getByText('Name').closest('th');
      nameHeader?.focus();
      
      fireEvent.keyDown(nameHeader!, { key: 'Enter' });
      
      expect(onSort).toHaveBeenCalledWith('name', 'asc');
    });

    it('should have focusable sortable headers', () => {
      render(
        <AdaptiveTable
          tableId="test-table"
          columns={mockColumns}
          data={mockData}
        />
      );
      
      const nameHeader = screen.getByText('Name').closest('th');
      const statusHeader = screen.getByText('Status').closest('th');
      
      // Sortable = focusable
      expect(nameHeader).toHaveAttribute('tabindex', '0');
      // Not sortable = not focusable
      expect(statusHeader).toHaveAttribute('tabindex', '-1');
    });
  });

  describe('pagination', () => {
    it('should show pagination controls', () => {
      render(
        <AdaptiveTable
          tableId="test-table"
          columns={mockColumns}
          data={mockData}
        />
      );
      
      expect(screen.getByLabelText('Previous page')).toBeInTheDocument();
      expect(screen.getByLabelText('Next page')).toBeInTheDocument();
    });
  });
});

