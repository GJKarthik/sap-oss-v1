import { NO_ERRORS_SCHEMA } from '@angular/core';
import { ComponentFixture, TestBed, fakeAsync, tick } from '@angular/core/testing';
import { provideHttpClient } from '@angular/common/http';
import { HttpTestingController, provideHttpClientTesting } from '@angular/common/http/testing';

import { GovernanceComponent } from './governance.component';
import { AuthService } from '../../services/auth.service';
import { I18nService } from '../../services/i18n.service';
import { ToastService } from '../../services/toast.service';
import { AppLinkService } from '../../services/app-link.service';

const API = '/api';

describe('GovernanceComponent', () => {
  let fixture: ComponentFixture<GovernanceComponent>;
  let component: GovernanceComponent;
  let httpMock: HttpTestingController;

  const auth = {
    getUserId: jest.fn(() => 'reviewer@example.com'),
  };
  const i18n = {
    t: (key: string) => key,
  };
  const toast = {
    error: jest.fn(),
  };
  const appLinks = {
    appDisplayNameKey: jest.fn(() => 'nav.training'),
    targetLabelKey: jest.fn(() => null),
    navigate: jest.fn(),
  };

  function runSummary(overrides: Record<string, unknown> = {}) {
    return {
      id: 'run-1',
      workflow_type: 'deployment',
      use_case_family: 'training',
      team: 'training-console',
      requested_by: 'training-user',
      run_name: 'Release 1',
      model_name: 'gpt2',
      dataset_ref: null,
      job_id: 'job-1',
      config_json: { source_job_id: 'job-1' },
      risk_tier: 'critical',
      risk_score: 90,
      approval_status: 'pending',
      gate_status: 'blocked',
      status: 'submitted',
      tag: null,
      blocking_checks: [{ gate_key: 'required_approvals', category: 'control', detail: 'Awaiting approval.', status: 'pending' }],
      created_at: '2026-04-15T00:00:00Z',
      updated_at: '2026-04-15T00:05:00Z',
      ...overrides,
    };
  }

  function approval(overrides: Record<string, unknown> = {}) {
    return {
      id: 'approval-1',
      run_id: 'run-1',
      workflow_type: 'deployment',
      title: 'Approve deployment',
      description: 'Required by policy',
      risk_level: 'critical',
      requested_by: 'training-user',
      approvers: ['team-lead', 'risk-owner'],
      status: 'pending',
      decisions: [],
      created_at: '2026-04-15T00:00:00Z',
      updated_at: '2026-04-15T00:01:00Z',
      ...overrides,
    };
  }

  function runDetail(overrides: Record<string, unknown> = {}) {
    return {
      ...runSummary(),
      approvals: [approval()],
      gate_checks: [
        {
          gate_key: 'required_approvals',
          category: 'control',
          status: 'pending',
          detail: 'Awaiting approval.',
          blocking: true,
        },
      ],
      metrics: [],
      artifacts: [],
      audit_entries: [
        {
          id: 'audit-1',
          created_at: '2026-04-15T00:02:00Z',
          record: { event_type: 'training_run_submitted' },
        },
      ],
      job: {
        id: 'job-1',
        status: 'completed',
        progress: 100,
        config: { model_name: 'gpt2' },
        created_at: '2026-04-15T00:00:00Z',
      },
      ...overrides,
    };
  }

  function flushInitialLoad(options: { approvalStatus?: 'pending' | 'approved'; gateStatus?: 'blocked' | 'passed' } = {}): void {
    const currentApproval = approval({ status: options.approvalStatus ?? 'pending' });
    const currentRun = runSummary({
      approval_status: options.approvalStatus ?? 'pending',
      gate_status: options.gateStatus ?? 'blocked',
      blocking_checks:
        options.gateStatus === 'passed'
          ? []
          : [{ gate_key: 'required_approvals', category: 'control', detail: 'Awaiting approval.', status: 'pending' }],
    });

    httpMock.expectOne((req) => req.url === `${API}/governance/approvals` && req.params.get('workflow_type') === '')
      .flush({ approvals: [currentApproval], total: 1 });
    httpMock.expectOne(`${API}/governance/policies`).flush({
      policies: [
        {
          id: 'policy-1',
          name: 'Deployment Approval Gate',
          description: 'All deployment runs require approval.',
          workflow_type: 'deployment',
          rule_type: 'approval',
          enabled: true,
          severity: 'high',
          condition_json: { always: true },
        },
      ],
    });
    httpMock.expectOne((req) =>
      req.url === `${API}/governance/training-runs`
      && req.params.get('workflow_type') === ''
      && req.params.get('risk_tier') === ''
      && req.params.get('status') === ''
      && req.params.get('team') === '',
    ).flush({ runs: [currentRun], total: 1 });
    httpMock.expectOne(`${API}/governance/training-runs/run-1`).flush(
      runDetail({
        approval_status: options.approvalStatus ?? 'pending',
        gate_status: options.gateStatus ?? 'blocked',
        approvals: [currentApproval],
        gate_checks: [
          {
            gate_key: 'required_approvals',
            category: 'control',
            status: options.approvalStatus === 'approved' ? 'passed' : 'pending',
            detail: options.approvalStatus === 'approved' ? 'Approval completed.' : 'Awaiting approval.',
            blocking: true,
          },
        ],
      }),
    );
  }

  beforeEach(async () => {
    await TestBed.configureTestingModule({
      imports: [GovernanceComponent],
      providers: [
        provideHttpClient(),
        provideHttpClientTesting(),
        { provide: AuthService, useValue: auth },
        { provide: I18nService, useValue: i18n },
        { provide: ToastService, useValue: toast },
        { provide: AppLinkService, useValue: appLinks },
      ],
    })
      .overrideComponent(GovernanceComponent, {
        add: { schemas: [NO_ERRORS_SCHEMA] },
      })
      .compileComponents();

    fixture = TestBed.createComponent(GovernanceComponent);
    component = fixture.componentInstance;
    httpMock = TestBed.inject(HttpTestingController);
    auth.getUserId.mockClear();
    toast.error.mockClear();
  });

  afterEach(() => {
    httpMock.verify();
  });

  it('loads approvals, policies, runs, and selected run detail on init', fakeAsync(() => {
    fixture.detectChanges();
    flushInitialLoad();
    tick();
    fixture.detectChanges();

    expect(component.approvals).toHaveLength(1);
    expect(component.policies).toHaveLength(1);
    expect(component.runs).toHaveLength(1);
    expect(component.selectedRun?.id).toBe('run-1');
    expect(component.blockedRunsCount()).toBe(1);
    expect(component.pendingApprovalsCount()).toBe(1);
    expect(component.approvals[0].title).toBe('Approve deployment');
    expect(component.selectedRun?.gate_checks?.[0].gate_key).toBe('required_approvals');
  }));

  it('submits an approval decision and refreshes the queue/detail state', fakeAsync(() => {
    fixture.detectChanges();
    flushInitialLoad();
    tick();

    component.decideApproval(component.approvals[0], 'approve');

    const decisionReq = httpMock.expectOne(`${API}/governance/approvals/approval-1/decide`);
    expect(decisionReq.request.method).toBe('POST');
    expect(decisionReq.request.body).toEqual({
      approver: 'reviewer@example.com',
      action: 'approve',
      comment: 'Approved by reviewer.',
    });
    decisionReq.flush(approval({ status: 'approved', decisions: [{ approver: 'reviewer@example.com', action: 'approve' }] }));

    flushInitialLoad({ approvalStatus: 'approved', gateStatus: 'passed' });
    tick();

    expect(component.approvals[0].status).toBe('approved');
    expect(component.selectedRun?.gate_status).toBe('passed');
    expect(toast.error).not.toHaveBeenCalled();
  }));
});
