import { of, throwError, firstValueFrom } from 'rxjs';
import { HttpClient } from '@angular/common/http';
import {
  LiveDemoHealthService,
  type LiveDemoRoute,
} from './live-demo-health.service';
import {
  validateLiveDemoConfig,
  type LiveDemoConfig,
} from './live-demo-config';

function makeConfig(overrides: Partial<LiveDemoConfig> = {}): LiveDemoConfig {
  return {
    agUiEndpoint: '/ag-ui/run',
    openAiBaseUrl: 'http://localhost:8400',
    mcpBaseUrl: 'http://localhost:9160',
    requireRealBackends: true,
    ...overrides,
  };
}

function makeHttpClient() {
  return {
    get: jest.fn(),
  } as unknown as HttpClient;
}

describe('validateLiveDemoConfig', () => {
  it('throws when a required backend URL is missing in real mode', () => {
    expect(() =>
      validateLiveDemoConfig(makeConfig({ mcpBaseUrl: '' })),
    ).toThrow('mcpBaseUrl');
  });

  it('returns config when all required fields are present', () => {
    const config = makeConfig();
    expect(validateLiveDemoConfig(config)).toEqual(config);
  });
});

describe('LiveDemoHealthService', () => {
  it('marks route blocked when a required service check fails', async () => {
    const http = makeHttpClient();
    (http.get as jest.Mock).mockImplementation((url: string) => {
      if (url.includes('/health')) {
        return throwError(() => ({ status: 503, message: 'Service unavailable' }));
      }
      return of({ ok: true });
    });
    const service = new LiveDemoHealthService(http);

    const readiness = await firstValueFrom(
      service.checkRouteReadiness('generative'),
    );

    expect(readiness.route).toBe('generative');
    expect(readiness.blocking).toBe(true);
    expect(readiness.checks.some((check) => check.name === 'AG-UI')).toBe(true);
  });

  it.each<LiveDemoRoute>(['generative', 'joule', 'components', 'mcp'])(
    'returns non-blocking readiness when dependencies are healthy (%s)',
    async (route) => {
      const http = makeHttpClient();
      (http.get as jest.Mock).mockReturnValue(of({ status: 200 }));
      const service = new LiveDemoHealthService(http);

      const readiness = await firstValueFrom(service.checkRouteReadiness(route));

      expect(readiness.route).toBe(route);
      expect(readiness.blocking).toBe(false);
      expect(readiness.checks.length).toBeGreaterThan(0);
      expect(readiness.checks.every((check) => check.ok)).toBe(true);
    },
  );
});
