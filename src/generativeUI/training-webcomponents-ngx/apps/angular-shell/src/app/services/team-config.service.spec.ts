import { TestBed } from '@angular/core/testing';
import { HttpTestingController, provideHttpClientTesting } from '@angular/common/http/testing';
import { provideHttpClient } from '@angular/common/http';
import { firstValueFrom, skip } from 'rxjs';
import { environment } from '../../environments/environment';
import { TeamConfigService, TeamConfig, TeamMemberConfig, TeamSettings } from './team-config.service';

const API = `${environment.apiBaseUrl}/team`;

function makeTeamConfig(overrides: Partial<TeamConfig> = {}): TeamConfig {
  return {
    teamId: 'team-1',
    teamName: 'Test Team',
    members: [
      { userId: 'admin-1', displayName: 'Admin', role: 'admin', joinedAt: '2026-01-01T00:00:00Z' },
      { userId: 'editor-1', displayName: 'Editor', role: 'editor', joinedAt: '2026-01-01T00:00:00Z' },
      { userId: 'viewer-1', displayName: 'Viewer', role: 'viewer', joinedAt: '2026-01-01T00:00:00Z' },
    ],
    settings: {
      defaultModel: 'gpt-4',
      dataSources: [],
      governancePolicies: [],
      promptTemplates: [],
    },
    createdAt: '2026-01-01T00:00:00Z',
    updatedAt: '2026-01-01T00:00:00Z',
    ...overrides,
  };
}

describe('TeamConfigService', () => {
  let service: TeamConfigService;
  let httpMock: HttpTestingController;

  beforeEach(() => {
    TestBed.configureTestingModule({
      providers: [TeamConfigService, provideHttpClient(), provideHttpClientTesting()],
    });
    service = TestBed.inject(TeamConfigService);
    httpMock = TestBed.inject(HttpTestingController);
  });

  afterEach(() => {
    httpMock.verify();
  });

  describe('getTeamConfig', () => {
    it('returns null initially', () => {
      expect(service.getTeamConfig()).toBeNull();
    });
  });

  describe('loadTeamConfig', () => {
    it('loads config from API', async () => {
      const configPromise = firstValueFrom(service.teamConfig$.pipe(skip(1)));
      service.loadTeamConfig();
      httpMock.expectOne(API).flush(makeTeamConfig());
      const config = await configPromise;
      expect(config?.teamId).toBe('team-1');
      expect(config?.members).toHaveLength(3);
    });

    it('falls back to default config on error', async () => {
      const configPromise = firstValueFrom(service.teamConfig$.pipe(skip(1)));
      service.loadTeamConfig();
      httpMock.expectOne(API).error(new ProgressEvent('error'));
      const config = await configPromise;
      expect(config?.teamId).toBe('default');
      expect(config?.teamName).toBe('Default Team');
    });

    it('sets loading state during fetch', async () => {
      const loadingPromise = firstValueFrom(service.loading$.pipe(skip(1)));
      service.loadTeamConfig();
      const loading = await loadingPromise;
      expect(loading).toBe(true);
      httpMock.expectOne(API).flush(makeTeamConfig());
    });
  });

  describe('updateSettings', () => {
    it('does nothing when no config is loaded', () => {
      service.updateSettings({ defaultModel: 'gpt-3.5' });
      expect(service.getTeamConfig()).toBeNull();
    });

    it('updates settings optimistically and sends PATCH', async () => {
      service.loadTeamConfig();
      httpMock.expectOne(API).flush(makeTeamConfig());

      service.updateSettings({ defaultModel: 'gpt-3.5' });
      expect(service.getTeamConfig()?.settings.defaultModel).toBe('gpt-3.5');

      const req = httpMock.expectOne(`${API}/settings`);
      expect(req.request.method).toBe('PATCH');
      expect(req.request.body).toEqual({ defaultModel: 'gpt-3.5' });
      req.flush({});
    });
  });

  describe('addMember', () => {
    it('adds member optimistically and sends POST', () => {
      service.loadTeamConfig();
      httpMock.expectOne(API).flush(makeTeamConfig({ members: [] }));

      service.addMember({ userId: 'new-1', displayName: 'New User', role: 'viewer' });
      expect(service.getTeamConfig()?.members).toHaveLength(1);
      expect(service.getTeamConfig()?.members[0].userId).toBe('new-1');

      const req = httpMock.expectOne(`${API}/members`);
      expect(req.request.method).toBe('POST');
      req.flush({});
    });
  });

  describe('updateMemberRole', () => {
    it('updates member role optimistically and sends PATCH', () => {
      service.loadTeamConfig();
      httpMock.expectOne(API).flush(makeTeamConfig());

      service.updateMemberRole('viewer-1', 'editor');
      const member = service.getTeamConfig()?.members.find(m => m.userId === 'viewer-1');
      expect(member?.role).toBe('editor');

      const req = httpMock.expectOne(`${API}/members/viewer-1`);
      expect(req.request.method).toBe('PATCH');
      req.flush({});
    });
  });

  describe('hasRole', () => {
    beforeEach(() => {
      service.loadTeamConfig();
      httpMock.expectOne(API).flush(makeTeamConfig());
    });

    it('returns false when no config is loaded', () => {
      // Create a fresh TestBed without loading config
      TestBed.resetTestingModule();
      TestBed.configureTestingModule({
        providers: [TeamConfigService, provideHttpClient(), provideHttpClientTesting()],
      });
      const fresh = TestBed.inject(TeamConfigService);
      expect(fresh.hasRole('admin-1', 'admin')).toBe(false);
      // Re-setup for remaining tests
      TestBed.resetTestingModule();
      TestBed.configureTestingModule({
        providers: [TeamConfigService, provideHttpClient(), provideHttpClientTesting()],
      });
      service = TestBed.inject(TeamConfigService);
      httpMock = TestBed.inject(HttpTestingController);
      service.loadTeamConfig();
      httpMock.expectOne(API).flush(makeTeamConfig());
    });

    it('returns false for non-member', () => {
      expect(service.hasRole('unknown', 'viewer')).toBe(false);
    });

    it('viewer role returns true for any member', () => {
      expect(service.hasRole('viewer-1', 'viewer')).toBe(true);
      expect(service.hasRole('editor-1', 'viewer')).toBe(true);
      expect(service.hasRole('admin-1', 'viewer')).toBe(true);
    });

    it('editor role returns true for editor and admin', () => {
      expect(service.hasRole('viewer-1', 'editor')).toBe(false);
      expect(service.hasRole('editor-1', 'editor')).toBe(true);
      expect(service.hasRole('admin-1', 'editor')).toBe(true);
    });

    it('admin role returns true only for admin', () => {
      expect(service.hasRole('viewer-1', 'admin')).toBe(false);
      expect(service.hasRole('editor-1', 'admin')).toBe(false);
      expect(service.hasRole('admin-1', 'admin')).toBe(true);
    });
  });
});
