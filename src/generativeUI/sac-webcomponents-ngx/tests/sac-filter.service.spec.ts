import { describe, expect, it } from 'vitest';
import { SacFilterService } from '../libs/sac-datasource/src/lib/services/sac-filter.service';

describe('SacFilterService', () => {
  it('starts with empty filters', () => {
    const service = new SacFilterService();
    expect(service.getFilter('dim1')).toBeUndefined();
  });

  it('sets and retrieves a filter', () => {
    const service = new SacFilterService();
    const values = [{ type: 'single', value: 'US' }] as any[];

    service.setFilter('country', values);
    expect(service.getFilter('country')).toEqual(values);
  });

  it('removes a filter', () => {
    const service = new SacFilterService();
    service.setFilter('country', [{ type: 'single', value: 'US' }] as any[]);
    service.removeFilter('country');
    expect(service.getFilter('country')).toBeUndefined();
  });

  it('clearAll removes all filters', () => {
    const service = new SacFilterService();
    service.setFilter('country', [{ type: 'single', value: 'US' }] as any[]);
    service.setFilter('year', [{ type: 'single', value: '2024' }] as any[]);
    service.clearAll();
    expect(service.getFilter('country')).toBeUndefined();
    expect(service.getFilter('year')).toBeUndefined();
  });

  it('filters$ emits on changes', () => {
    const service = new SacFilterService();
    const emissions: Map<string, any[]>[] = [];

    service.filters$.subscribe((m) => emissions.push(new Map(m)));
    service.setFilter('dim1', [{ type: 'single', value: 'A' }] as any[]);

    expect(emissions).toHaveLength(2); // initial + set
    expect(emissions[0].size).toBe(0);
    expect(emissions[1].size).toBe(1);
  });
});
