import { TestBed, fakeAsync, tick } from '@angular/core/testing';
import { HttpTestingController, provideHttpClientTesting } from '@angular/common/http/testing';
import { provideHttpClient } from '@angular/common/http';
import { provideZoneChangeDetection, signal } from '@angular/core';

import { PipelineComponent } from './pipeline.component';
import { ToastService } from '../../services/toast.service';
import { AppStore } from '../../store/app.store';
import { RealtimeConnectionService } from '../../services/realtime-connection.service';
import { of } from 'rxjs';

const MOCK_ENV_URL = 'http://localhost:8001';

jest.mock('../../../environments/environment', () => ({
  environment: { apiBaseUrl: 'http://localhost:8001' },
}));

function makeWsMock() {
  const sent: unknown[] = [];
  return {
    sent,
    readyState: WebSocket.OPEN,
    send: jest.fn((data: unknown) => sent.push(data)),
    close: jest.fn(),
    addEventListener: jest.fn(),
    removeEventListener: jest.fn(),
    dispatchEvent: jest.fn(),
    onopen: null as ((e: Event) => void) | null,
    onmessage: null as ((e: MessageEvent) => void) | null,
    onclose: null as ((e: CloseEvent) => void) | null,
    onerror: null as ((e: Event) => void) | null,
  };
}

describe('PipelineComponent', () => {
  let component: PipelineComponent;
  let fixture: any;
  let httpMock: HttpTestingController;
  let toastSpy: jest.Mocked<Pick<ToastService, 'success' | 'error'>>;
  let wsMock: ReturnType<typeof makeWsMock>;
  const realtime = {
    buildWebSocketUrl: jest.fn(() => 'ws://localhost:8001/ws/pipeline'),
    probeApiHealth: jest.fn(() => of(true)),
  };
  const pipelineState = signal<'idle' | 'running' | 'completed' | 'error'>('idle');
  const appStore = {
    pipelineState,
    setPipelineState: jest.fn((state: 'idle' | 'running' | 'completed' | 'error') => pipelineState.set(state)),
  };

  beforeEach(async () => {
    toastSpy = { success: jest.fn(), error: jest.fn() };
    wsMock = makeWsMock();
    pipelineState.set('idle');
    appStore.setPipelineState.mockClear();
    realtime.buildWebSocketUrl.mockClear();
    realtime.probeApiHealth.mockClear();

    jest.spyOn(global, 'WebSocket').mockImplementation(() => wsMock as unknown as WebSocket);
    jest.spyOn(global, 'setTimeout').mockImplementation((fn: TimerHandler) => { (fn as () => void)(); return 0 as unknown as ReturnType<typeof setTimeout>; });

    await TestBed.configureTestingModule({
      imports: [PipelineComponent],
      providers: [
        provideHttpClient(),
        provideHttpClientTesting(),
        provideZoneChangeDetection({ eventCoalescing: true }),
        { provide: ToastService, useValue: toastSpy },
        { provide: AppStore, useValue: appStore },
        { provide: RealtimeConnectionService, useValue: realtime },
      ],
    }).compileComponents();

    fixture = TestBed.createComponent(PipelineComponent);
    component = fixture.componentInstance;
    httpMock = TestBed.inject(HttpTestingController);
    fixture.detectChanges();
  });

  afterEach(() => {
    fixture.destroy();
    httpMock.verify();
    jest.restoreAllMocks();
  });

  // ── Initialisation ──────────────────────────────────────────────────────────

  it('should create', () => {
    expect(component).toBeTruthy();
  });

  it('should start in idle state with empty log lines', () => {
    expect(component.pipelineState()).toBe('idle');
    expect(component.logLines()).toHaveLength(0);
    expect(component.starting()).toBe(false);
  });

  it('should expose 6 pipeline stages all starting idle', () => {
    const stages = component.stages();
    expect(stages).toHaveLength(6);
    stages.forEach(s => expect(s.status).toBe('idle'));
  });

  // ── WebSocket connectivity ───────────────────────────────────────────────────

  it('should mark wsConnected=true on WebSocket open', () => {
    expect(realtime.probeApiHealth).toHaveBeenCalled();
    expect(realtime.buildWebSocketUrl).toHaveBeenCalledWith('/ws/pipeline');
    wsMock.onopen?.(new Event('open'));
    expect(component.wsConnected()).toBe(true);
  });

  it('should mark wsConnected=false on WebSocket close', () => {
    wsMock.onopen?.(new Event('open'));
    wsMock.onclose?.(new CloseEvent('close'));
    expect(component.wsConnected()).toBe(false);
  });

  it('should apply init message — sets state and pre-existing logs', () => {
    const msg = { type: 'init', state: 'running', logs: ['Stage 1 started', '✅ schema loaded'] };
    wsMock.onmessage?.(new MessageEvent('message', { data: JSON.stringify(msg) }));
    expect(component.pipelineState()).toBe('running');
    expect(component.logLines()).toHaveLength(2);
  });

  it('should append log line on "log" message type', () => {
    wsMock.onmessage?.(new MessageEvent('message', { data: JSON.stringify({ type: 'log', text: 'Processing row 42' }) }));
    expect(component.logLines()).toHaveLength(1);
    expect(component.logLines()[0].text).toBe('Processing row 42');
  });

  it('should set completed state and toast on "done" message with completed', () => {
    wsMock.onmessage?.(new MessageEvent('message', {
      data: JSON.stringify({ type: 'done', state: 'completed', text: 'Pipeline finished' })
    }));
    expect(component.pipelineState()).toBe('completed');
    expect(toastSpy.success).toHaveBeenCalled();
  });

  it('should set error state and toast on "done" message with error', () => {
    wsMock.onmessage?.(new MessageEvent('message', {
      data: JSON.stringify({ type: 'done', state: 'error', text: 'Python pipeline failed' })
    }));
    expect(component.pipelineState()).toBe('error');
    expect(toastSpy.error).toHaveBeenCalled();
  });

  it('should silently ignore malformed WebSocket frames', () => {
    expect(() => {
      wsMock.onmessage?.(new MessageEvent('message', { data: 'not-valid-json{{{' }));
    }).not.toThrow();
    expect(component.logLines()).toHaveLength(0);
  });

  // ── parseLine / log colouring ────────────────────────────────────────────────

  it.each([
    ['✅ done', 'success'],
    ['❌ failed', 'error'],
    ['💥 crash', 'error'],
    ['⚠ low memory', 'warn'],
    ['# comment line', 'dim'],
    ['-- separator', 'dim'],
    ['ordinary info text', 'info'],
  ])('parseLine classifies "%s" as %s', (text, kind) => {
    wsMock.onmessage?.(new MessageEvent('message', { data: JSON.stringify({ type: 'log', text }) }));
    const last = component.logLines().at(-1);
    if (!last) {
      throw new Error('Expected a log line to be appended');
    }
    expect(last.kind).toBe(kind);
  });

  // ── startPipeline ────────────────────────────────────────────────────────────

  it('should POST to /pipeline/start and set running state on success', fakeAsync(() => {
    component.startPipeline();
    expect(component.starting()).toBe(true);

    const req = httpMock.expectOne(`${MOCK_ENV_URL}/pipeline/start`);
    expect(req.request.method).toBe('POST');
    req.flush({});
    tick();

    expect(component.pipelineState()).toBe('running');
    expect(component.starting()).toBe(false);
    expect(toastSpy.success).toHaveBeenCalled();
  }));

  it('should show error toast and clear starting flag when POST fails', fakeAsync(() => {
    component.startPipeline();
    const req = httpMock.expectOne(`${MOCK_ENV_URL}/pipeline/start`);
    req.flush({ detail: 'Pipeline already running' }, { status: 409, statusText: 'Conflict' });
    tick();

    expect(component.starting()).toBe(false);
    expect(toastSpy.error).toHaveBeenCalled();
  }));

  // ── stateDesign / statusIcon ────────────────────────────────────────────────

  it.each([
    ['idle', 'Neutral'],
    ['running', 'Information'],
    ['completed', 'Positive'],
    ['error', 'Negative'],
  ] as const)('stateDesign() returns correct design for state=%s', (state, expected) => {
    // Drive state via WebSocket message to update the AppStore
    if (state === 'running') {
      wsMock.onmessage?.(new MessageEvent('message', { data: JSON.stringify({ type: 'init', state: 'running', logs: [] }) }));
    } else if (state === 'completed') {
      wsMock.onmessage?.(new MessageEvent('message', { data: JSON.stringify({ type: 'done', state: 'completed', text: 'ok' }) }));
    } else if (state === 'error') {
      wsMock.onmessage?.(new MessageEvent('message', { data: JSON.stringify({ type: 'done', state: 'error', text: 'fail' }) }));
    }
    expect(component.stateDesign()).toBe(expected);
  });

  it.each([
    ['idle', 'circle-task'],
    ['running', 'synchronize'],
    ['done', 'status-completed'],
    ['error', 'status-error'],
  ] as const)('statusIcon() returns correct icon for status=%s', (status, expected) => {
    expect(component.statusIcon(status)).toBe(expected);
  });

  // ── Stage state updates ──────────────────────────────────────────────────────

  it('should mark first stage as running when state becomes running', () => {
    wsMock.onmessage?.(new MessageEvent('message', {
      data: JSON.stringify({ type: 'init', state: 'running', logs: [] })
    }));
    const stages = component.stages();
    expect(stages[0].status).toBe('running');
    stages.slice(1).forEach(s => expect(s.status).toBe('idle'));
  });

  it('should mark all stages done when state becomes completed', () => {
    wsMock.onmessage?.(new MessageEvent('message', {
      data: JSON.stringify({ type: 'done', state: 'completed', text: 'ok' })
    }));
    component.stages().forEach(s => expect(s.status).toBe('done'));
  });

  // ── ngOnDestroy ──────────────────────────────────────────────────────────────

  it('should close WebSocket on destroy', () => {
    component.ngOnDestroy();
    expect(wsMock.close).toHaveBeenCalled();
  });
});
