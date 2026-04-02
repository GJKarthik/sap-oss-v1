import { ComponentFixture, TestBed } from '@angular/core/testing';
import { provideHttpClient } from '@angular/common/http';
import { provideHttpClientTesting, HttpTestingController } from '@angular/common/http/testing';
import { CUSTOM_ELEMENTS_SCHEMA, signal } from '@angular/core';
import { ModelOptimizerComponent } from './model-optimizer.component';
import { UserSettingsService, UserMode } from '../../services/user-settings.service';
import { AppStore } from '../../store/app.store';
import { ToastService } from '../../services/toast.service';

describe('ModelOptimizerComponent', () => {
  let component: ModelOptimizerComponent;
  let fixture: ComponentFixture<ModelOptimizerComponent>;
  let httpMock: HttpTestingController;

  const mockMode = signal<UserMode>('novice');

  const mockUserSettings = {
    mode: mockMode,
    setMode: jest.fn(),
  };

  const mockAppStore = {
    addJob: jest.fn(),
    models: signal({ data: [{ name: 'TestModel', recommended_quant: 'int8', t4_compatible: true }] }),
    loadModels: jest.fn(),
  };

  const mockToast = {
    success: jest.fn(),
    error: jest.fn(),
    warning: jest.fn(),
    info: jest.fn(),
  };

  beforeEach(async () => {
    await TestBed.configureTestingModule({
      imports: [ModelOptimizerComponent],
      providers: [
        provideHttpClient(),
        provideHttpClientTesting(),
        { provide: UserSettingsService, useValue: mockUserSettings },
        { provide: AppStore, useValue: mockAppStore },
        { provide: ToastService, useValue: mockToast },
      ],
    }).compileComponents();

    TestBed.overrideComponent(ModelOptimizerComponent, {
      set: { template: '<div></div>', schemas: [CUSTOM_ELEMENTS_SCHEMA] },
    });
  });

  beforeEach(() => {
    jest.useFakeTimers();
    fixture = TestBed.createComponent(ModelOptimizerComponent);
    component = fixture.componentInstance;
    httpMock = TestBed.inject(HttpTestingController);
    mockMode.set('novice'); // Default behavior
    Object.values(mockToast).forEach(spy => spy.mockClear());
    fixture.detectChanges();
    // Flush ngOnInit's loadData() requests
    httpMock.match('/api/models/catalog').forEach(r => r.flush([]));
    httpMock.match('/api/jobs').forEach(r => r.flush([]));
  });

  afterEach(() => {
    fixture.destroy(); // clears setInterval via ngOnDestroy
    jest.useRealTimers();
    httpMock.verify();
  });

  it('renders correctly', () => {
    expect(component).toBeTruthy();
  });

  it('shows toast when a model is clicked in novice mode', () => {
    component.selectModel({ name: 'Model A', recommended_quant: 'int4', t4_compatible: true, size_gb: 4, parameters: '1B' });
    
    expect(mockToast.info).toHaveBeenCalledWith('Switch to Intermediate mode to select a model manually.');
    expect(component.jobForm.value.model_name).not.toBe('Model A');
  });

  it('allows model selection in intermediate mode', () => {
    mockMode.set('intermediate');
    fixture.detectChanges();

    component.selectModel({ name: 'Model B', recommended_quant: 'fp8', t4_compatible: true, size_gb: 8, parameters: '1B' });
    
    expect(mockToast.info).not.toHaveBeenCalled();
    expect(component.jobForm.value.model_name).toBe('Model B');
    expect(component.jobForm.value.quant_format).toBe('fp8');
  });

  it('createJob() posts the correct typed payload', () => {
    component.jobForm.patchValue({
      model_name: 'test-model',
      quant_format: 'int8',
      calib_samples: 256,
      calib_seq_len: 2048,
      export_format: 'vllm',
      enable_pruning: false,
    });

    component.createJob();

    const req = httpMock.expectOne('/api/jobs');
    expect(req.request.method).toBe('POST');
    expect(req.request.body).toEqual({
      config: {
        model_name: 'test-model',
        quant_format: 'int8',
        calib_samples: 256,
        calib_seq_len: 2048,
        export_format: 'vllm',
        enable_pruning: false,
        pruning_sparsity: 0.2,
      },
    });

    req.flush({
      id: 'job-1234',
      name: 'Optimizing test-model',
      status: 'pending',
      progress: 0,
      created_at: new Date().toISOString(),
      config: { model_name: 'test-model', quant_format: 'int8' },
    });

    expect(mockToast.success).toHaveBeenCalled();
  });
});
