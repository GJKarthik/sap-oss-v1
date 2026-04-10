import { NavigationAssistantService } from './navigation-assistant.service';

describe('NavigationAssistantService', () => {
  beforeEach(() => {
    localStorage.clear();
  });

  it('records recent pages without duplicates and keeps the newest first', () => {
    const service = new NavigationAssistantService();

    service.recordVisit('/chat');
    service.recordVisit('/pipeline');
    service.recordVisit('/chat');

    expect(service.recentEntries().map((entry) => entry.path)).toEqual(['/chat', '/pipeline']);
  });

  it('pins and unpins pages persistently', () => {
    const service = new NavigationAssistantService();

    service.togglePinned('/model-optimizer');
    expect(service.isPinned('/model-optimizer')).toBe(true);

    const restored = new NavigationAssistantService();
    expect(restored.isPinned('/model-optimizer')).toBe(true);

    restored.togglePinned('/model-optimizer');
    expect(restored.isPinned('/model-optimizer')).toBe(false);
  });

  it('finds the OCR page from task-oriented search terms', () => {
    const service = new NavigationAssistantService();

    const results = service.search(
      'invoice extraction',
      (key) => key,
      (group) => group,
    );

    expect(results[0]?.path).toBe('/document-ocr');
  });
});
