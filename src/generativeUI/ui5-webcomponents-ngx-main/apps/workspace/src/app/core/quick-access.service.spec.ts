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
});
