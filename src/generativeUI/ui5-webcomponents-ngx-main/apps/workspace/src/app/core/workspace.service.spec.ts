import { firstValueFrom, of } from 'rxjs';
import { WorkspaceService } from './workspace.service';
import { createDefaultWorkspaceSettings } from './workspace.types';

function makeHttp() {
  return {
    get: jest.fn().mockReturnValue(of({ status: 204, body: null })),
    put: jest.fn().mockReturnValue(of({})),
  };
}

describe('WorkspaceService', () => {
  beforeEach(() => {
    localStorage.clear();
    window.history.replaceState({}, '', '/');
  });

  it('loads saved settings before the server reconciliation step', async () => {
    const saved = createDefaultWorkspaceSettings();
    saved.identity.displayName = 'Saved Workspace';
    saved.identity.userId = 'ws-user-saved';
    localStorage.setItem('sap-ai-experience.workspace.v1', JSON.stringify(saved));

    const http = makeHttp();
    const service = new WorkspaceService(http as never);
    await firstValueFrom(service.initialize());

    expect(service.identity().displayName).toBe('Saved Workspace');
    expect(http.get).toHaveBeenCalledWith(
      expect.stringContaining(encodeURIComponent('ws-user-saved')),
      { observe: 'response' },
    );
  });

  it('adopts the shared workspace query parameter and persists it', async () => {
    window.history.replaceState({}, '', '/ui5/?workspace=shared-ui5');

    const service = new WorkspaceService(makeHttp() as never);
    await firstValueFrom(service.initialize());

    expect(service.activeWorkspace()).toEqual({ id: 'shared-ui5' });
    expect(localStorage.getItem('sap-ai-experience.workspace.userId')).toBe('shared-ui5');
    expect(JSON.parse(localStorage.getItem('sap-ai-experience.workspace.v1') || '{}').identity?.userId).toBe('shared-ui5');
  });

  it('keeps home discovery available even when a shell route is hidden', async () => {
    const saved = createDefaultWorkspaceSettings();
    saved.nav.items = saved.nav.items.map((item) =>
      item.path === '/ocr' ? { ...item, visible: false } : item,
    );
    localStorage.setItem('sap-ai-experience.workspace.v1', JSON.stringify(saved));

    const service = new WorkspaceService(makeHttp() as never);
    await firstValueFrom(service.initialize());

    expect(service.visibleNavLinks().some((link) => link.path === '/ocr')).toBe(false);
    expect(service.visibleHomeCards().some((card) => card.path === '/ocr')).toBe(true);
  });
});
