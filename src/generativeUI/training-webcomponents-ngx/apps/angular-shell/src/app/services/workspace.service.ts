import { Injectable, signal, computed } from '@angular/core';
import { HttpClient } from '@angular/common/http';
import { Observable, of, Subject, firstValueFrom } from 'rxjs';
import { catchError, map, switchMap, debounceTime, takeUntil, tap } from 'rxjs/operators';
import { environment } from '../../environments/environment';
import { AuthService } from './auth.service';
import {
  WorkspaceSettings,
  WorkspaceIdentity,
  WorkspaceBackendConfig,
  WorkspaceNavConfig,
  WorkspaceModelPrefs,
  TRAINING_NAV_LINKS,
  TrainingNavLink,
  createDefaultWorkspaceSettings,
  normalizeWorkspaceTheme,
} from './workspace.types';

const STORAGE_KEY = 'training.workspace.v1';
const SAVE_DEBOUNCE_MS = 1000;
const USER_ID_STORAGE_KEY = 'training.workspace.userId';

interface WorkspaceBootstrapResponse {
  identity: {
    userId: string;
    displayName: string;
    teamName?: string;
    email?: string;
  };
  settings: WorkspaceSettings;
  auth_source: string;
  authenticated: boolean;
  has_saved_settings: boolean;
}

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

  constructor(
    private readonly http: HttpClient,
    private readonly authService: AuthService,
  ) {
    this.saveSubject.pipe(
      debounceTime(SAVE_DEBOUNCE_MS),
      switchMap(() => this.persistToServer()),
      takeUntil(this.destroy$),
    ).subscribe();
  }

  async initialize(): Promise<void> {
    const localRaw = this.loadFromLocalStorage();
    let currentSettings = localRaw
      ? this.normalizeSettings(localRaw)
      : createDefaultWorkspaceSettings();
    const externalWorkspaceId = this.workspaceIdFromUrl();
    if (externalWorkspaceId && externalWorkspaceId !== currentSettings.identity.userId) {
      currentSettings = {
        ...currentSettings,
        identity: { ...currentSettings.identity, userId: externalWorkspaceId },
      };
    }
    this._settings.set(currentSettings);
    this.saveToLocalStorage(currentSettings);
    this.syncResolvedIdentity(currentSettings.identity, 'local_storage', false);

    await this.bootstrapFromServer();
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
    this.patch((s: WorkspaceSettings) => ({ ...s, theme: normalizeWorkspaceTheme(theme) }));
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
      const normalized = this.normalizeSettings(parsed);
      normalized.identity = {
        ...this._settings().identity,
        teamName: normalized.identity.teamName || this._settings().identity.teamName,
      };
      normalized.updatedAt = new Date().toISOString();
      this._settings.set(normalized);
      this.saveToLocalStorage(normalized);
      const resolvedIdentity = this.authService.resolvedIdentity();
      this.syncResolvedIdentity(
        normalized.identity,
        resolvedIdentity?.authSource ?? 'local_import',
        resolvedIdentity?.authenticated ?? false,
        resolvedIdentity?.email ?? '',
      );
      this.saveSubject.next();
      return true;
    } catch {
      return false;
    }
  }

  resetToDefaults(): void {
    const identity = this._settings().identity;
    const defaults = createDefaultWorkspaceSettings();
    defaults.identity = { ...defaults.identity, ...identity };
    defaults.updatedAt = new Date().toISOString();
    this._settings.set(defaults);
    this.saveToLocalStorage(defaults);
    this.syncStoredUserId(identity.userId);
    this.syncResolvedIdentity(defaults.identity, 'local_reset', false);
    this.saveSubject.next();
  }

  private patch(updater: (s: WorkspaceSettings) => WorkspaceSettings): void {
    const updated = updater(this._settings());
    updated.updatedAt = new Date().toISOString();
    this._settings.set(updated);
    this.saveToLocalStorage(updated);
    const resolvedIdentity = this.authService.resolvedIdentity();
    this.syncResolvedIdentity(
      updated.identity,
      resolvedIdentity?.authSource ?? 'local_override',
      resolvedIdentity?.authenticated ?? false,
      resolvedIdentity?.email ?? '',
    );
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
    return this.http.put<WorkspaceBootstrapResponse>(url, settings, {
      headers: this.workspaceContextHeaders(settings),
    }).pipe(
      tap((response) => this.applyServerBootstrap(response, settings)),
      map(() => void 0),
      catchError(() => of(void 0)),
    );
  }

  private async bootstrapFromServer(): Promise<void> {
    const url = `${environment.apiBaseUrl.replace(/\/$/, '')}/workspace`;
    const currentSettings = this._settings();
    const response = await firstValueFrom(
      this.http.get<WorkspaceBootstrapResponse>(url, {
        headers: this.workspaceContextHeaders(currentSettings),
      }).pipe(
        catchError(() => of(null)),
      ),
    );

    if (!response) {
      return;
    }

    this.applyServerBootstrap(response, currentSettings);
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

  private normalizeSettings(settings: WorkspaceSettings): WorkspaceSettings {
    return {
      ...settings,
      theme: normalizeWorkspaceTheme(settings.theme),
    };
  }

  private applyServerBootstrap(
    response: WorkspaceBootstrapResponse,
    fallbackSettings: WorkspaceSettings,
  ): void {
    const candidateSettings = response.has_saved_settings
      ? this.normalizeSettings(response.settings)
      : fallbackSettings;

    const merged: WorkspaceSettings = {
      ...fallbackSettings,
      ...candidateSettings,
      backend: {
        ...fallbackSettings.backend,
        ...candidateSettings.backend,
      },
      nav: candidateSettings.nav?.items?.length ? candidateSettings.nav : fallbackSettings.nav,
      model: {
        ...fallbackSettings.model,
        ...candidateSettings.model,
      },
      identity: {
        userId: response.identity.userId || candidateSettings.identity.userId || fallbackSettings.identity.userId,
        displayName: response.identity.displayName || candidateSettings.identity.displayName || fallbackSettings.identity.displayName,
        teamName: response.identity.teamName ?? candidateSettings.identity.teamName ?? fallbackSettings.identity.teamName,
      },
      theme: normalizeWorkspaceTheme(candidateSettings.theme || fallbackSettings.theme),
      language: candidateSettings.language || fallbackSettings.language,
      updatedAt: candidateSettings.updatedAt || new Date().toISOString(),
    };

    this._settings.set(merged);
    this.saveToLocalStorage(merged);
    this.syncResolvedIdentity(merged.identity, response.auth_source, response.authenticated, response.identity.email);
  }

  private syncResolvedIdentity(
    identity: WorkspaceIdentity,
    authSource: string,
    authenticated: boolean,
    email = '',
  ): void {
    this.authService.setResolvedIdentity({
      userId: identity.userId,
      displayName: identity.displayName,
      email,
      authSource,
      authenticated,
    });
  }

  private workspaceContextHeaders(settings: WorkspaceSettings): Record<string, string> {
    const headers: Record<string, string> = {};
    if (settings.identity.userId.trim()) {
      headers['X-Workspace-User'] = settings.identity.userId.trim();
    }
    if (settings.identity.displayName.trim()) {
      headers['X-Workspace-Display-Name'] = settings.identity.displayName.trim();
    }
    if (settings.identity.teamName.trim()) {
      headers['X-Workspace-Team-Name'] = settings.identity.teamName.trim();
    }
    return headers;
  }
}
