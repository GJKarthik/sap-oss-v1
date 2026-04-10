import { of } from 'rxjs';
import { WorkspaceService } from './workspace.service';
import { createDefaultWorkspaceSettings } from './workspace.types';

describe('WorkspaceService', () => {
  const authService = {
    setResolvedIdentity: jest.fn(),
  };

  beforeEach(() => {
    localStorage.clear();
    window.history.replaceState({}, '', '/');
    authService.setResolvedIdentity.mockReset();
  });

  it('loads saved workspace settings on initialize', async () => {
    const saved = createDefaultWorkspaceSettings();
    saved.identity.displayName = 'Saved Operator';
    saved.identity.userId = 'tc-user-saved';
    localStorage.setItem('training.workspace.v1', JSON.stringify(saved));

    const http = {
      get: jest.fn(() => of({
        identity: {
          userId: 'btp.user@example.com',
          displayName: 'SAP Operator',
          teamName: 'Launch',
          email: 'btp.user@example.com',
        },
        settings: { ...saved, identity: { ...saved.identity, teamName: 'Launch' } },
        auth_source: 'edge_header',
        authenticated: true,
        has_saved_settings: true,
      })),
      put: jest.fn(() => of(null)),
    };

    const service = new WorkspaceService(http as never, authService as never);
    await service.initialize();

    expect(service.identity().displayName).toBe('SAP Operator');
    expect(service.identity().teamName).toBe('Launch');
    expect(service.activeWorkspace()).toEqual({ id: 'btp.user@example.com' });
    expect(authService.setResolvedIdentity).toHaveBeenCalledWith(expect.objectContaining({
      userId: 'btp.user@example.com',
      displayName: 'SAP Operator',
      authSource: 'edge_header',
      authenticated: true,
    }));
  });

  it('adopts the workspace query parameter and persists it locally in preview mode', async () => {
    window.history.replaceState({}, '', '/training/?workspace=shared-ws');

    const http = {
      get: jest.fn(() => of({
        identity: {
          userId: 'shared-ws',
          displayName: 'shared-ws',
          teamName: '',
          email: '',
        },
        settings: createDefaultWorkspaceSettings(),
        auth_source: 'workspace_hint',
        authenticated: false,
        has_saved_settings: false,
      })),
      put: jest.fn(() => of(null)),
    };

    const service = new WorkspaceService(http as never, authService as never);
    await service.initialize();

    expect(service.activeWorkspace()).toEqual({ id: 'shared-ws' });
    expect(localStorage.getItem('training.workspace.userId')).toBe('shared-ws');
    expect(JSON.parse(localStorage.getItem('training.workspace.v1') || '{}').identity?.userId).toBe('shared-ws');
  });
});
