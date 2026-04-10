import { TestBed } from '@angular/core/testing';
import { HttpClientTestingModule, HttpTestingController } from '@angular/common/http/testing';
import { RealtimeConnectionService } from './realtime-connection.service';
import { WorkspaceService } from './workspace.service';

function makeWorkspaceService(apiBaseUrl = '/api') {
  return {
    effectiveApiBaseUrl: () => apiBaseUrl,
  } as unknown as WorkspaceService;
}

describe('RealtimeConnectionService', () => {
  beforeEach(() => {
    window.history.replaceState({}, '', '/training/dashboard');
  });

  it('builds websocket URLs from a relative API base', () => {
    TestBed.configureTestingModule({
      imports: [HttpClientTestingModule],
      providers: [
        RealtimeConnectionService,
        { provide: WorkspaceService, useValue: makeWorkspaceService('/api') },
      ],
    });

    const service = TestBed.inject(RealtimeConnectionService);
    const origin = window.location.origin;

    expect(service.buildWebSocketUrl('/ws/pipeline')).toBe(`${origin.replace(/^http/, 'ws')}/ws/pipeline`);
  });

  it('builds websocket URLs from a nested API base path', () => {
    TestBed.configureTestingModule({
      imports: [HttpClientTestingModule],
      providers: [
        RealtimeConnectionService,
        { provide: WorkspaceService, useValue: makeWorkspaceService('/training/api') },
      ],
    });

    const service = TestBed.inject(RealtimeConnectionService);
    const origin = window.location.origin;

    expect(service.buildWebSocketUrl('/ws/jobs/job-1')).toBe(`${origin.replace(/^http/, 'ws')}/training/ws/jobs/job-1`);
  });

  it('probes API health through the resolved API base', () => {
    TestBed.configureTestingModule({
      imports: [HttpClientTestingModule],
      providers: [
        RealtimeConnectionService,
        { provide: WorkspaceService, useValue: makeWorkspaceService('/api') },
      ],
    });

    const service = TestBed.inject(RealtimeConnectionService);
    const httpMock = TestBed.inject(HttpTestingController);
    let ready: boolean | undefined;

    service.probeApiHealth().subscribe((result) => {
      ready = result;
    });

    const req = httpMock.expectOne(`${window.location.origin}/api/health`);
    req.flush({}, { status: 200, statusText: 'OK' });

    expect(ready).toBe(true);
    httpMock.verify();
  });
});
