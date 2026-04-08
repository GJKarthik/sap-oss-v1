import { of, throwError, firstValueFrom } from 'rxjs';
import { HttpClient } from '@angular/common/http';
import {
  ExperienceHealthService,
  type ExperienceRoute,
} from './experience-health.service';
import {
  validateExperienceRuntimeConfig,
  type ExperienceRuntimeConfig,
} from './experience-runtime-config';
import { WorkspaceService } from './workspace.service';

function makeConfig(overrides: Partial<ExperienceRuntimeConfig> = {}): ExperienceRuntimeConfig {
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

function makeWorkspaceService() {
  return {
    effectiveOpenAiBaseUrl: () => 'http://localhost:8400',
    effectiveMcpBaseUrl: () => 'http://localhost:9160/mcp',
    effectiveAgUiEndpoint: () => '/ag-ui/run',
  } as unknown as WorkspaceService;
}

describe('validateExperienceRuntimeConfig', () => {
  it('throws when a required backend URL is missing in real mode', () => {
    expect(() =>
      validateExperienceRuntimeConfig(makeConfig({ mcpBaseUrl: '' })),
    ).toThrow('mcpBaseUrl');
  });

  it('returns config when all required fields are present', () => {
    const config = makeConfig();
    expect(validateExperienceRuntimeConfig(config)).toEqual(config);
  });
});

describe('ExperienceHealthService', () => {
  it('marks route blocked when a required service check fails', async () => {
    const http = makeHttpClient();
    (http.get as jest.Mock).mockImplementation((url: string) => {
      if (url.includes('/health')) {
        return throwError(() => ({ status: 503, message: 'Service unavailable' }));
      }
      return of({ ok: true });
    });
    const service = new ExperienceHealthService(http, makeWorkspaceService());

    const readiness = await firstValueFrom(
      service.checkRouteReadiness('generative'),
    );

    expect(readiness.route).toBe('generative');
    expect(readiness.blocking).toBe(true);
    expect(readiness.checks.some((check) => check.name === 'AG-UI')).toBe(true);
  });

  it.each<ExperienceRoute>(['generative', 'joule', 'components', 'mcp'])(
    'returns non-blocking readiness when dependencies are healthy (%s)',
    async (route) => {
      const http = makeHttpClient();
      (http.get as jest.Mock).mockReturnValue(of({ status: 200 }));
      const service = new ExperienceHealthService(http, makeWorkspaceService());

      const readiness = await firstValueFrom(service.checkRouteReadiness(route));

      expect(readiness.route).toBe(route);
      expect(readiness.blocking).toBe(false);
      expect(readiness.checks.length).toBeGreaterThan(0);
      expect(readiness.checks.every((check) => check.ok)).toBe(true);
    },
  );
});
