import { describe, expect, it } from 'vitest';

import { SacTableService } from '../libs/sac-table/src/lib/services/sac-table.service';

const rows = [
  { id: 'row-1', region: 'North', revenue: 120, owner: 'Alice' },
  { id: 'row-2', region: 'South', revenue: 200, owner: 'Bob' },
  { id: 'row-3', region: 'West', revenue: 90, owner: 'Cara' },
];

describe('SacTableService', () => {
  it('applies filters and sorting without destroying the original source-row order', () => {
    const service = new SacTableService();
    service.setData(rows);

    service.setSort({ column: 'revenue', direction: 'desc' });
    expect(service.getData().map((row) => row.id)).toEqual(['row-2', 'row-1', 'row-3']);

    service.addFilter({ column: 'region', value: 'o', operator: 'contains' });
    expect(service.getData().map((row) => row.id)).toEqual(['row-2', 'row-1']);

    service.clearFilters();
    expect(service.getData().map((row) => row.id)).toEqual(['row-2', 'row-1', 'row-3']);

    service.clearSort();
    expect(service.getData().map((row) => row.id)).toEqual(['row-1', 'row-2', 'row-3']);
    expect(service.getSourceData().map((row) => row.id)).toEqual(['row-1', 'row-2', 'row-3']);
  });

  it('prunes selection to the currently visible rows after filter changes', () => {
    const service = new SacTableService();
    service.setData(rows);

    service.selectAll(service.getData().slice(0, 2));
    expect(service.getSelection()).toMatchObject({
      selectedRowIds: ['row-1', 'row-2'],
      allSelected: true,
    });

    service.setFilters([{ column: 'region', value: 'North', operator: 'equals' }]);

    expect(service.getData().map((row) => row.id)).toEqual(['row-1']);
    expect(service.getSelection()).toEqual({
      selectedRowIds: ['row-1'],
      selectedRows: [{ id: 'row-1', region: 'North', revenue: 120, owner: 'Alice' }],
      allSelected: true,
    });
  });
});
