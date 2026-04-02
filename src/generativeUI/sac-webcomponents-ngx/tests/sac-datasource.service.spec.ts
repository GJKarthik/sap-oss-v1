import { describe, expect, it, vi } from 'vitest';

import { DataSourceInstance } from '../libs/sac-datasource/src/lib/services/sac-datasource.service';
import type { ResultSet } from '../libs/sac-datasource/src/lib/types/datasource.types';

const makeResultSet = (): ResultSet => ({
  data: [[{ value: 42, formatted: '42', status: 'normal' }]],
  dimensions: ['Region'],
  measures: ['Revenue'],
  rowCount: 1,
  columnCount: 1,
  metadata: {
    modelId: 'Sales',
    dimensionHeaders: [{ id: 'Region', name: 'Region', index: 0 }],
    measureHeaders: [{ id: 'Revenue', name: 'Revenue', index: 0 }],
  },
});

describe('DataSourceInstance', () => {
  it('builds datasource endpoints through SacApiService and records refresh state', async () => {
    const api = {
      post: vi.fn().mockResolvedValue(makeResultSet()),
    };

    const dataSource = new DataSourceInstance(
      'ds-1',
      'Sales Model',
      api as never,
      {
        initialFilters: {
          Region: {
            type: 'SingleValue' as never,
            value: 'EMEA',
          },
        },
      },
    );

    const result = await dataSource.getData();

    expect(result.rowCount).toBe(1);
    expect(api.post).toHaveBeenCalledWith('/api/v1/datasources/Sales%20Model/data', {
      modelId: 'Sales Model',
      filters: {
        Region: {
          type: 'SingleValue',
          value: 'EMEA',
        },
      },
    });
    expect(dataSource.getState()).toEqual(
      expect.objectContaining({
        hasData: true,
        filterCount: 1,
        lastRefresh: expect.any(Date),
      }),
    );
  });

  it('returns cached data while paused without issuing another request', async () => {
    const api = {
      post: vi.fn().mockResolvedValue(makeResultSet()),
    };

    const dataSource = new DataSourceInstance('ds-2', 'Sales', api as never);

    await dataSource.getData();
    dataSource.pause();
    const cached = await dataSource.getData();

    expect(cached.rowCount).toBe(1);
    expect(api.post).toHaveBeenCalledTimes(1);
  });
});
