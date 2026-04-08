import { TestBed } from '@angular/core/testing';
import { Router } from '@angular/router';
import { AppLinkService } from './app-link.service';
import { WorkspaceService } from './workspace.service';

describe('AppLinkService', () => {
  const router = {
    navigateByUrl: jest.fn(),
  };

  const workspace = {
    activeWorkspace: jest.fn(() => ({ id: 'ws-shared' })),
  };

  beforeEach(() => {
    router.navigateByUrl.mockReset();
    workspace.activeWorkspace.mockClear();
    TestBed.resetTestingModule();
    TestBed.configureTestingModule({
      providers: [
        AppLinkService,
        { provide: Router, useValue: router },
        { provide: WorkspaceService, useValue: workspace },
      ],
    });
  });

  it('builds SAP AI Experience links with the shared workspace id', () => {
    const service = TestBed.inject(AppLinkService);

    expect(service.buildUrl('experience', '/ocr')).toBe('/ui5/ocr?workspace=ws-shared');
  });

  it('navigates within SAP AI Workbench without a full app reload', () => {
    const service = TestBed.inject(AppLinkService);

    service.navigate('training', '/chat');

    expect(router.navigateByUrl).toHaveBeenCalledWith('/chat');
  });

  it('resolves route labels from the central navigation model', () => {
    const service = TestBed.inject(AppLinkService);

    expect(service.targetLabelKey('training', '/rag-studio')).toBe('nav.ragStudio');
    expect(service.targetLabelKey('aifabric', '/rag')).toBe('crossApp.target.aifabricRag');
  });
});
