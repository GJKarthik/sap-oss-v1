import { DashboardLayoutService } from './dashboard-layout.service';

describe('DashboardLayoutService', () => {
  beforeEach(() => {
    localStorage.clear();
  });

  it('hides and restores widgets persistently', () => {
    const service = new DashboardLayoutService();

    service.toggleVisibility('productFamily');
    expect(service.isVisible('productFamily')).toBe(false);

    const restored = new DashboardLayoutService();
    expect(restored.isVisible('productFamily')).toBe(false);

    restored.toggleVisibility('productFamily');
    expect(restored.isVisible('productFamily')).toBe(true);
  });

  it('moves widgets within the ordered layout', () => {
    const service = new DashboardLayoutService();

    service.move('quickAccess', 'up');

    expect(service.orderedWidgets()).toEqual([
      'hubMap',
      'quickAccess',
      'priorityActions',
      'liveSignals',
      'productFamily',
    ]);
  });
});
