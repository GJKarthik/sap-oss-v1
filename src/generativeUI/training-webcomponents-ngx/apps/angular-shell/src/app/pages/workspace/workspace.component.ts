import { Component, ChangeDetectionStrategy, inject, ViewChild, ElementRef } from '@angular/core';
import { CommonModule } from '@angular/common';
import { FormsModule } from '@angular/forms';
import { HttpClient } from '@angular/common/http';
import { catchError, of } from 'rxjs';
import { WorkspaceService } from '../../services/workspace.service';
import { TRAINING_NAV_LINKS } from '../../services/workspace.types';
import { I18nService } from '../../services/i18n.service';
import { Ui5TrainingComponentsModule } from '../../shared/ui5-training-components.module';

@Component({
  selector: 'app-workspace',
  standalone: true,
  imports: [CommonModule, Ui5TrainingComponentsModule, FormsModule],
  changeDetection: ChangeDetectionStrategy.OnPush,
  template: `
    <div class="workspace-page">
      <ui5-breadcrumbs>
        <ui5-breadcrumbs-item href="/dashboard" text="Home"></ui5-breadcrumbs-item>
        <ui5-breadcrumbs-item text="Workspace Settings"></ui5-breadcrumbs-item>
      </ui5-breadcrumbs>
      <div class="workspace-hero">
        <h2>{{ i18n.t('workspace.title') }}</h2>
        <p class="workspace-hero__subtitle">{{ i18n.t('workspace.subtitle') }}</p>
      </div>

      <div class="workspace-grid">
        <!-- Identity -->
        <ui5-card>
          <ui5-card-header slot="header" [attr.title-text]="i18n.t('workspace.identity')" [attr.subtitle-text]="ws.identity().userId"></ui5-card-header>
          <div class="card-body">
            <div class="field">
              <label>{{ i18n.t('workspace.displayName') }}</label>
              <ui5-input [value]="ws.identity().displayName" (change)="onIdentity('displayName', $event)"></ui5-input>
            </div>
            <div class="field">
              <label>{{ i18n.t('workspace.teamName') }}</label>
              <ui5-input [value]="ws.identity().teamName" (change)="onIdentity('teamName', $event)"></ui5-input>
            </div>
            <div class="field">
              <label>{{ i18n.t('workspace.userId') }}</label>
              <ui5-tag design="Set2" color-scheme="6">{{ ws.identity().userId }}</ui5-tag>
            </div>
          </div>
        </ui5-card>

        <!-- Backend -->
        <ui5-card class="card-wide">
          <ui5-card-header slot="header" [attr.title-text]="i18n.t('workspace.backend')"></ui5-card-header>
          <div class="card-body">
            <div class="field field--row">
              <label>{{ i18n.t('workspace.apiBaseUrl') }}</label>
              <ui5-input class="field__input" [value]="ws.backendConfig().apiBaseUrl" (change)="onBackend('apiBaseUrl', $event)"></ui5-input>
              <ui5-button design="Transparent" (click)="testUrl(ws.backendConfig().apiBaseUrl, 'api')">{{ i18n.t('workspace.testConnection') }}</ui5-button>
              @if (connStatus['api'] === 'ok') { <ui5-tag design="Set2" color-scheme="8">{{ i18n.t('workspace.connected') }}</ui5-tag> }
              @if (connStatus['api'] === 'error') { <ui5-tag design="Set2" color-scheme="1">{{ i18n.t('workspace.unreachable') }}</ui5-tag> }
            </div>
            <div class="field field--row">
              <label>{{ i18n.t('workspace.collabWs') }}</label>
              <ui5-input class="field__input" [value]="ws.backendConfig().collabWsUrl" (change)="onBackend('collabWsUrl', $event)"></ui5-input>
            </div>
          </div>
        </ui5-card>

        <!-- Navigation -->
        <ui5-card>
          <ui5-card-header slot="header" [attr.title-text]="i18n.t('workspace.navigation')"></ui5-card-header>
          <div class="card-body">
            <div class="nav-list">
              @for (link of allNavLinks; track link.route) {
                <div class="nav-item">
                  <span>{{ i18n.t(link.labelKey) }}</span>
                  <ui5-switch [checked]="isNavVisible(link.route)" (change)="onNavToggle(link.route, $event)"></ui5-switch>
                </div>
              }
            </div>
          </div>
        </ui5-card>

        <!-- Model Preferences -->
        <ui5-card>
          <ui5-card-header slot="header" [attr.title-text]="i18n.t('workspace.modelPrefs')"></ui5-card-header>
          <div class="card-body">
            <div class="field">
              <label>{{ i18n.t('workspace.defaultModel') }}</label>
              <ui5-input [value]="ws.modelPreferences().defaultModel" placeholder="gpt-4o, gemma-4, etc." (change)="onModel('defaultModel', $event)"></ui5-input>
            </div>
            <div class="field">
              <label>{{ i18n.t('workspace.temperature') }}</label>
              <ui5-step-input [value]="ws.modelPreferences().temperature" [min]="0" [max]="2" [step]="0.1" (change)="onTemperature($event)"></ui5-step-input>
            </div>
            <div class="field">
              <label>{{ i18n.t('workspace.systemPrompt') }}</label>
              <ui5-textarea [value]="ws.modelPreferences().systemPrompt" [rows]="4" growing (change)="onModel('systemPrompt', $event)"></ui5-textarea>
            </div>
          </div>
        </ui5-card>

        <!-- Data Management -->
        <ui5-card>
          <ui5-card-header slot="header" [attr.title-text]="i18n.t('workspace.dataManagement')"></ui5-card-header>
          <div class="card-body card-body--actions">
            <ui5-button design="Default" icon="download" (click)="exportSettings()">{{ i18n.t('workspace.export') }}</ui5-button>
            <ui5-button design="Default" icon="upload" (click)="fileInput.click()">{{ i18n.t('workspace.import') }}</ui5-button>
            <input #fileInput type="file" accept=".json" style="display:none" (change)="onImport($event)">
            <ui5-button design="Negative" icon="delete" (click)="resetDialog.show()">{{ i18n.t('workspace.reset') }}</ui5-button>
          </div>
        </ui5-card>
      </div>
    </div>

    <ui5-dialog #resetDialog [attr.header-text]="i18n.t('workspace.reset')">
      <p style="padding:1rem;">{{ i18n.t('workspace.resetConfirm') }}</p>
      <div slot="footer" style="display:flex;justify-content:flex-end;gap:0.5rem;padding:0.5rem;">
        <ui5-button design="Transparent" (click)="resetDialog.close()">{{ i18n.t('common.cancel') }}</ui5-button>
        <ui5-button design="Negative" (click)="ws.resetToDefaults(); resetDialog.close()">{{ i18n.t('workspace.reset') }}</ui5-button>
      </div>
    </ui5-dialog>
  `,
  styles: [`
    .workspace-page { display: grid; gap: 1.5rem; padding: 2rem; min-height: 100%;
      background: radial-gradient(circle at top right, color-mix(in srgb, var(--sapBrandColor, #0854a0) 10%, transparent), transparent 32%), var(--sapBackgroundColor, #f5f5f5); }
    .workspace-hero { display: grid; gap: 0.5rem; padding: 1.5rem; border-radius: 1rem;
      background: linear-gradient(135deg, rgba(255,255,255,0.94), rgba(232,244,253,0.7));
      border: 1px solid color-mix(in srgb, var(--sapList_BorderColor, #d9d9d9) 88%, white);
      box-shadow: var(--sapContent_Shadow1, 0 2px 8px rgba(0,0,0,0.12)); }
    .workspace-hero h2 { margin: 0; }
    .workspace-hero__subtitle { margin: 0; color: var(--sapContent_LabelColor, #6a6d70); max-width: 48rem; line-height: 1.5; }
    .workspace-grid { display: grid; gap: 1rem; grid-template-columns: repeat(auto-fill, minmax(380px, 1fr)); align-items: start; }
    .card-wide { grid-column: 1 / -1; }
    .card-body { display: grid; gap: 1rem; padding: 1rem; }
    .card-body--actions { display: flex; flex-wrap: wrap; gap: 0.75rem; }
    .field { display: grid; gap: 0.35rem; }
    .field label { font-size: 0.8rem; font-weight: 600; color: var(--sapContent_LabelColor, #6a6d70); }
    .field--row { display: flex; flex-wrap: wrap; align-items: center; gap: 0.5rem; }
    .field--row label { min-width: 140px; }
    .field__input { flex: 1; min-width: 200px; }
    .nav-list { display: grid; gap: 0.5rem; }
    .nav-item { display: flex; justify-content: space-between; align-items: center; padding: 0.5rem 0.75rem;
      border-radius: 0.5rem; background: var(--sapList_Background, #fff); border: 1px solid var(--sapList_BorderColor, #e5e5e5); }
    .nav-item span { font-size: 0.875rem; }
    @media (max-width: 960px) { .workspace-page { padding: 1rem; } .workspace-grid { grid-template-columns: 1fr; } .card-wide { grid-column: auto; } }
  `]
})
export class WorkspaceComponent {
  readonly ws = inject(WorkspaceService);
  readonly i18n = inject(I18nService);
  private readonly http = inject(HttpClient);
  readonly allNavLinks = TRAINING_NAV_LINKS;
  connStatus: Record<string, string> = {};

  @ViewChild('resetDialog') resetDialog!: ElementRef<any>;

  onIdentity(field: string, event: Event): void {
    const value = (event.target as HTMLInputElement)?.value ?? '';
    this.ws.updateIdentity({ [field]: value });
  }

  onBackend(field: string, event: Event): void {
    const value = (event.target as HTMLInputElement)?.value ?? '';
    this.ws.updateBackend({ [field]: value });
  }

  onModel(field: string, event: Event): void {
    const value = (event.target as HTMLInputElement)?.value ?? '';
    this.ws.updateModel({ [field]: value });
  }

  onTemperature(event: Event): void {
    const value = parseFloat((event.target as HTMLInputElement)?.value);
    if (!isNaN(value)) this.ws.updateModel({ temperature: Math.min(2, Math.max(0, value)) });
  }

  testUrl(url: string, key: string): void {
    this.connStatus[key] = 'checking';
    const healthUrl = url.replace(/\/$/, '') + '/health';
    this.http.get(healthUrl, { observe: 'response' }).pipe(
      catchError(() => of({ status: 0 })),
    ).subscribe((r: { status: number }) => {
      this.connStatus[key] = (r.status >= 200 && r.status < 400) ? 'ok' : 'error';
    });
  }

  isNavVisible(route: string): boolean {
    const item = this.ws.navConfig().items.find((i: { route: string; visible: boolean }) => i.route === route);
    return !item || item.visible;
  }

  onNavToggle(route: string, event: Event): void {
    const checked = (event.target as HTMLInputElement)?.checked ?? true;
    const items = [...this.ws.navConfig().items];
    const idx = items.findIndex(i => i.route === route);
    if (idx >= 0) items[idx] = { ...items[idx], visible: checked };
    else items.push({ route, visible: checked, order: items.length });
    this.ws.updateNav({ items });
  }

  exportSettings(): void {
    const json = this.ws.exportSettings();
    const blob = new Blob([json], { type: 'application/json' });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a'); a.href = url; a.download = 'training-workspace.json'; a.click();
    URL.revokeObjectURL(url);
  }

  onImport(event: Event): void {
    const file = (event.target as HTMLInputElement)?.files?.[0];
    if (!file) return;
    const reader = new FileReader();
    reader.onload = () => this.ws.importSettings(reader.result as string);
    reader.readAsText(file);
  }
}
