import { of, throwError } from 'rxjs';
import { HttpClient } from '@angular/common/http';
import { ComponentPlaygroundPageComponent } from './component-playground-page.component';
import { LiveDemoHealthService } from '../../core/live-demo-health.service';

function makeHttp() {
  return {
    get: jest.fn(),
  } as unknown as HttpClient;
}

function makeHealthService() {
  return {
    checkRouteReadiness: jest.fn().mockReturnValue(
      of({ route: 'components', blocking: false, checks: [] }),
    ),
  } as unknown as LiveDemoHealthService;
}

describe('ComponentPlaygroundPageComponent', () => {
  it('loads models from live OpenAI endpoint when route is healthy', () => {
    const http = makeHttp();
    (http.get as jest.Mock).mockReturnValue(
      of({ data: [{ id: 'gpt-live-a' }, { id: 'gpt-live-b' }] }),
    );
    const health = makeHealthService();
    const component = new ComponentPlaygroundPageComponent(http, health);

    component.ngOnInit();

    expect(http.get).toHaveBeenCalled();
    expect(component.models).toEqual(['gpt-live-a', 'gpt-live-b']);
    expect(component.lastError).toBeNull();
  });

  it('does not call OpenAI endpoint when route is blocked', () => {
    const http = makeHttp();
    const health = makeHealthService();
    (health.checkRouteReadiness as jest.Mock).mockReturnValue(
      of({
        route: 'components',
        blocking: true,
        checks: [{ name: 'OpenAI', ok: false, status: 503, url: '/health' }],
      }),
    );
    const component = new ComponentPlaygroundPageComponent(http, health);

    component.ngOnInit();

    expect(http.get).not.toHaveBeenCalled();
    expect(component.routeBlocked).toBe(true);
  });

  it('captures backend error message when live call fails', () => {
    const http = makeHttp();
    (http.get as jest.Mock).mockReturnValue(
      throwError(() => new Error('openai unavailable')),
    );
    const health = makeHealthService();
    const component = new ComponentPlaygroundPageComponent(http, health);

    component.ngOnInit();

    expect(component.models).toEqual([]);
    expect(component.lastError).toContain('openai unavailable');
  });

  it('flags invalid model contract when response shape is unexpected', () => {
    const http = makeHttp();
    (http.get as jest.Mock).mockReturnValue(of({ data: [{ wrong: 'field' }] }));
    const health = makeHealthService();
    const component = new ComponentPlaygroundPageComponent(http, health);

    component.ngOnInit();

    expect(component.models).toEqual([]);
    expect(component.lastError).toContain('Invalid model catalog contract');
  });
});
