import { TestBed, fakeAsync, tick } from '@angular/core/testing';
import { HttpTestingController, provideHttpClientTesting } from '@angular/common/http/testing';
import { provideHttpClient } from '@angular/common/http';

import { RegistryComponent } from './registry.component';
import { ToastService } from '../../services/toast.service';

jest.mock('../../../environments/environment', () => ({
  environment: { apiBaseUrl: 'http://localhost:8001' },
}));

const API = 'http://localhost:8001';

const MOCK_JOBS = [
  {
    id: 'aaaa-1111',
    status: 'completed',
    progress: 100,
    config: { model_name: 'llama-3.1-8b', quant_format: 'gguf' },
    history: [{ step: 10, loss: 1.23 }, { step: 20, loss: 0.87 }],
    evaluation: { perplexity: 5.1, eval_loss: 0.62, runtime_sec: 120 },
    deployed: true,
    created_at: '2024-03-01T10:00:00Z',
  },
  {
    id: 'bbbb-2222',
    status: 'running',
    progress: 50,
    config: { model_name: 'mistral-7b', quant_format: null },
    history: [],
    deployed: false,
    created_at: '2024-03-02T11:00:00Z',
  },
  {
    id: 'cccc-3333',
    status: 'failed',
    progress: 30,
    config: { model_name: 'phi-3', quant_format: 'awq' },
    history: [{ step: 5, loss: 2.1 }],
    deployed: false,
    created_at: '2024-03-03T12:00:00Z',
  },
];

describe('RegistryComponent', () => {
  let component: RegistryComponent;
  let fixture: ReturnType<typeof TestBed.createComponent<RegistryComponent>>;
  let httpMock: HttpTestingController;
  let toastSpy: jest.Mocked<Pick<ToastService, 'success' | 'error'>>;

  beforeEach(async () => {
    toastSpy = { success: jest.fn(), error: jest.fn() };
    localStorage.clear();

    await TestBed.configureTestingModule({
      imports: [RegistryComponent],
      providers: [provideHttpClient(), provideHttpClientTesting(), { provide: ToastService, useValue: toastSpy }],
    }).compileComponents();

    fixture = TestBed.createComponent(RegistryComponent);
    component = fixture.componentInstance;
    httpMock = TestBed.inject(HttpTestingController);
    fixture.detectChanges();
  });

  afterEach(() => {
    httpMock.verify();
    localStorage.clear();
    jest.restoreAllMocks();
  });

  // ── Creation / ngOnInit ───────────────────────────────────────────────────────

  it('should create and load jobs on init', fakeAsync(() => {
    httpMock.expectOne(`${API}/jobs`).flush(MOCK_JOBS);
    tick();
    expect(component).toBeTruthy();
    expect(component.models()).toHaveLength(3);
  }));

  // ── Stat computeds ────────────────────────────────────────────────────────────

  it('completedCount() should count only completed jobs', fakeAsync(() => {
    httpMock.expectOne(`${API}/jobs`).flush(MOCK_JOBS);
    tick();
    expect(component.completedCount()).toBe(1);
  }));

  it('deployedCount() should count only deployed jobs', fakeAsync(() => {
    httpMock.expectOne(`${API}/jobs`).flush(MOCK_JOBS);
    tick();
    expect(component.deployedCount()).toBe(1);
  }));

  it('taggedCount() should return 0 when no tags are set', fakeAsync(() => {
    httpMock.expectOne(`${API}/jobs`).flush(MOCK_JOBS);
    tick();
    expect(component.taggedCount()).toBe(0);
  }));

  // ── applyFilter ───────────────────────────────────────────────────────────────

  it('should show all jobs when no filter is applied', fakeAsync(() => {
    httpMock.expectOne(`${API}/jobs`).flush(MOCK_JOBS);
    tick();
    expect(component.filtered()).toHaveLength(3);
  }));

  it('should filter by status=completed', fakeAsync(() => {
    httpMock.expectOne(`${API}/jobs`).flush(MOCK_JOBS);
    tick();
    component.filterStatus = 'completed';
    component.applyFilter();
    expect(component.filtered()).toHaveLength(1);
    expect(component.filtered()[0].status).toBe('completed');
  }));

  it('should filter by status=running', fakeAsync(() => {
    httpMock.expectOne(`${API}/jobs`).flush(MOCK_JOBS);
    tick();
    component.filterStatus = 'running';
    component.applyFilter();
    expect(component.filtered()).toHaveLength(1);
    expect(component.filtered()[0].status).toBe('running');
  }));

  it('should filter by deployedOnly', fakeAsync(() => {
    httpMock.expectOne(`${API}/jobs`).flush(MOCK_JOBS);
    tick();
    component.showDeployedOnly = true;
    component.applyFilter();
    expect(component.filtered()).toHaveLength(1);
    expect(component.filtered()[0].deployed).toBe(true);
  }));

  it('should combine status and deployedOnly filters', fakeAsync(() => {
    httpMock.expectOne(`${API}/jobs`).flush(MOCK_JOBS);
    tick();
    component.filterStatus = 'completed';
    component.showDeployedOnly = true;
    component.applyFilter();
    expect(component.filtered()).toHaveLength(1);
    expect(component.filtered()[0].id).toBe('aaaa-1111');
  }));

  it('should return empty array when combined filter matches nothing', fakeAsync(() => {
    httpMock.expectOne(`${API}/jobs`).flush(MOCK_JOBS);
    tick();
    component.filterStatus = 'failed';
    component.showDeployedOnly = true;
    component.applyFilter();
    expect(component.filtered()).toHaveLength(0);
  }));

  // ── Tags ──────────────────────────────────────────────────────────────────────

  it('startTag() should set editingTag and tagDraft', fakeAsync(() => {
    httpMock.expectOne(`${API}/jobs`).flush(MOCK_JOBS);
    tick();
    const job = component.models()[0];
    component.startTag(job);
    expect(component.editingTag()).toBe(job.id);
    expect(component.tagDraft).toBe('');
  }));

  it('saveTag() should persist tag to localStorage and update model', fakeAsync(() => {
    httpMock.expectOne(`${API}/jobs`).flush(MOCK_JOBS);
    tick();
    component.startTag(component.models()[0]);
    component.tagDraft = 'v1-baseline';
    component.saveTag('aaaa-1111');

    expect(component.editingTag()).toBeNull();
    expect(component.taggedCount()).toBe(1);
    const storedTags = localStorage.getItem('model_tags');
    expect(storedTags).not.toBeNull();
    if (!storedTags) {
      throw new Error('Expected persisted model tags');
    }
    expect(JSON.parse(storedTags)).toEqual({ 'aaaa-1111': 'v1-baseline' });
    expect(toastSpy.success).toHaveBeenCalled();
  }));

  it('cancelTag() should clear editingTag without persisting', fakeAsync(() => {
    httpMock.expectOne(`${API}/jobs`).flush(MOCK_JOBS);
    tick();
    component.startTag(component.models()[0]);
    component.tagDraft = 'abandoned';
    component.cancelTag();
    expect(component.editingTag()).toBeNull();
    expect(component.taggedCount()).toBe(0);
  }));

  it('should restore persisted tags from localStorage on load', fakeAsync(() => {
    localStorage.setItem('model_tags', JSON.stringify({ 'aaaa-1111': 'prod-v1' }));
    httpMock.expectOne(`${API}/jobs`).flush(MOCK_JOBS);
    tick();
    expect(component.taggedCount()).toBe(1);
    expect(component.models()[0].tag).toBe('prod-v1');
  }));

  // ── deploy ────────────────────────────────────────────────────────────────────

  it('deploy() should POST to /jobs/:id/deploy and reload', fakeAsync(() => {
    httpMock.expectOne(`${API}/jobs`).flush(MOCK_JOBS);
    tick();

    const job = component.models()[2];
    component.deploy(job);

    httpMock.expectOne(`${API}/jobs/cccc-3333/deploy`).flush({});
    tick();

    httpMock.expectOne(`${API}/jobs`).flush(MOCK_JOBS);
    tick();

    expect(toastSpy.success).toHaveBeenCalled();
  }));

  it('deploy() should show error toast on failure', fakeAsync(() => {
    httpMock.expectOne(`${API}/jobs`).flush(MOCK_JOBS);
    tick();

    component.deploy(component.models()[2]);
    httpMock.expectOne(`${API}/jobs/cccc-3333/deploy`).flush(
      { detail: 'Model not ready' },
      { status: 400, statusText: 'Bad Request' }
    );
    tick();

    expect(toastSpy.error).toHaveBeenCalledWith('Model not ready', 'Error');
  }));

  // ── deleteJob ─────────────────────────────────────────────────────────────────

  it('deleteJob() should DELETE job and reload', fakeAsync(() => {
    httpMock.expectOne(`${API}/jobs`).flush(MOCK_JOBS);
    tick();

    component.deleteJob('bbbb-2222');
    httpMock.expectOne(`${API}/jobs/bbbb-2222`).flush({});
    tick();

    httpMock.expectOne(`${API}/jobs`).flush(MOCK_JOBS.filter(j => j.id !== 'bbbb-2222'));
    tick();

    expect(toastSpy.success).toHaveBeenCalledWith('Job removed from registry', 'Deleted');
    expect(component.models()).toHaveLength(2);
  }));

  // ── load error handling ───────────────────────────────────────────────────────

  it('should show error toast when load() fails', fakeAsync(() => {
    httpMock.expectOne(`${API}/jobs`).flush('error', { status: 503, statusText: 'Unavailable' });
    tick();
    expect(toastSpy.error).toHaveBeenCalledWith('Failed to load model registry', 'Error');
  }));
});
