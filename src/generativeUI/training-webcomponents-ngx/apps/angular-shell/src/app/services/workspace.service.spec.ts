import { WorkspaceService } from './workspace.service';
import { createDefaultWorkspaceSettings } from './workspace.types';

describe('WorkspaceService', () => {
  beforeEach(() => {
    localStorage.clear();
    window.history.replaceState({}, '', '/');
  });

  it('loads saved workspace settings on initialize', () => {
    const saved = createDefaultWorkspaceSettings();
    saved.identity.displayName = 'Saved Operator';
    saved.identity.userId = 'tc-user-saved';
    localStorage.setItem('training.workspace.v1', JSON.stringify(saved));

    const service = new WorkspaceService({} as never);
    service.initialize();

    expect(service.identity().displayName).toBe('Saved Operator');
    expect(service.activeWorkspace()).toEqual({ id: 'tc-user-saved' });
  });

  it('adopts the workspace query parameter and persists it locally', () => {
    window.history.replaceState({}, '', '/training/?workspace=shared-ws');

    const service = new WorkspaceService({} as never);
    service.initialize();

    expect(service.activeWorkspace()).toEqual({ id: 'shared-ws' });
    expect(localStorage.getItem('training.workspace.userId')).toBe('shared-ws');
    expect(JSON.parse(localStorage.getItem('training.workspace.v1') || '{}').identity?.userId).toBe('shared-ws');
  });
});
