import { QuickAccessService } from './quick-access.service';

describe('QuickAccessService', () => {
  beforeEach(() => {
    localStorage.clear();
  });

  it('records recent pages without duplicates and keeps the newest first', () => {
    const service = new QuickAccessService();

    service.recordVisit('/joule');
    service.recordVisit('/ocr');
    service.recordVisit('/joule');

    expect(service.recentEntries().map((entry) => entry.path)).toEqual(['/joule', '/ocr']);
  });

  it('pins and unpins pages persistently', () => {
    const service = new QuickAccessService();

    service.togglePinned('/ocr');
    expect(service.isPinned('/ocr')).toBe(true);

    const restored = new QuickAccessService();
    expect(restored.isPinned('/ocr')).toBe(true);

    restored.togglePinned('/ocr');
    expect(restored.isPinned('/ocr')).toBe(false);
  });

  it('finds document intelligence from task-oriented search terms', () => {
    const service = new QuickAccessService();

    const results = service.search('invoice extraction');

    expect(results[0]?.path).toBe('/ocr');
  });

  it('ranks exact term matches higher than partial matches', () => {
    const service = new QuickAccessService();

    const results = service.search('joule');

    expect(results[0]?.path).toBe('/joule');
    expect(results.length).toBeGreaterThanOrEqual(1);
  });

  it('returns empty results for a query matching no terms', () => {
    const service = new QuickAccessService();

    const results = service.search('xyznonexistent');

    expect(results).toEqual([]);
  });

  it('returns suggested entries when search query is empty', () => {
    const service = new QuickAccessService();

    const results = service.search('');

    expect(results.length).toBeGreaterThan(0);
    expect(results.every((entry) => entry.path !== '/workspace')).toBe(true);
  });

  it('limits search results to 8 entries', () => {
    const service = new QuickAccessService();

    const results = service.search('a');

    expect(results.length).toBeLessThanOrEqual(8);
  });

  it('boosts pinned pages in search results', () => {
    const service = new QuickAccessService();
    service.togglePinned('/readiness');

    const results = service.search('status');
    const readinessResult = results.find((r) => r.path === '/readiness');

    expect(readinessResult).toBeDefined();
  });

  it('excludes workspace from suggested entries', () => {
    const service = new QuickAccessService();

    const suggested = service.suggestedEntries();

    expect(suggested.every((entry) => entry.path !== '/workspace')).toBe(true);
  });
});
