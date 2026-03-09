import { ComponentFixture, TestBed } from '@angular/core/testing';
import { HttpClientTestingModule, HttpTestingController } from '@angular/common/http/testing';
import { ModelsComponent } from './models.component';

describe('ModelsComponent', () => {
  let component: ModelsComponent;
  let fixture: ComponentFixture<ModelsComponent>;
  let httpMock: HttpTestingController;

  beforeEach(async () => {
    await TestBed.configureTestingModule({
      imports: [ModelsComponent, HttpClientTestingModule],
    }).compileComponents();

    fixture = TestBed.createComponent(ModelsComponent);
    component = fixture.componentInstance;
    httpMock = TestBed.inject(HttpTestingController);
  });

  afterEach(() => httpMock.match(() => true));

  it('should create', () => {
    expect(component).toBeTruthy();
  });

  it('should start with empty models', () => {
    expect(component.models).toEqual([]);
  });

  it('ngOnInit fetches models from API', () => {
    fixture.detectChanges(); // triggers ngOnInit

    const req = httpMock.expectOne('/api/v1/models');
    expect(req.request.method).toBe('GET');
    req.flush({
      object: 'list',
      data: [
        { id: 'qwen3.5-0.6b-int8', object: 'model', created: 1701388800, owned_by: 'nvidia-modelopt' },
        { id: 'qwen3.5-1.8b-int8', object: 'model', created: 1701388800, owned_by: 'nvidia-modelopt' },
      ],
    });

    expect(component.models.length).toBe(2);
  });

  it('getModelType returns INT8 for int8 models', () => {
    expect(component.getModelType('qwen3.5-0.6b-int8')).toBe('INT8');
  });

  it('getModelType returns INT4 AWQ for awq models', () => {
    expect(component.getModelType('qwen3.5-9b-int4-awq')).toBe('INT4 AWQ');
  });

  it('getModelType returns FP16 for unknown format', () => {
    expect(component.getModelType('some-model')).toBe('FP16');
  });

  it('getQuantization returns correct format', () => {
    expect(component.getQuantization('qwen3.5-0.6b-int8')).toBe('INT8');
    expect(component.getQuantization('qwen3.5-9b-int4-awq')).toBe('INT4 AWQ');
  });

  it('getQuantClass returns correct CSS class', () => {
    expect(component.getQuantClass('qwen3.5-0.6b-int8')).toBe('int8');
    expect(component.getQuantClass('qwen3.5-9b-int4-awq')).toBe('int4');
    expect(component.getQuantClass('unknown')).toBe('');
  });

  it('formatDate converts timestamp to locale string', () => {
    const result = component.formatDate(1701388800);
    expect(result).toBeTruthy();
    // Just verify it returns a non-empty string (locale-dependent)
  });
});

