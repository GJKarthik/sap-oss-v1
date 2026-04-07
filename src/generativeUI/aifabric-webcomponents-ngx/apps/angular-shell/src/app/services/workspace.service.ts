import { Injectable, signal, computed } from '@angular/core';
import { HttpClient } from '@angular/common/http';
import { Observable, of, Subject } from 'rxjs';
import { catchError, map, switchMap, debounceTime, takeUntil } from 'rxjs/operators';
import { environment } from '../../environments/environment';
import {
  WorkspaceSettings,
  WorkspaceIdentity,
  WorkspaceBackendConfig,
  WorkspaceNavConfig,
  WorkspaceModelPrefs,
  UseCaseWorkspace,
  CrossAppFeature,
  AppId,
  SEED_WORKSPACES,
  createDefaultWorkspaceSettings,
} from './workspace.types';
import { AI_FABRIC_NAV_ITEMS, AiFabricNavItem } from '../app.navigation';
import { CollaborationService } from './collaboration.service';

const STORAGE_KEY = 'aifabric.workspace.v1';
const SAVE_DEBOUNCE_MS = 1000;

/** This app's identity within the cross-app workspace federation */
const THIS_APP: AppId = 'aifabric';

@Injectable({ providedIn: 'root' })
export class WorkspaceService {
  private readonly _settings = signal<WorkspaceSettings>(createDefaultWorkspaceSettings());
  private readonly saveSubject = new Subject<void>();
  private readonly destroy$ = new Subject<void>();

  readonly settings = this._settings.asReadonly();
  readonly identity = computed(() => this._settings().identity);
  readonly backendConfig = computed(() => this._settings().backend);
  readonly navConfig = computed(() => this._settings().nav);
  readonly modelPreferences = computed(() => this._settings().model);

  // ─── Cross-App Workspace State ──────────────────────────────────
  private readonly _workspaces = signal<UseCaseWorkspace[]>(SEED_WORKSPACES);
  readonly workspaces = this._workspaces.asReadonly();

  /** The currently active use-case workspace */
  readonly activeWorkspace = computed(() => {
    const id = this._settings().activeWorkspaceId;
    return id ? this._workspaces().find(ws => ws.id === id) ?? null : null;
  });

  /** Features from the active workspace that belong to THIS app (native nav) */
  readonly localFeatures = computed(() => {
    const ws = this.activeWorkspace();
    if (!ws) return [];
    return ws.features.filter(f => f.sourceApp === THIS_APP);
  });

  /** Features from the active workspace that belong to OTHER apps (cross-app links) */
  readonly crossAppFeatures = computed(() => {
    const ws = this.activeWorkspace();
    if (!ws) return [];
    return ws.features.filter(f => f.sourceApp !== THIS_APP);
  });

  /** All features from the active workspace, with crossAppUrl resolved */
  readonly allFeatures = computed(() => {
    const ws = this.activeWorkspace();
    if (!ws) return [];
    return ws.features.map(f => ({
      ...f,
      crossAppUrl: f.sourceApp === THIS_APP ? undefined : (f.crossAppUrl || `/${f.sourceApp}${f.route}`),
    }));
  });

  readonly visibleNavItems = computed(() => {
    const ws = this.activeWorkspace();
    // When a workspace is active, filter nav to only features in the workspace
    if (ws) {
      const localIds = new Set(ws.features.filter(f => f.sourceApp === THIS_APP).map(f => f.id));
      return AI_FABRIC_NAV_ITEMS.filter(item => localIds.has(item.id));
    }
    // No workspace active: use per-user nav config
    const nav = this._settings().nav;
    const itemMap = new Map(nav.items.map(i => [i.id, i]));
    return AI_FABRIC_NAV_ITEMS
      .filter(item => {
        const wsItem = itemMap.get(item.id);
        return !wsItem || wsItem.visible;
      })
      .sort((a, b) => {
        const oa = itemMap.get(a.id)?.order ?? 999;
        const ob = itemMap.get(b.id)?.order ?? 999;
        return oa - ob;
      });
  });

  readonly effectiveApiBaseUrl = computed(() =>
    this._settings().backend.apiBaseUrl || environment.apiBaseUrl,
  );

  readonly effectiveElasticsearchMcpUrl = computed(() =>
    this._settings().backend.elasticsearchMcpUrl || environment.elasticsearchMcpUrl,
  );

  readonly effectivePalMcpUrl = computed(() =>
    this._settings().backend.palMcpUrl || environment.palMcpUrl,
  );

  constructor(
    private readonly http: HttpClient,
    private readonly collab: CollaborationService,
  ) {
    this.saveSubject.pipe(
      debounceTime(SAVE_DEBOUNCE_MS),
      switchMap(() => this.persistToServer()),
      takeUntil(this.destroy$),
    ).subscribe();
  }

  // ─── Cross-App Workspace Management ─────────────────────────────

  /** Switch to a use-case workspace. Re-scopes collab room, language, model. */
  switchWorkspace(workspaceId: string | null): void {
    this.patch(s => ({ ...s, activeWorkspaceId: workspaceId }));
    const ws = workspaceId ? this._workspaces().find(w => w.id === workspaceId) : null;
    if (ws) {
      // Re-join collab room scoped to this workspace
      this.collab.leaveRoom();
      this.collab.joinRoom(ws.collabRoomId).catch(() => {});
      // Apply workspace defaults
      if (ws.defaultModel) {
        this.updateModel({ defaultModel: ws.defaultModel });
      }
      if (ws.language) {
        this.updateLanguage(ws.language);
      }
    }
  }

  /** Get workspaces the current user belongs to */
  getMyWorkspaces(): UseCaseWorkspace[] {
    const userId = this._settings().identity.userId;
    return this._workspaces().filter(ws =>
      ws.team.members.some(m => m.userId === userId)
    );
  }

  /** Get all available workspaces */
  getAllWorkspaces(): UseCaseWorkspace[] {
    return this._workspaces();
  }

  /** Load workspaces from server (would replace seed data in production) */
  loadWorkspaces(): void {
    this.http.get<{ workspaces: UseCaseWorkspace[] }>(`${environment.apiBaseUrl}/workspaces`)
      .pipe(
        catchError(() => of({ workspaces: SEED_WORKSPACES })),
        takeUntil(this.destroy$),
      )
      .subscribe(res => this._workspaces.set(res.workspaces));
  }

  /** Navigate to a cross-app feature */
  navigateToFeature(feature: CrossAppFeature): void {
    if (feature.sourceApp === THIS_APP) {
      // Same app — use Angular router (caller handles this)
      return;
    }
    // Cross-app — navigate via URL
    const url = feature.crossAppUrl || `/${feature.sourceApp}${feature.route}`;
    // Pass workspace context via query param so the target app can join the same workspace
    const wsId = this._settings().activeWorkspaceId;
    const fullUrl = wsId ? `${url}?workspace=${wsId}` : url;
    window.location.href = fullUrl;
  }

  initialize(): void {
    const localRaw = this.loadFromLocalStorage();
    if (localRaw) {
      this._settings.set(localRaw);
    }
  }

  updateIdentity(patch: Partial<WorkspaceIdentity>): void {
    this.patch(s => ({ ...s, identity: { ...s.identity, ...patch } }));
  }

  updateBackend(patch: Partial<WorkspaceBackendConfig>): void {
    this.patch(s => ({ ...s, backend: { ...s.backend, ...patch } }));
  }

  updateNav(patch: Partial<WorkspaceNavConfig>): void {
    this.patch(s => ({ ...s, nav: { ...s.nav, ...patch } }));
  }

  updateModel(patch: Partial<WorkspaceModelPrefs>): void {
    this.patch(s => ({ ...s, model: { ...s.model, ...patch } }));
  }

  updateTheme(theme: string): void {
    this.patch(s => ({ ...s, theme }));
  }

  updateLanguage(language: string): void {
    this.patch(s => ({ ...s, language }));
  }

  exportSettings(): string {
    return JSON.stringify(this._settings(), null, 2);
  }

  importSettings(json: string): boolean {
    try {
      const parsed = JSON.parse(json) as WorkspaceSettings;
      if (parsed.version !== 1) return false;
      parsed.updatedAt = new Date().toISOString();
      this._settings.set(parsed);
      this.saveToLocalStorage(parsed);
      this.saveSubject.next();
      return true;
    } catch {
      return false;
    }
  }

  resetToDefaults(): void {
    const userId = this._settings().identity.userId;
    const defaults = createDefaultWorkspaceSettings();
    defaults.identity.userId = userId;
    defaults.updatedAt = new Date().toISOString();
    this._settings.set(defaults);
    this.saveToLocalStorage(defaults);
    this.saveSubject.next();
  }

  private patch(updater: (s: WorkspaceSettings) => WorkspaceSettings): void {
    const updated = updater(this._settings());
    updated.updatedAt = new Date().toISOString();
    this._settings.set(updated);
    this.saveToLocalStorage(updated);
    this.saveSubject.next();
  }

  private saveToLocalStorage(settings: WorkspaceSettings): void {
    try {
      localStorage.setItem(STORAGE_KEY, JSON.stringify(settings));
    } catch { /* storage full or unavailable */ }
  }

  private loadFromLocalStorage(): WorkspaceSettings | null {
    try {
      const raw = localStorage.getItem(STORAGE_KEY);
      if (!raw) return null;
      const parsed = JSON.parse(raw) as WorkspaceSettings;
      return parsed.version === 1 ? parsed : null;
    } catch {
      return null;
    }
  }

  private persistToServer(): Observable<void> {
    const settings = this._settings();
    const url = `${environment.apiBaseUrl.replace(/\/$/, '')}/workspace`;
    return this.http.put(url, settings).pipe(
      map(() => void 0),
      catchError(() => of(void 0)),
    );
  }
}
