import { HomeLayoutService } from './home-layout.service';

describe('HomeLayoutService', () => {
  beforeEach(() => {
    localStorage.clear();
  });

  it('stores hidden widgets persistently', () => {
    const service = new HomeLayoutService();

    service.toggleVisibility('serviceHealth');
    expect(service.isVisible('serviceHealth')).toBe(false);

    const restored = new HomeLayoutService();
    expect(restored.isVisible('serviceHealth')).toBe(false);
  });

  it('moves widgets inside the home layout', () => {
    const service = new HomeLayoutService();

    service.move('quickAccess', 'up');

    expect(service.orderedWidgets()).toEqual([
      'quickAccess',
      'journeys',
      'productAreas',
      'serviceHealth',
      'productFamily',
    ]);
  });
});
