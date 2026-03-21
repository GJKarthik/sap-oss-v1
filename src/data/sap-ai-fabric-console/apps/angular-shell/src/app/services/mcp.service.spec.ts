import { TestBed } from '@angular/core/testing';
import { HttpTestingController, provideHttpClientTesting } from '@angular/common/http/testing';
import { provideHttpClient } from '@angular/common/http';
import { firstValueFrom } from 'rxjs';
import { environment } from '../../environments/environment';
import { Deployment, McpService, ServiceHealth } from './mcp.service';

describe('McpService', () => {
  let service: McpService;
  let httpMock: HttpTestingController;

  beforeEach(() => {
    jest.useFakeTimers();

    TestBed.configureTestingModule({
      providers: [McpService, provideHttpClient(), provideHttpClientTesting()],
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

  it('calls the deployments MCP tool and exposes the returned resources', async () => {
    const deployments: Deployment[] = [
      { id: 'deployment-1', status: 'RUNNING', scenarioId: 'scenario-a' },
    ];

    const resultPromise = firstValueFrom(service.fetchDeployments());
    const request = httpMock.expectOne(environment.streamingMcpUrl);

    expect(request.request.method).toBe('POST');
    expect(request.request.body.method).toBe('tools/call');
    expect(request.request.body.params).toEqual({
      name: 'list_deployments',
      arguments: {},
    });

    request.flush({
      jsonrpc: '2.0',
      id: request.request.body.id,
      result: {
        content: [{ type: 'text', text: JSON.stringify({ resources: deployments }) }],
      },
    });

    await expect(resultPromise).resolves.toEqual(deployments);

    let latestDeployments: Deployment[] = [];
    service.deployments$.subscribe(value => {
      latestDeployments = value;
    }).unsubscribe();

    expect(latestDeployments).toEqual(deployments);
  });

  function flushHealthChecks(langchain: ServiceHealth, streaming: ServiceHealth): void {
    const requests = httpMock.match(request => request.method === 'GET' && request.url.endsWith('/health'));
    expect(requests).toHaveLength(2);

    const langchainRequest = requests.find(request =>
      request.request.url === environment.langchainMcpUrl.replace('/mcp', '/health')
    );
    const streamingRequest = requests.find(request =>
      request.request.url === environment.streamingMcpUrl.replace('/mcp', '/health')
    );

    expect(langchainRequest).toBeDefined();
    expect(streamingRequest).toBeDefined();

    langchainRequest!.flush(langchain);
    streamingRequest!.flush(streaming);
  }
});
