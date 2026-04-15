import { NO_ERRORS_SCHEMA } from '@angular/core';
import { ComponentFixture, TestBed, fakeAsync, tick } from '@angular/core/testing';
import { provideHttpClient } from '@angular/common/http';
import { HttpTestingController, provideHttpClientTesting } from '@angular/common/http/testing';
import { DeploymentsComponent } from './deployments.component';

const API = '/api';

describe('DeploymentsComponent', () => {
  let fixture: ComponentFixture<DeploymentsComponent>;
  let component: DeploymentsComponent;
  let httpMock: HttpTestingController;

  beforeEach(async () => {
    await TestBed.configureTestingModule({
      imports: [DeploymentsComponent],
      providers: [provideHttpClient(), provideHttpClientTesting()],
    })
      .overrideComponent(DeploymentsComponent, {
        add: {
          schemas: [NO_ERRORS_SCHEMA],
        },
      })
      .compileComponents();

    fixture = TestBed.createComponent(DeploymentsComponent);
    component = fixture.componentInstance;
    httpMock = TestBed.inject(HttpTestingController);
  });

  afterEach(() => {
    httpMock.verify();
  });

  function flushInitialLoad(): void {
    httpMock.expectOne(`${API}/governance/training-runs?workflow_type=deployment`).flush({
      runs: [
        {
          id: 'deployment-run-1',
          workflow_type: 'deployment',
          run_name: 'Release 1',
          requested_by: 'training-user',
          team: 'training-console',
          config_json: { scenario_id: 'release-1' },
          risk_tier: 'critical',
          risk_score: 90,
          approval_status: 'pending',
          gate_status: 'pending_approval',
          status: 'submitted',
          job_id: 'job-1',
          blocking_checks: [{ gate_key: 'required_approvals', category: 'control', detail: 'Awaiting approval.', status: 'pending' }],
          created_at: '2026-04-14T00:00:00Z',
        },
      ],
      total: 1,
    });
    httpMock.expectOne(`${API}/jobs`).flush([
      {
        id: 'job-1',
        status: 'completed',
        progress: 100,
        config: { model_name: 'llama' },
        created_at: '2026-04-14T00:00:00Z',
      },
    ]);
  }

  it('loads governed deployment runs on init', fakeAsync(() => {
    fixture.detectChanges();
    flushInitialLoad();
    tick();

    expect(component.deployments).toHaveLength(1);
    expect(component.deployments[0].id).toBe('deployment-run-1');
    expect(component.loading).toBe(false);
  }));

  it('opens the governed deployment creation form', fakeAsync(() => {
    fixture.detectChanges();
    flushInitialLoad();
    tick();

    component.toggleCreateForm();
    fixture.detectChanges();

    expect(component.showCreateForm).toBe(true);
    expect(fixture.nativeElement.textContent).toContain('Completed job');
  }));

  it('creates and launches a deployment run from a completed job', fakeAsync(() => {
    fixture.detectChanges();
    flushInitialLoad();
    tick();

    component.showCreateForm = true;
    component.selectedJobId = 'job-1';
    component.draftScenarioId = 'release-1';
    component.createDeployment();

    httpMock.expectOne(`${API}/governance/training-runs`).flush({
      id: 'deployment-run-2',
      workflow_type: 'deployment',
      run_name: 'release-1',
      requested_by: 'training-user',
      team: 'training-console',
      config_json: {},
      risk_tier: 'critical',
      risk_score: 90,
      approval_status: 'pending',
      gate_status: 'draft',
      status: 'draft',
      blocking_checks: [],
      created_at: '2026-04-14T00:00:00Z',
    });
    httpMock.expectOne(`${API}/governance/training-runs/deployment-run-2/submit`).flush({});
    httpMock.expectOne(`${API}/governance/training-runs/deployment-run-2/launch`).flush({});
    flushInitialLoad();
    tick();

    expect(component.showCreateForm).toBe(false);
    expect(component.selectedJobId).toBe('');
  }));

  it('shows blocking details when deployment launch is rejected by governance', fakeAsync(() => {
    fixture.detectChanges();
    flushInitialLoad();
    tick();

    component.setTargetStatus(component.deployments[0], 'RUNNING');

    httpMock.expectOne(`${API}/governance/training-runs/deployment-run-1/launch`).flush(
      { detail: { blocking_checks: [{ detail: 'Awaiting approval.' }] } },
      { status: 409, statusText: 'Conflict' }
    );
    flushInitialLoad();
    tick();

    expect(component.mutating).toBe(false);
    expect(component.deployments).toHaveLength(1);
  }));
});
