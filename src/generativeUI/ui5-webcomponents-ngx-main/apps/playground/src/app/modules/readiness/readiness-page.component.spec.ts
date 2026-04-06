import { of } from 'rxjs';
import { ReadinessPageComponent } from './readiness-page.component';
import { LiveDemoHealthService } from '../../core/live-demo-health.service';
import { DemoTourService } from '../../core/demo-tour.service';
import { Router } from '@angular/router';

function createHealthServiceMock(overrides: Partial<LiveDemoHealthService> = {}) {
  return {
    checkAllServices: () =>
      of([
        { name: 'AG-UI', ok: true, status: 200, url: '/health' },
        { name: 'OpenAI', ok: true, status: 200, url: '/health' },
        { name: 'MCP', ok: true, status: 200, url: '/health' },
      ]),
    checkRouteReadiness: (route: string) =>
      of({
        route,
        blocking: false,
        checks: [{ name: 'AG-UI', ok: true, status: 200, url: '/health' }],
      }),
    ...overrides,
  } as unknown as LiveDemoHealthService;
}

describe('ReadinessPageComponent', () => {
  it('marks demo as ready when all dependencies and routes are healthy', () => {
    const component = new ReadinessPageComponent(
      createHealthServiceMock(),
      {
        start: () => ({ route: '/generative', label: 'Generative Renderer' }),
      } as DemoTourService,
      { navigate: jest.fn() } as unknown as Router,
    );
    component.refresh();

    expect(component.demoReady).toBe(true);
    expect(component.routeStatuses.length).toBe(5);
    expect(component.lastCheckedAt).not.toBeNull();
  });

  it('marks demo as blocked when one route is blocked', () => {
    const health = createHealthServiceMock({
      checkRouteReadiness: (route: 'generative' | 'joule' | 'components' | 'mcp') =>
        of({
          route,
          blocking: route === 'generative',
          checks: [
            {
              name: 'AG-UI',
              ok: route !== 'generative',
              status: route === 'generative' ? 503 : 200,
              url: '/health',
            },
          ],
        }),
    });
    const component = new ReadinessPageComponent(
      health,
      {
        start: () => ({ route: '/generative', label: 'Generative Renderer' }),
      } as DemoTourService,
      { navigate: jest.fn() } as unknown as Router,
    );
    component.refresh();

    expect(component.demoReady).toBe(false);
    expect(component.routeStatuses.find((s) => s.route === 'generative')?.blocking).toBe(
      true,
    );
  });

  it('starts tour and navigates to first step', () => {
    const navigate = jest.fn();
    const component = new ReadinessPageComponent(
      createHealthServiceMock(),
      {
        start: () => ({ route: '/generative', label: 'Generative Renderer' }),
      } as DemoTourService,
      { navigate } as unknown as Router,
    );

    component.startDemo();

    expect(navigate).toHaveBeenCalledWith(['/generative']);
  });
});
