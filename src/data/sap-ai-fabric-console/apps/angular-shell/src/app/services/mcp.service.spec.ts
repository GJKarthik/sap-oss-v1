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
      { status: 'healthy', service: 'langchain-hana-mcp' },
      { status: 'healthy', service: 'ai-core-streaming-mcp' }
    );
  });

  afterEach(() => {
    httpMock.verify();
    jest.useRealTimers();
  });

  it('updates health state based on backend health responses', async () => {
    const completion = firstValueFrom(service.checkAllHealth());

    flushHealthChecks(
      { status: 'healthy', service: 'langchain-hana-mcp' },
      { status: 'error', service: 'ai-core-streaming-mcp', error: 'Connection failed' }
    );

    await completion;

    let latestHealth;
    service.health$.subscribe(value => {
      latestHealth = value;
    }).unsubscribe();

    expect(latestHealth).toEqual({
      langchain: { status: 'healthy', service: 'langchain-hana-mcp' },
      streaming: { status: 'error', service: 'ai-core-streaming-mcp', error: 'Connection failed' },
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
      { status: 'healthy', service: 'langchain-hana-mcp' },
      { status: 'healthy', service: 'ai-core-streaming-mcp' }
    );
  });

  it('calls the deployments MCP tool and exposes the returned resources', async () => {
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

  it('surfaces deployment request failures instead of converting them into empty lists', async () => {
    const resultPromise = firstValueFrom(service.fetchDeployments());
    const request = httpMock.expectOne(`${environment.apiBaseUrl}/deployments`);

    request.flush({ detail: 'backend unavailable' }, { status: 503, statusText: 'Service Unavailable' });

    await expect(resultPromise).rejects.toMatchObject({
      error: { detail: 'backend unavailable' },
    });
  });

  function flushHealthChecks(langchain: ServiceHealth, streaming: ServiceHealth): void {
    const requests = httpMock.match(request => request.method === 'GET' && request.url.endsWith('/health'));
    expect(requests).toHaveLength(2);

    const langchainRequest = requests.find(request =>
      request.request.url === `${environment.langchainMcpUrl}/health`
    );
    const streamingRequest = requests.find(request =>
      request.request.url === `${environment.streamingMcpUrl}/health`
    );

    expect(langchainRequest).toBeDefined();
    expect(streamingRequest).toBeDefined();

    langchainRequest!.flush(langchain);
    streamingRequest!.flush(streaming);
  }
});
