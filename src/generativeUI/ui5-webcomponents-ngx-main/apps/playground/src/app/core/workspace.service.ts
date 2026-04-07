// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2024 SAP SE

import { Injectable, signal, computed } from '@angular/core';
import { HttpClient } from '@angular/common/http';
import { Observable, of, timer, Subject } from 'rxjs';
import { catchError, map, switchMap, tap, debounceTime, takeUntil } from 'rxjs/operators';
import { environment } from '../../environments/environment';
import {
  WorkspaceSettings,
  WorkspaceIdentity,
  WorkspaceBackendConfig,
  WorkspaceNavConfig,
  WorkspaceModelPrefs,
  NavLinkDatum,
  NAV_LINK_DATA,
  createDefaultWorkspaceSettings,
} from './workspace.types';

const STORAGE_KEY = 'playground.workspace.v1';
const SAVE_DEBOUNCE_MS = 1000;

@Injectable({ providedIn: 'root' })
export class WorkspaceService {
  private readonly _settings = signal<WorkspaceSettings>(createDefaultWorkspaceSettings());
  private readonly saveSubject = new Subject<void>();
  private readonly destroy$ = new Subject<void>();

  // --------------- Public readonly signals ---------------

  readonly settings = this._settings.asReadonly();

  readonly identity = computed(() => this._settings().identity);
  readonly backendConfig = computed(() => this._settings().backend);
  readonly navConfig = computed(() => this._settings().nav);
  readonly modelPreferences = computed(() => this._settings().model);

  readonly visibleNavLinks = computed(() => {
    const nav = this._settings().nav;
    const itemMap = new Map(nav.items.map(i => [i.path, i]));
    return NAV_LINK_DATA
      .filter(link => {
        const item = itemMap.get(link.path);
        return !item || item.visible;
      })
      .sort((a, b) => {
        const oa = itemMap.get(a.path)?.order ?? 999;
        const ob = itemMap.get(b.path)?.order ?? 999;
        return oa - ob;
      });
  });

  readonly visibleHomeCards = computed(() =>
    this.visibleNavLinks().filter(l => l.showOnHome && l.path !== '/' && l.path !== '/workspace'),
  );

  readonly effectiveOpenAiBaseUrl = computed(() =>
    this._settings().backend.openAiBaseUrl || environment.openAiBaseUrl,
  );

  readonly effectiveMcpBaseUrl = computed(() =>
    this._settings().backend.mcpBaseUrl || environment.mcpBaseUrl,
  );

  readonly effectiveAgUiEndpoint = computed(() =>
    this._settings().backend.agUiEndpoint || environment.agUiEndpoint,
  );

  constructor(private readonly http: HttpClient) {
    this.saveSubject.pipe(
      debounceTime(SAVE_DEBOUNCE_MS),
      switchMap(() => this.persistToServer()),
      takeUntil(this.destroy$),
    ).subscribe();
  }

  // --------------- Initialization ---------------

  initialize(): Observable<void> {
    const userId = this._settings().identity.userId;
    const url = `${environment.openAiBaseUrl.replace(/\/$/, '')}/v1/workspace?userId=${encodeURIComponent(userId)}`;

    return this.http.get<WorkspaceSettings>(url, { observe: 'response' }).pipe(
      map(response => {
        if (response.status === 200 && response.body && response.body.version === 1) {
          return response.body;
        }
        return null;
      }),
      catchError(() => of(null)),
      map(serverSettings => {
        if (serverSettings) {
          this._settings.set(serverSettings);
          this.saveToLocalStorage(serverSettings);
          return;
        }
        const localRaw = this.loadFromLocalStorage();
        if (localRaw) {
          this._settings.set(localRaw);
          return;
        }
        // defaults already set via signal init
      }),
    );
  }

  // --------------- Mutators ---------------

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

  // --------------- Data Management ---------------

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

  // --------------- Private helpers ---------------

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
    } catch {
      // storage full or unavailable
    }
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
    const url = `${environment.openAiBaseUrl.replace(/\/$/, '')}/v1/workspace`;
    return this.http.put(url, settings).pipe(
      map(() => void 0),
      catchError(() => of(void 0)),
    );
  }
}
