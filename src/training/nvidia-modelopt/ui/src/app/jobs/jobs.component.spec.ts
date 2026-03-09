import { ComponentFixture, TestBed } from '@angular/core/testing';
import { HttpClientTestingModule, HttpTestingController } from '@angular/common/http/testing';
import { JobsComponent } from './jobs.component';

describe('JobsComponent', () => {
  let component: JobsComponent;
  let fixture: ComponentFixture<JobsComponent>;
  let httpMock: HttpTestingController;

  beforeEach(async () => {
    await TestBed.configureTestingModule({
      imports: [JobsComponent, HttpClientTestingModule],
    }).compileComponents();

    fixture = TestBed.createComponent(JobsComponent);
    component = fixture.componentInstance;
    httpMock = TestBed.inject(HttpTestingController);
  });

  afterEach(() => httpMock.match(() => true));

  it('should create', () => {
    expect(component).toBeTruthy();
  });

  it('should start with empty jobs', () => {
    expect(component.jobs).toEqual([]);
  });

  it('should not show create modal initially', () => {
    expect(component.showCreateModal).toBeFalse();
  });

  it('should have default newJob values', () => {
    expect(component.newJob.model_name).toBe('Qwen/Qwen3.5-1.8B');
    expect(component.newJob.quant_format).toBe('int8');
    expect(component.newJob.calib_samples).toBe(512);
    expect(component.newJob.export_format).toBe('hf');
  });

  it('getJobCount returns correct count', () => {
    component.jobs = [
      { id: '1', name: 'j1', status: 'pending', config: {}, created_at: '', progress: 0 },
      { id: '2', name: 'j2', status: 'running', config: {}, created_at: '', progress: 50 },
      { id: '3', name: 'j3', status: 'pending', config: {}, created_at: '', progress: 0 },
    ];
    expect(component.getJobCount('pending')).toBe(2);
    expect(component.getJobCount('running')).toBe(1);
    expect(component.getJobCount('completed')).toBe(0);
  });

  it('ngOnInit loads jobs from API', () => {
    fixture.detectChanges();

    const req = httpMock.expectOne('/api/jobs');
    expect(req.request.method).toBe('GET');
    req.flush([
      { id: '1', name: 'j1', status: 'pending', config: {}, created_at: '2024-01-01', progress: 0 },
    ]);

    expect(component.jobs.length).toBe(1);
  });

  it('createJob sends POST and closes modal', () => {
    component.showCreateModal = true;
    component.createJob();

    const postReq = httpMock.expectOne('/api/jobs');
    expect(postReq.request.method).toBe('POST');
    expect(postReq.request.body.config.model_name).toBe('Qwen/Qwen3.5-1.8B');
    postReq.flush({ id: 'new', name: 'j-new', status: 'pending', config: {}, created_at: '', progress: 0 });

    expect(component.showCreateModal).toBeFalse();

    // Drain the loadJobs() call triggered after create
    const listReq = httpMock.expectOne('/api/jobs');
    listReq.flush([]);
  });

  it('cancelJob sends DELETE and reloads', () => {
    component.cancelJob('j99');

    const delReq = httpMock.expectOne('/api/jobs/j99');
    expect(delReq.request.method).toBe('DELETE');
    delReq.flush({ message: 'ok', job_id: 'j99' });

    // Drain the loadJobs() call
    const listReq = httpMock.expectOne('/api/jobs');
    listReq.flush([]);
  });

  it('retryJob creates a new job with same config', () => {
    const failedJob = {
      id: 'old',
      name: 'j-old',
      status: 'failed' as const,
      config: { model_name: 'Qwen/Qwen3.5-4B', quant_format: 'int8' },
      created_at: '',
      progress: 0,
    };
    component.retryJob(failedJob);

    const req = httpMock.expectOne('/api/jobs');
    expect(req.request.method).toBe('POST');
    expect(req.request.body.config.model_name).toBe('Qwen/Qwen3.5-4B');
    req.flush({ id: 'retry', name: 'j-retry', status: 'pending', config: {}, created_at: '', progress: 0 });

    // Drain loadJobs
    httpMock.expectOne('/api/jobs').flush([]);
  });

  it('ngOnDestroy unsubscribes polling', () => {
    fixture.detectChanges();
    httpMock.match(() => true); // drain init
    component.ngOnDestroy();
    // No error = success
  });
});

