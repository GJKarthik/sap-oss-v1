import '@angular/compiler';

import { ChangeDetectorRef } from '@angular/core';
import { describe, expect, it, vi } from 'vitest';

import { SacTableComponent } from '../libs/sac-table/src/lib/components/sac-table.component';
import { SacTableService } from '../libs/sac-table/src/lib/services/sac-table.service';
import type { TableColumn } from '../libs/sac-table/src/lib/types/table.types';

const columns: TableColumn[] = [
  { id: 'region', label: 'Region', sortable: true },
  { id: 'revenue', label: 'Revenue', sortable: true, align: 'right' },
];

const rows = [
  { id: 'row-1', region: 'North', revenue: 120 },
  { id: 'row-2', region: 'South', revenue: 200 },
  { id: 'row-3', region: 'West', revenue: 90 },
];

describe('SacTableComponent', () => {
  it('supports uncontrolled sorting, paginates processed rows, and selects only the visible page rows', () => {
    const cdr = { markForCheck: vi.fn() } as ChangeDetectorRef;
    const component = new SacTableComponent(new SacTableService(), cdr);
    const sortEvents: unknown[] = [];
    const pageEvents: unknown[] = [];
    const selectionEvents: unknown[] = [];

    component.columns = columns;
    component.rows = rows;
    component.selectable = true;
    component.multiSelect = true;
    component.pagination = {
      enabled: true,
      pageSize: 1,
    };
    component.onSortChange.subscribe((event) => sortEvents.push(event));
    component.onPageChange.subscribe((event) => pageEvents.push(event));
    component.onSelectionChange.subscribe((event) => selectionEvents.push(event));

    component.ngOnInit();
    expect(component.displayRows.map((row) => row.id)).toEqual(['row-1']);

    component.handleSort(columns[1]);
    expect(component.displayRows.map((row) => row.id)).toEqual(['row-3']);
    expect(sortEvents).toEqual([{ column: 'revenue', direction: 'asc' }]);

    component.goToPage(2);
    expect(component.displayRows.map((row) => row.id)).toEqual(['row-1']);
    expect(pageEvents).toEqual([{ page: 2, pageSize: 1, totalItems: 3 }]);

    component.toggleSelectAll({
      target: { checked: true },
    } as unknown as Event);

    expect(selectionEvents).toEqual([
      {
        selectedRows: [{ id: 'row-1', region: 'North', revenue: 120 }],
        selectedCount: 1,
      },
    ]);
    expect(component.allDisplayedRowsSelected).toBe(true);
  });

  it('respects controlled sort config and filter inputs when rows change', () => {
    const cdr = { markForCheck: vi.fn() } as ChangeDetectorRef;
    const component = new SacTableComponent(new SacTableService(), cdr);

    component.columns = columns;
    component.rows = rows;
    component.sortConfig = { column: 'revenue', direction: 'desc' };
    component.filters = [{ column: 'region', value: 'o', operator: 'contains' }];
    component.ngOnInit();

    expect(component.displayRows.map((row) => row.id)).toEqual(['row-2', 'row-1']);

    component.rows = [...rows, { id: 'row-4', region: 'Oceania', revenue: 240 }];
    component.ngOnChanges({
      rows: {
        currentValue: component.rows,
        previousValue: rows,
        firstChange: false,
        isFirstChange: () => false,
      },
    });

    expect(component.displayRows.map((row) => row.id)).toEqual(['row-4', 'row-2', 'row-1']);
    expect(component.paginationInfo).toBe('1-3 of 3');
  });
});
