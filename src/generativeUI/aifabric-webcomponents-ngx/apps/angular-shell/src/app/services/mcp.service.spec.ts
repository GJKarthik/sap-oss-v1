import { TestBed } from '@angular/core/testing';
import { HttpTestingController, provideHttpClientTesting } from '@angular/common/http/testing';
import { provideHttpClient } from '@angular/common/http';
import { BehaviorSubject, firstValueFrom } from 'rxjs';
import { environment } from '../../environments/environment';
import { Deployment, McpService, ServiceHealth } from './mcp.service';
import { AuthService } from './auth.service';

describe('McpService', () => {
  let service: McpService;
  let httpMock: HttpTestingController;
  let authState$: BehaviorSubject<boolean>;

  beforeEach(() => {
    jest.useFakeTimers();
    authState$ = new BehaviorSubject<boolean>(true);

    TestBed.configureTestingModule({
      providers: [
        McpService,
        provideHttpClient(),
        provideHttpClientTesting(),
        {
          provide: AuthService,
          useValue: {
            isAuthenticated$: authState$.asObservable(),
          },
        },
      ],
    });

    service = TestBed.inject(McpService);
    httpMock = TestBed.inject(HttpTestingController);

    flushHealthChecks(
      { status: 'healthy', service: 'elasticsearch-mcp' },
      { status: 'healthy', service: 'ai-core-pal-mcp' }
    );
  });

  afterEach(() => {
    httpMock.verify();
    jest.useRealTimers();
  });

  it('updates health state based on backend health responses', async () => {
    const completion = firstValueFrom(service.checkAllHealth());

    flushHealthChecks(
      { status: 'healthy', service: 'elasticsearch-mcp' },
      { status: 'error', service: 'ai-core-pal-mcp', error: 'Connection failed' }
    );

    await completion;

    let latestHealth;
    service.health$.subscribe(value => {
      latestHealth = value;
    }).unsubscribe();

    expect(latestHealth).toEqual({
      elasticsearch: { status: 'healthy', service: 'elasticsearch-mcp' },
      pal: { status: 'error', service: 'ai-core-pal-mcp', error: 'Connection failed' },
      overall: 'degraded',
    });
  });

  it('does not start health polling until the user is authenticated', () => {
    httpMock.verify();
    TestBed.resetTestingModule();

    authState$ = new BehaviorSubject<boolean>(false);
    TestBed.configureTestingModule({
      providers: [
        McpService,
        provideHttpClient(),
        provideHttpClientTesting(),
        {
          provide: AuthService,
          useValue: {
            isAuthenticated$: authState$.asObservable(),
          },
        },
      ],
    });

    service = TestBed.inject(McpService);
    httpMock = TestBed.inject(HttpTestingController);

    expect(httpMock.match(request => request.method === 'GET' && request.url.endsWith('/health'))).toHaveLength(0);

    authState$.next(true);
    flushHealthChecks(
      { status: 'healthy', service: 'elasticsearch-mcp' },
      { status: 'healthy', service: 'ai-core-pal-mcp' }
    );
  });

  it('calls the deployments endpoint and exposes the returned resources', async () => {
    const deployments: Deployment[] = [
      { id: 'deployment-1', status: 'RUNNING', scenarioId: 'scenario-a' },
    ];

    const resultPromise = firstValueFrom(service.fetchDeployments());
    const request = httpMock.expectOne(`${environment.apiBaseUrl}/deployments`);

    expect(request.request.method).toBe('GET');

    request.flush({
      resources: [
        { id: 'deployment-1', status: 'RUNNING', scenario_id: 'scenario-a' },
      ],
      count: 1,
    });

    await expect(resultPromise).resolves.toEqual(deployments);

    let latestDeployments: Deployment[] = [];
    service.deployments$.subscribe(value => {
      latestDeployments = value;
    }).unsubscribe();

    expect(latestDeployments).toEqual(deployments);
  });

  it('loads PAL tools through the MCP proxy', async () => {
    const resultPromise = firstValueFrom(service.fetchPalTools());
    const request = httpMock.expectOne(environment.palMcpUrl);

    expect(request.request.method).toBe('POST');
    expect(request.request.body.method).toBe('tools/list');

    request.flush({
      jsonrpc: '2.0',
      id: request.request.body.id,
      result: {
        tools: [{ name: 'pal_forecast', description: 'Forecast data' }],
      },
    });

    await expect(resultPromise).resolves.toEqual([
      { name: 'pal_forecast', description: 'Forecast data' },
    ]);
  });

  function flushHealthChecks(elasticsearch: ServiceHealth, pal: ServiceHealth): void {
    const requests = httpMock.match(request => request.method === 'GET' && request.url.endsWith('/health'));
    expect(requests).toHaveLength(2);

    const elasticsearchRequest = requests.find(request =>
      request.request.url === `${environment.elasticsearchMcpUrl}/health`
    );
    const palRequest = requests.find(request =>
      request.request.url === `${environment.palMcpUrl}/health`
    );

    expect(elasticsearchRequest).toBeDefined();
    expect(palRequest).toBeDefined();

    elasticsearchRequest!.flush(elasticsearch);
    palRequest!.flush(pal);
  }
});
