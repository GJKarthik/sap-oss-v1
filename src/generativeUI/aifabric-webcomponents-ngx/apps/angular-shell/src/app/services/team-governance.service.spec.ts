import { TestBed } from '@angular/core/testing';
import { HttpTestingController, provideHttpClientTesting } from '@angular/common/http/testing';
import { provideHttpClient } from '@angular/common/http';
import { firstValueFrom, skip } from 'rxjs';
import { environment } from '../../environments/environment';
import { TeamGovernanceService, PendingApproval, PolicyViolation } from './team-governance.service';
import { TeamConfigService, TeamConfig, GovernancePolicyConfig } from './team-config.service';

const GOV_API = `${environment.apiBaseUrl}/governance`;
const TEAM_API = `${environment.apiBaseUrl}/team`;

function makePolicy(overrides: Partial<GovernancePolicyConfig> = {}): GovernancePolicyConfig {
  return {
    id: 'policy-1', name: 'deploy_model', ruleType: 'approval',
    active: true, requireApprovalCount: 2, approverRoles: ['admin', 'editor'],
    ...overrides,
  };
}

function loadTeamWithPolicies(
  teamConfigService: TeamConfigService,
  httpMock: HttpTestingController,
  policies: GovernancePolicyConfig[] = [makePolicy()],
): void {
  teamConfigService.loadTeamConfig();
  httpMock.expectOne(TEAM_API).flush({
    teamId: 'team-1', teamName: 'Test Team',
    members: [
      { userId: 'admin-1', displayName: 'Admin', role: 'admin', joinedAt: '2026-01-01' },
      { userId: 'editor-1', displayName: 'Editor', role: 'editor', joinedAt: '2026-01-01' },
      { userId: 'viewer-1', displayName: 'Viewer', role: 'viewer', joinedAt: '2026-01-01' },
    ],
    settings: { defaultModel: 'gpt-4', dataSources: [], governancePolicies: policies, promptTemplates: [] },
    createdAt: '2026-01-01', updatedAt: '2026-01-01',
  } satisfies TeamConfig);
}

describe('TeamGovernanceService', () => {
  let service: TeamGovernanceService;
  let teamConfig: TeamConfigService;
  let httpMock: HttpTestingController;

  beforeEach(() => {
    TestBed.configureTestingModule({
      providers: [TeamGovernanceService, TeamConfigService, provideHttpClient(), provideHttpClientTesting()],
    });
    service = TestBed.inject(TeamGovernanceService);
    teamConfig = TestBed.inject(TeamConfigService);
    httpMock = TestBed.inject(HttpTestingController);
  });

  afterEach(() => {
    httpMock.verify();
  });

  describe('isBlocked', () => {
    it('returns true for hardcoded blocked actions', () => {
      expect(service.isBlocked('drop_table')).toBe(true);
      expect(service.isBlocked('delete_all')).toBe(true);
      expect(service.isBlocked('admin_reset')).toBe(true);
    });

    it('returns false for non-blocked actions without config', () => {
      expect(service.isBlocked('deploy_model')).toBe(false);
    });

    it('returns true for policy-blocked actions', () => {
      loadTeamWithPolicies(teamConfig, httpMock, [
        makePolicy({ name: 'dangerous_action', ruleType: 'block' }),
      ]);
      expect(service.isBlocked('dangerous_action')).toBe(true);
    });
  });

  describe('requiresApproval', () => {
    it('returns false when action is blocked (blocked takes precedence)', () => {
      expect(service.requiresApproval('drop_table')).toBe(false);
    });

    it('returns true for approval-type policies', () => {
      loadTeamWithPolicies(teamConfig, httpMock);
      expect(service.requiresApproval('deploy_model')).toBe(true);
    });

    it('returns false for unknown actions', () => {
      loadTeamWithPolicies(teamConfig, httpMock);
      expect(service.requiresApproval('unknown_action')).toBe(false);
    });
  });

  describe('createApprovalRequest', () => {
    it('returns null and emits violation for blocked actions', async () => {
      const violationPromise = firstValueFrom(service.violations$);
      const result = service.createApprovalRequest('drop_table', 'Drop table', {}, 'user-1');
      expect(result).toBeNull();
      const violation = await violationPromise;
      expect(violation.type).toBe('blocked');
      expect(violation.actionName).toBe('drop_table');
    });

    it('creates a pending approval with correct fields', () => {
      loadTeamWithPolicies(teamConfig, httpMock);
      const result = service.createApprovalRequest('deploy_model', 'Deploy model X', { model: 'x' }, 'user-1');
      expect(result).toBeTruthy();
      expect(result!.actionName).toBe('deploy_model');
      expect(result!.status).toBe('pending');
      expect(result!.requiredApprovals).toBe(2);
      expect(result!.currentApprovals).toEqual([]);
      httpMock.expectOne(`${GOV_API}/approvals`).flush({});
    });
  });

  describe('submitDecision', () => {
    let approval: PendingApproval;

    beforeEach(() => {
      loadTeamWithPolicies(teamConfig, httpMock);
      approval = service.createApprovalRequest('deploy_model', 'Deploy', {}, 'user-1')!;
      httpMock.expectOne(`${GOV_API}/approvals`).flush({});
    });

    it('rejects immediately on reject decision', () => {
      service.submitDecision(approval.id, 'admin-1', 'Admin', 'admin', 'reject', 'Too risky');
      httpMock.expectOne(`${GOV_API}/approvals/${approval.id}`).flush({});
      expect(approval.status).toBe('rejected');
      expect(approval.currentApprovals).toHaveLength(1);
      expect(approval.currentApprovals[0].reason).toBe('Too risky');
    });

    it('approves when threshold is met', () => {
      service.submitDecision(approval.id, 'admin-1', 'Admin', 'admin', 'approve');
      httpMock.expectOne(`${GOV_API}/approvals/${approval.id}`).flush({});
      expect(approval.status).toBe('pending');

      service.submitDecision(approval.id, 'editor-1', 'Editor', 'editor', 'approve');
      httpMock.expectOne(`${GOV_API}/approvals/${approval.id}`).flush({});
      expect(approval.status).toBe('approved');
    });

    it('ignores decisions on non-pending approvals', () => {
      approval.status = 'rejected';
      service.submitDecision(approval.id, 'admin-1', 'Admin', 'admin', 'approve');
      expect(approval.currentApprovals).toHaveLength(0);
    });
  });

  describe('canApprove', () => {
    beforeEach(() => {
      loadTeamWithPolicies(teamConfig, httpMock);
    });

    it('returns true for users with approved roles', () => {
      expect(service.canApprove('admin-1', 'deploy_model')).toBe(true);
      expect(service.canApprove('editor-1', 'deploy_model')).toBe(true);
    });

    it('returns false for users without approved roles', () => {
      expect(service.canApprove('viewer-1', 'deploy_model')).toBe(false);
    });

    it('returns false for unknown users', () => {
      expect(service.canApprove('unknown', 'deploy_model')).toBe(false);
    });

    it('returns false for unknown policies', () => {
      expect(service.canApprove('admin-1', 'unknown_action')).toBe(false);
    });
  });
});
