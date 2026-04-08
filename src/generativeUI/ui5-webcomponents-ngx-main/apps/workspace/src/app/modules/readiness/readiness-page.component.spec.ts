import { of } from 'rxjs';
import { ReadinessPageComponent } from './readiness-page.component';
import { ExperienceHealthService } from '../../core/experience-health.service';
import { LearnPathService } from '../../core/learn-path.service';
import { Router } from '@angular/router';

function createHealthServiceMock(overrides: Partial<ExperienceHealthService> = {}) {
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
  } as unknown as ExperienceHealthService;
}

describe('ReadinessPageComponent', () => {
  it('marks workspace as ready when all dependencies and routes are healthy', () => {
    const component = new ReadinessPageComponent(
      createHealthServiceMock(),
      {
        start: () => ({ route: '/generative', label: 'Generative Renderer' }),
      } as LearnPathService,
      { navigate: jest.fn() } as unknown as Router,
    );
    component.refresh();

    expect(component.workspaceReady).toBe(true);
    expect(component.routeStatuses.length).toBe(5);
    expect(component.lastCheckedAt).not.toBeNull();
  });

  it('marks workspace as blocked when one route is blocked', () => {
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
      } as LearnPathService,
      { navigate: jest.fn() } as unknown as Router,
    );
    component.refresh();

    expect(component.workspaceReady).toBe(false);
    expect(component.routeStatuses.find((s) => s.route === 'generative')?.blocking).toBe(
      true,
    );
  });

  it('opens the learn path and navigates to the first step', () => {
    const navigate = jest.fn();
    const component = new ReadinessPageComponent(
      createHealthServiceMock(),
      {
        start: () => ({ route: '/generative', label: 'Generative Renderer' }),
      } as LearnPathService,
      { navigate } as unknown as Router,
    );

    component.openLearnPath();

    expect(navigate).toHaveBeenCalledWith(['/generative']);
  });
});
