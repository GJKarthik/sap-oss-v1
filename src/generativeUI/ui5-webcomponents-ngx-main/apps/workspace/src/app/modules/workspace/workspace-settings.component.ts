// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2024 SAP SE
import { Component, ChangeDetectionStrategy, ChangeDetectorRef, ViewChild, ElementRef } from '@angular/core';
import { HttpClient } from '@angular/common/http';
import { catchError, of } from 'rxjs';
import { WorkspaceService } from '../../core/workspace.service';
import { NAV_LINK_DATA } from '../../core/workspace.types';

@Component({
  selector: 'ui-angular-workspace-settings',
  standalone: false,
  templateUrl: './workspace-settings.component.html',
  styleUrls: ['./workspace-settings.component.scss'],
  changeDetection: ChangeDetectionStrategy.OnPush,
})
export class WorkspaceSettingsComponent {
  @ViewChild('resetDialog') resetDialog!: ElementRef<any>;
  // fileInput ViewChild removed — now using ui5-file-uploader

  readonly allNavLinks = NAV_LINK_DATA;
  // Connection test status per service
  connectionStatus: Record<string, 'idle' | 'checking' | 'ok' | 'error'> = {};

  constructor(
    readonly ws: WorkspaceService,
    private readonly http: HttpClient,
    private readonly cdr: ChangeDetectorRef,
  ) {}

  // --- Identity ---

  onDisplayNameChange(event: Event): void {
    const value = (event.target as HTMLInputElement)?.value ?? '';
    this.ws.updateIdentity({ displayName: value });
  }

  onTeamNameChange(event: Event): void {
    const value = (event.target as HTMLInputElement)?.value ?? '';
    this.ws.updateIdentity({ teamName: value });
  }

  // --- Backend ---

  onBackendFieldChange(field: string, event: Event): void {
    const value = (event.target as HTMLInputElement)?.value ?? '';
    this.ws.updateBackend({ [field]: value });
  }

  testConnection(serviceUrl: string, key: string): void {
    this.connectionStatus[key] = 'checking';
    this.cdr.markForCheck();
    const healthUrl = serviceUrl.replace(/\/$/, '').replace(/\/mcp$/, '') + '/health';
    this.http.get(healthUrl, { observe: 'response' }).pipe(
      catchError(() => of({ status: 0 })),
    ).subscribe(response => {
      this.connectionStatus[key] = (response.status >= 200 && response.status < 400) ? 'ok' : 'error';
      this.cdr.markForCheck();
    });
  }

  // --- Navigation ---

  isNavVisible(path: string): boolean {
    const item = this.ws.navConfig().items.find(i => i.path === path);
    return !item || item.visible;
  }

  onNavToggle(path: string, event: Event): void {
    const checked = (event.target as any)?.checked ?? true;
    const items = [...this.ws.navConfig().items];
    const idx = items.findIndex(i => i.path === path);
    if (idx >= 0) {
      items[idx] = { ...items[idx], visible: checked };
    } else {
      items.push({ path, visible: checked, order: items.length });
    }
    this.ws.updateNav({ items });
  }

  onDefaultLandingChange(event: Event): void {
    const value = (event as CustomEvent)?.detail?.selectedOption?.value;
    if (value) {
      this.ws.updateNav({ defaultLandingPath: value });
    }
  }

  onThemeChange(event: Event): void {
    const theme = (event as CustomEvent)?.detail?.selectedOption?.value;
    if (theme) {
      this.ws.updateTheme(theme);
    }
  }

  onLanguageChange(event: Event): void {
    const language = (event as CustomEvent)?.detail?.selectedOption?.value;
    if (language) {
      this.ws.updateLanguage(language);
    }
  }

  // --- Model ---

  onDefaultModelChange(event: Event): void {
    const value = (event.target as HTMLInputElement)?.value ?? '';
    this.ws.updateModel({ defaultModel: value });
  }

  onTemperatureChange(event: Event): void {
    const value = parseFloat((event.target as any)?.value);
    if (!isNaN(value)) {
      this.ws.updateModel({ temperature: Math.min(2, Math.max(0, value)) });
    }
  }

  onSystemPromptChange(event: Event): void {
    const value = (event.target as HTMLTextAreaElement)?.value ?? '';
    this.ws.updateModel({ systemPrompt: value });
  }

  // --- Data Management ---

  exportSettings(): void {
    const json = this.ws.exportSettings();
    const blob = new Blob([json], { type: 'application/json' });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = 'workspace-settings.json';
    a.click();
    URL.revokeObjectURL(url);
  }

  onImportFile(event: Event): void {
    const detail = (event as CustomEvent)?.detail;
    const file = detail?.files?.[0] ?? (event.target as HTMLInputElement)?.files?.[0];
    if (!file) return;
    const reader = new FileReader();
    reader.onload = () => {
      const text = reader.result as string;
      this.ws.importSettings(text);
      this.cdr.markForCheck();
    };
    reader.readAsText(file);
  }

  openResetDialog(): void {
    this.resetDialog?.nativeElement?.show?.();
  }

  confirmReset(): void {
    this.ws.resetToDefaults();
    this.resetDialog?.nativeElement?.close?.();
    this.cdr.markForCheck();
  }

  cancelReset(): void {
    this.resetDialog?.nativeElement?.close?.();
  }
}
