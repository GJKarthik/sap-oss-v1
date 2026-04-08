import { TestBed } from '@angular/core/testing';
import { provideHttpClient } from '@angular/common/http';
import { provideHttpClientTesting, HttpTestingController } from '@angular/common/http/testing';
import { signal } from '@angular/core';
import { ModelOptimizerComponent } from './model-optimizer.component';
import { AppStore } from '../../store/app.store';
import { ToastService } from '../../services/toast.service';
import { I18nService } from '../../services/i18n.service';

describe('ModelOptimizerComponent', () => {
  let component: ModelOptimizerComponent;
  let httpMock: HttpTestingController;

  const mockAppStore = {
    gpuMemoryTotal: signal(40),
  };

  const mockToast = {
    success: jest.fn(),
    error: jest.fn(),
    warning: jest.fn(),
    info: jest.fn(),
  };

  const mockI18n = {
    t: (key: string) => key,
  };

  function flushInitialLoad(): void {
    httpMock.expectOne('/api/models/catalog').flush([
      { name: 'Model A', recommended_quant: 'int8', t4_compatible: true, size_gb: 4, parameters: '1B' },
      { name: 'Model B', recommended_quant: 'fp8', t4_compatible: true, size_gb: 8, parameters: '1B' },
    ]);
    httpMock.expectOne('/api/jobs').flush([]);
  }

  beforeEach(async () => {
    await TestBed.configureTestingModule({
      imports: [ModelOptimizerComponent],
      providers: [
        provideHttpClient(),
        provideHttpClientTesting(),
        { provide: AppStore, useValue: mockAppStore },
        { provide: ToastService, useValue: mockToast },
        { provide: I18nService, useValue: mockI18n },
      ],
    }).compileComponents();
  });

  beforeEach(() => {
    component = TestBed.runInInjectionContext(() => new ModelOptimizerComponent());
    httpMock = TestBed.inject(HttpTestingController);
    Object.values(mockToast).forEach(spy => spy.mockClear());
    component.ngOnInit();
    flushInitialLoad();
  });

  afterEach(() => {
    component.ngOnDestroy();
    httpMock.verify();
  });

  it('renders correctly', () => {
    expect(component).toBeTruthy();
  });

  it('selectModel() applies the chosen model and recommended quantization', () => {
    component.selectModel({ name: 'Model A', recommended_quant: 'int4', t4_compatible: true, size_gb: 4, parameters: '1B' });

    expect(component.jobForm.value.model_name).toBe('Model A');
    expect(component.jobForm.value.quant_format).toBe('int4');
  });

  it('createJob() posts the correct typed payload', () => {
    component.jobForm.patchValue({
      model_name: 'test-model',
      quant_format: 'int8',
      export_format: 'vllm',
    });

    component.createJob();

    const req = httpMock.expectOne(r => r.url === '/api/jobs' && r.method === 'POST');
    expect(req.request.body).toEqual({
      config: {
        model_name: 'test-model',
        quant_format: 'int8',
        export_format: 'vllm',
      },
    });

    req.flush({ id: 'job-1234', name: 'test', status: 'pending', config: { model_name: 'test-model', quant_format: 'int8', export_format: 'vllm' }, created_at: new Date().toISOString(), progress: 0 });

    expect(mockToast.success).toHaveBeenCalled();
  });
});
