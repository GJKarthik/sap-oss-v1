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
  TRAINING_NAV_LINKS,
  TrainingNavLink,
  createDefaultWorkspaceSettings,
} from './workspace.types';

const STORAGE_KEY = 'training.workspace.v1';
const SAVE_DEBOUNCE_MS = 1000;
const USER_ID_STORAGE_KEY = 'training.workspace.userId';

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

  readonly visibleNavLinks = computed((): TrainingNavLink[] => {
    const nav = this._settings().nav;
    const itemMap = new Map(nav.items.map((i: { route: string; visible: boolean; order: number }) => [i.route, i]));
    return TRAINING_NAV_LINKS
      .filter((link: TrainingNavLink) => {
        const item = itemMap.get(link.route);
        return !item || item.visible;
      })
      .sort((a: TrainingNavLink, b: TrainingNavLink) => {
        const oa = itemMap.get(a.route)?.order ?? 999;
        const ob = itemMap.get(b.route)?.order ?? 999;
        return oa - ob;
      });
  });

  activeWorkspace(): { id: string } | null {
    const id = this._settings().identity.userId.trim();
    return id ? { id } : null;
  }

  readonly effectiveApiBaseUrl = computed(() =>
    this._settings().backend.apiBaseUrl || environment.apiBaseUrl,
  );

  constructor(private readonly http: HttpClient) {
    this.saveSubject.pipe(
      debounceTime(SAVE_DEBOUNCE_MS),
      switchMap(() => this.persistToServer()),
      takeUntil(this.destroy$),
    ).subscribe();
  }

  initialize(): void {
    const localRaw = this.loadFromLocalStorage();
    if (localRaw) {
      this._settings.set(localRaw);
    }
    this.syncStoredUserId(this._settings().identity.userId);

    const externalWorkspaceId = this.workspaceIdFromUrl();
    if (externalWorkspaceId && externalWorkspaceId !== this._settings().identity.userId) {
      this.patch((s: WorkspaceSettings) => ({
        ...s,
        identity: { ...s.identity, userId: externalWorkspaceId },
      }));
      return;
    }
  }

  updateIdentity(patch: Partial<WorkspaceIdentity>): void {
    this.patch((s: WorkspaceSettings) => ({ ...s, identity: { ...s.identity, ...patch } }));
  }

  updateBackend(patch: Partial<WorkspaceBackendConfig>): void {
    this.patch((s: WorkspaceSettings) => ({ ...s, backend: { ...s.backend, ...patch } }));
  }

  updateNav(patch: Partial<WorkspaceNavConfig>): void {
    this.patch((s: WorkspaceSettings) => ({ ...s, nav: { ...s.nav, ...patch } }));
  }

  updateModel(patch: Partial<WorkspaceModelPrefs>): void {
    this.patch((s: WorkspaceSettings) => ({ ...s, model: { ...s.model, ...patch } }));
  }

  updateTheme(theme: string): void {
    this.patch((s: WorkspaceSettings) => ({ ...s, theme }));
  }

  updateLanguage(language: string): void {
    this.patch((s: WorkspaceSettings) => ({ ...s, language }));
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
    this.syncStoredUserId(userId);
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
      this.syncStoredUserId(settings.identity.userId);
    } catch { /* storage full */ }
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

  private workspaceIdFromUrl(): string | null {
    if (typeof window === 'undefined') {
      return null;
    }

    const workspaceId = new URLSearchParams(window.location.search).get('workspace')?.trim();
    return workspaceId || null;
  }

  private syncStoredUserId(userId: string): void {
    try {
      if (typeof localStorage !== 'undefined' && userId) {
        localStorage.setItem(USER_ID_STORAGE_KEY, userId);
      }
    } catch {
      // ignore storage errors
    }
  }
}
