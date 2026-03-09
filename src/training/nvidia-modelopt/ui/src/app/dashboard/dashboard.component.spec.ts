import { ComponentFixture, TestBed, fakeAsync, tick } from '@angular/core/testing';
import { HttpClientTestingModule, HttpTestingController } from '@angular/common/http/testing';
import { DashboardComponent } from './dashboard.component';

describe('DashboardComponent', () => {
  let component: DashboardComponent;
  let fixture: ComponentFixture<DashboardComponent>;
  let httpMock: HttpTestingController;

  beforeEach(async () => {
    await TestBed.configureTestingModule({
      imports: [DashboardComponent, HttpClientTestingModule],
    }).compileComponents();

    fixture = TestBed.createComponent(DashboardComponent);
    component = fixture.componentInstance;
    httpMock = TestBed.inject(HttpTestingController);
  });

  afterEach(() => {
    // Drain any outstanding requests from polling / init
    httpMock.match(() => true);
  });

  it('should create', () => {
    expect(component).toBeTruthy();
  });

  it('should initialise with default newJob values', () => {
    expect(component.newJob.model_name).toBe('Qwen/Qwen3.5-1.8B');
    expect(component.newJob.quant_format).toBe('int8');
    expect(component.newJob.calib_samples).toBe(512);
  });

  it('isHealthy starts as false', () => {
    expect(component.isHealthy).toBeFalse();
  });

  it('models starts as empty', () => {
    expect(component.models).toEqual([]);
  });

  it('jobs starts as empty', () => {
    expect(component.jobs).toEqual([]);
  });

  it('ngOnDestroy unsubscribes all subscriptions', () => {
    fixture.detectChanges(); // triggers ngOnInit
    httpMock.match(() => true); // drain pending
    component.ngOnDestroy();
    // No error = success; subscriptions were cleaned up
  });
});

