import { TestBed, fakeAsync, tick } from '@angular/core/testing';
import { HttpTestingController, provideHttpClientTesting } from '@angular/common/http/testing';
import { provideHttpClient } from '@angular/common/http';

import { CompareComponent } from './compare.component';
import { ToastService } from '../../services/toast.service';

jest.mock('../../../environments/environment', () => ({
  environment: { apiBaseUrl: 'http://localhost:8001' },
}));

const API = 'http://localhost:8001';

describe('CompareComponent', () => {
  let component: CompareComponent;
  let fixture: ReturnType<typeof TestBed.createComponent<CompareComponent>>;
  let httpMock: HttpTestingController;
  let toastSpy: jest.Mocked<Pick<ToastService, 'success' | 'error'>>;

  const MOCK_JOBS = [
    { id: 'aaaabbbb-1111', status: 'completed', config: { model_name: 'llama-3.1-8b' }, deployed: true },
    { id: 'ccccdddd-2222', status: 'completed', config: { model_name: 'mistral-7b' }, deployed: true },
    { id: 'eeeeffff-3333', status: 'running', config: { model_name: 'llama-3.1-70b' }, deployed: false },
    { id: 'gggghhhh-4444', status: 'completed', config: { model_name: 'phi-3' }, deployed: false },
  ];

  beforeEach(async () => {
    toastSpy = { success: jest.fn(), error: jest.fn() };

    await TestBed.configureTestingModule({
      imports: [CompareComponent],
      providers: [provideHttpClient(), provideHttpClientTesting(), { provide: ToastService, useValue: toastSpy }],
    }).compileComponents();

    fixture = TestBed.createComponent(CompareComponent);
    component = fixture.componentInstance;
    httpMock = TestBed.inject(HttpTestingController);
    fixture.detectChanges();
  });

  afterEach(() => {
    httpMock.verify();
    jest.restoreAllMocks();
  });

  // ── Creation / ngOnInit ───────────────────────────────────────────────────────

  it('should create and load deployed models on init', fakeAsync(() => {
    httpMock.expectOne(`${API}/jobs`).flush(MOCK_JOBS);
    tick();
    expect(component).toBeTruthy();
    expect(component.deployedModels()).toHaveLength(2);
  }));

  // ── loadDeployedModels ────────────────────────────────────────────────────────

  it('should only expose jobs that are both deployed and completed', fakeAsync(() => {
    httpMock.expectOne(`${API}/jobs`).flush(MOCK_JOBS);
    tick();
    const models = component.deployedModels();
    models.forEach(m => {
      const job = MOCK_JOBS.find(j => j.id === m.id)!;
      expect(job.deployed).toBe(true);
      expect(job.status).toBe('completed');
    });
  }));

  it('should set deployedModels to [] when no jobs are deployed', fakeAsync(() => {
    httpMock.expectOne(`${API}/jobs`).flush([
      { id: 'x', status: 'running', config: { model_name: 'model-a' }, deployed: false },
    ]);
    tick();
    expect(component.deployedModels()).toHaveLength(0);
  }));

  it('should handle empty jobs array gracefully', fakeAsync(() => {
    httpMock.expectOne(`${API}/jobs`).flush([]);
    tick();
    expect(component.deployedModels()).toEqual([]);
  }));

  // ── modelNameFor ──────────────────────────────────────────────────────────────

  it('modelNameFor() should return model_name for a known id', fakeAsync(() => {
    httpMock.expectOne(`${API}/jobs`).flush(MOCK_JOBS);
    tick();
    expect(component.modelNameFor('aaaabbbb-1111')).toBe('llama-3.1-8b');
  }));

  it('modelNameFor() should return truncated id for unknown id', fakeAsync(() => {
    httpMock.expectOne(`${API}/jobs`).flush([]);
    tick();
    expect(component.modelNameFor('abcdefgh-xxxx')).toBe('abcdefgh');
  }));

  // ── runComparison ─────────────────────────────────────────────────────────────

  it('should not run comparison when modelA or modelB is missing', fakeAsync(() => {
    httpMock.expectOne(`${API}/jobs`).flush(MOCK_JOBS);
    tick();

    component.modelA = 'aaaabbbb-1111';
    component.modelB = '';
    component.prompt = 'Total balance?';
    component.runComparison();
    httpMock.expectNone(`${API}/inference/aaaabbbb-1111/chat`);
  }));

  it('should not run comparison when prompt is empty', fakeAsync(() => {
    httpMock.expectOne(`${API}/jobs`).flush(MOCK_JOBS);
    tick();

    component.modelA = 'aaaabbbb-1111';
    component.modelB = 'ccccdddd-2222';
    component.prompt = '   ';
    component.runComparison();
    httpMock.expectNone(`${API}/inference/aaaabbbb-1111/chat`);
  }));

  it('should POST to both model inference endpoints and set results', fakeAsync(() => {
    httpMock.expectOne(`${API}/jobs`).flush(MOCK_JOBS);
    tick();

    component.modelA = 'aaaabbbb-1111';
    component.modelB = 'ccccdddd-2222';
    component.prompt = 'What is the total balance?';

    component.runComparison();
    expect(component.loading()).toBe(true);

    httpMock.expectOne(`${API}/inference/aaaabbbb-1111/chat`).flush({ response: 'SELECT SUM(balance) FROM accounts' });
    httpMock.expectOne(`${API}/inference/ccccdddd-2222/chat`).flush({ response: 'SELECT SUM(b) FROM acct' });
    tick();

    expect(component.loading()).toBe(false);
    expect(component.resultA()).toBe('SELECT SUM(balance) FROM accounts');
    expect(component.resultB()).toBe('SELECT SUM(b) FROM acct');
  }));

  it('should set error placeholder when model A fails', fakeAsync(() => {
    httpMock.expectOne(`${API}/jobs`).flush(MOCK_JOBS);
    tick();

    component.modelA = 'aaaabbbb-1111';
    component.modelB = 'ccccdddd-2222';
    component.prompt = 'Total?';

    component.runComparison();
    httpMock.expectOne(`${API}/inference/aaaabbbb-1111/chat`).flush('error', { status: 500, statusText: 'Server Error' });
    httpMock.expectOne(`${API}/inference/ccccdddd-2222/chat`).flush({ response: 'SELECT 1' });
    tick();

    expect(component.resultA()).toBe('[Error — model did not respond]');
    expect(component.resultB()).toBe('SELECT 1');
    expect(component.loading()).toBe(false);
  }));

  it('should add to history after both results are received', fakeAsync(() => {
    httpMock.expectOne(`${API}/jobs`).flush(MOCK_JOBS);
    tick();

    component.modelA = 'aaaabbbb-1111';
    component.modelB = 'ccccdddd-2222';
    component.prompt = 'Count rows?';
    component.runComparison();

    httpMock.expectOne(`${API}/inference/aaaabbbb-1111/chat`).flush({ response: 'SELECT COUNT(*) FROM t' });
    httpMock.expectOne(`${API}/inference/ccccdddd-2222/chat`).flush({ response: 'SELECT count(*) FROM t' });
    tick();

    expect(component.history()).toHaveLength(1);
    expect(component.history()[0].query).toBe('Count rows?');
    expect(component.history()[0].a).toBe('SELECT COUNT(*) FROM t');
    expect(component.history()[0].b).toBe('SELECT count(*) FROM t');
  }));

  it('should cap history at 10 entries (oldest evicted)', fakeAsync(() => {
    httpMock.expectOne(`${API}/jobs`).flush(MOCK_JOBS);
    tick();

    component.modelA = 'aaaabbbb-1111';
    component.modelB = 'ccccdddd-2222';

    for (let i = 0; i < 11; i++) {
      component.prompt = `query ${i}`;
      component.runComparison();
      httpMock.expectOne(`${API}/inference/aaaabbbb-1111/chat`).flush({ response: `SELECT ${i}` });
      httpMock.expectOne(`${API}/inference/ccccdddd-2222/chat`).flush({ response: `select ${i}` });
      tick();
    }

    expect(component.history()).toHaveLength(10);
    expect(component.history()[0].query).toBe('query 10');
  }));

  // ── isWinner ──────────────────────────────────────────────────────────────────

  it('isWinner("A") returns true when result A is shorter or equal length', fakeAsync(() => {
    httpMock.expectOne(`${API}/jobs`).flush([]);
    tick();

    component.resultA.set('short');
    component.resultB.set('much longer query string here');
    expect(component.isWinner('A')).toBe(true);
    expect(component.isWinner('B')).toBe(false);
  }));

  it('isWinner("B") returns true when result B is strictly shorter', fakeAsync(() => {
    httpMock.expectOne(`${API}/jobs`).flush([]);
    tick();

    component.resultA.set('SELECT * FROM long_table_name WHERE condition = 1');
    component.resultB.set('SELECT 1');
    expect(component.isWinner('B')).toBe(true);
    expect(component.isWinner('A')).toBe(false);
  }));

  it('isWinner() returns false when results are null', fakeAsync(() => {
    httpMock.expectOne(`${API}/jobs`).flush([]);
    tick();
    expect(component.isWinner('A')).toBe(false);
    expect(component.isWinner('B')).toBe(false);
  }));
});
