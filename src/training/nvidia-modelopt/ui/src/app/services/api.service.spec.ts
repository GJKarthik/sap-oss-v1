import { TestBed } from '@angular/core/testing';
import { HttpClientTestingModule, HttpTestingController } from '@angular/common/http/testing';
import { ApiService, ModelList, Job, GpuStatus, ChatCompletionResponse } from './api.service';

describe('ApiService', () => {
  let service: ApiService;
  let httpMock: HttpTestingController;

  beforeEach(() => {
    TestBed.configureTestingModule({
      imports: [HttpClientTestingModule],
      providers: [ApiService],
    });
    service = TestBed.inject(ApiService);
    httpMock = TestBed.inject(HttpTestingController);
  });

  afterEach(() => httpMock.verify());

  it('should be created', () => {
    expect(service).toBeTruthy();
  });

  // -- Models --

  it('listModels sends GET /api/v1/models', () => {
    const mockResp: ModelList = {
      object: 'list',
      data: [{ id: 'test-model', object: 'model', created: 0, owned_by: 'test' }],
    };
    service.listModels().subscribe((data) => {
      expect(data.data.length).toBe(1);
      expect(data.data[0].id).toBe('test-model');
    });
    const req = httpMock.expectOne('/api/v1/models');
    expect(req.request.method).toBe('GET');
    req.flush(mockResp);
  });

  it('getModel sends GET /api/v1/models/:id', () => {
    service.getModel('m1').subscribe((m) => expect(m.id).toBe('m1'));
    const req = httpMock.expectOne('/api/v1/models/m1');
    req.flush({ id: 'm1', object: 'model', created: 0, owned_by: 'test' });
  });

  // -- Health & GPU --

  it('getHealth sends GET /api/health', () => {
    service.getHealth().subscribe((h) => expect(h.status).toBe('healthy'));
    httpMock.expectOne('/api/health').flush({ status: 'healthy', service: 'x' });
  });

  it('getGpuStatus sends GET /api/gpu/status', () => {
    const gpu: GpuStatus = {
      gpu_name: 'T4',
      compute_capability: '7.5',
      total_memory_gb: 16,
      supported_formats: ['int8'],
    };
    service.getGpuStatus().subscribe((g) => expect(g.gpu_name).toBe('T4'));
    httpMock.expectOne('/api/gpu/status').flush(gpu);
  });

  // -- Jobs --

  it('createJob sends POST /api/jobs', () => {
    const payload = { config: { model_name: 'X', quant_format: 'int8' } };
    service.createJob(payload).subscribe((j) => expect(j.id).toBe('j1'));
    const req = httpMock.expectOne('/api/jobs');
    expect(req.request.method).toBe('POST');
    expect(req.request.body).toEqual(payload);
    req.flush({ id: 'j1', name: 'job-j1', status: 'pending', config: {}, created_at: '', progress: 0 });
  });

  it('listJobs sends GET /api/jobs', () => {
    service.listJobs().subscribe((jobs) => expect(jobs.length).toBe(0));
    httpMock.expectOne('/api/jobs').flush([]);
  });

  it('listJobs passes status filter', () => {
    service.listJobs('running').subscribe();
    httpMock.expectOne('/api/jobs?status=running').flush([]);
  });

  it('cancelJob sends DELETE /api/jobs/:id', () => {
    service.cancelJob('j99').subscribe((r) => expect(r.message).toBe('ok'));
    const req = httpMock.expectOne('/api/jobs/j99');
    expect(req.request.method).toBe('DELETE');
    req.flush({ message: 'ok', job_id: 'j99' });
  });

  // -- Chat --

  it('createChatCompletion sends POST /api/v1/chat/completions', () => {
    const body = { model: 'm', messages: [{ role: 'user' as const, content: 'hi' }] };
    service.createChatCompletion(body).subscribe((r) => expect(r.id).toBeTruthy());
    const req = httpMock.expectOne('/api/v1/chat/completions');
    expect(req.request.method).toBe('POST');
    req.flush({ id: 'c1', object: 'chat.completion', created: 0, model: 'm', choices: [], usage: { prompt_tokens: 0, completion_tokens: 0, total_tokens: 0 } });
  });
});

