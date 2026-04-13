// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 SAP SE
import { provideHttpClient } from '@angular/common/http';
import { HttpTestingController, provideHttpClientTesting } from '@angular/common/http/testing';
import { TestBed } from '@angular/core/testing';
import { firstValueFrom } from 'rxjs';
import { environment } from '../../environments/environment';
import { ExperienceHealthService } from './experience-health.service';
import { WorkspaceService } from './workspace.service';

/**
 * Integration-style tests: real HttpClient pipeline + HttpTestingController (no jest.mock on HttpClient).
 * Verifies the exact capabilities URL and JSON mapping for readiness stack cards.
 */
describe('ExperienceHealthService.fetchTrainingStack (HTTP)', () => {
  let httpMock: HttpTestingController;
  let service: ExperienceHealthService;

  beforeEach(() => {
    TestBed.configureTestingModule({
      providers: [
        provideHttpClient(),
        provideHttpClientTesting(),
        ExperienceHealthService,
        {
          provide: WorkspaceService,
          useValue: {
            effectiveOpenAiBaseUrl: () => 'http://localhost:8400',
            effectiveMcpBaseUrl: () => 'http://localhost:9160/mcp',
            effectiveAgUiEndpoint: () => '/ag-ui/run',
          },
        },
      ],
    });
    httpMock = TestBed.inject(HttpTestingController);
    service = TestBed.inject(ExperienceHealthService);
  });

  afterEach(() => {
    httpMock.verify();
  });

  it('GETs trainingApiUrl/capabilities and maps stack layers', async () => {
    const expectedUrl = `${environment.trainingApiUrl.replace(/\/$/, '')}/capabilities`;
    const done = firstValueFrom(service.fetchTrainingStack());

    const req = httpMock.expectOne(expectedUrl);
    expect(req.request.method).toBe('GET');
    req.flush({
      service: 'training-webcomponents-ngx-api',
      db_backend: 'sqlite',
      database: 'healthy',
      hana_vector: 'unconfigured',
      vllm_turboquant: 'healthy',
      aicore_configured: false,
      aicore_reachable: 'unconfigured',
      pal_route: 'unconfigured',
      timestamp: '2026-01-01T00:00:00Z',
    });

    const result = await done;
    expect(result.layers).toHaveLength(5);
    expect(result.layers.map((l) => l.id)).toEqual([
      'database',
      'hana_vector',
      'vllm_turboquant',
      'aicore',
      'pal_route',
    ]);
    expect(result.layers[0].ok).toBe(true);
    expect(result.layers[1].ok).toBe(true);
    expect(result.blocksWorkspace).toBe(false);
    expect(result.httpError).toBeUndefined();
  });

  it('treats HTTP failure as blocking stack with empty layers', async () => {
    const expectedUrl = `${environment.trainingApiUrl.replace(/\/$/, '')}/capabilities`;
    const done = firstValueFrom(service.fetchTrainingStack());

    const req = httpMock.expectOne(expectedUrl);
    req.flush('unavailable', { status: 503, statusText: 'Service Unavailable' });

    const result = await done;
    expect(result.layers).toHaveLength(0);
    expect(result.blocksWorkspace).toBe(true);
    expect(result.httpError).toBeTruthy();
  });

  it('blocks when database unhealthy or AI Core configured but unreachable', async () => {
    const done = firstValueFrom(service.fetchTrainingStack());
    const req = httpMock.expectOne((r) => r.url.endsWith('/capabilities'));
    req.flush({
      service: 'training-webcomponents-ngx-api',
      db_backend: 'hana',
      database: 'unhealthy',
      hana_vector: 'healthy',
      vllm_turboquant: 'healthy',
      aicore_configured: true,
      aicore_reachable: 'unhealthy',
      pal_route: 'unconfigured',
      timestamp: '2026-01-01T00:00:00Z',
    });

    const result = await done;
    expect(result.blocksWorkspace).toBe(true);
    expect(result.layers[0].ok).toBe(false);
  });
});
