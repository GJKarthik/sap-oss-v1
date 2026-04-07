/**
 * Cross-App Link Banner Component — Training Console
 *
 * Displays a contextual banner linking to a related feature in another app.
 * Carries workspace context so the target app auto-joins the same workspace.
 */

import { Component, CUSTOM_ELEMENTS_SCHEMA, Input, inject } from '@angular/core';
import { WorkspaceService, AppId } from '../services/workspace.service';

@Component({
  selector: 'app-cross-app-link',
  standalone: true,
  schemas: [CUSTOM_ELEMENTS_SCHEMA],
  template: `
    <div class="cross-app-banner" role="complementary" [attr.aria-label]="'Related: ' + targetLabel">
      <ui5-icon [attr.name]="icon" class="banner-icon"></ui5-icon>
      <div class="banner-text">
        <span class="banner-label">{{ relationLabel }}</span>
        <span class="banner-target"><strong>{{ targetLabel }}</strong> in {{ appDisplayName }}</span>
      </div>
      <ui5-button design="Transparent" icon="action" (click)="navigate()">Open</ui5-button>
    </div>
  `,
  styles: [`
    .cross-app-banner {
      display: flex; align-items: center; gap: 0.75rem;
      padding: 0.5rem 1rem;
      background: var(--sapInformationBackground, #e8f2ff);
      border: 1px solid var(--sapInformativeBorderColor, #5b9bd5);
      border-radius: 0.5rem; margin-bottom: 1rem;
    }
    .banner-icon { font-size: 1.25rem; color: var(--sapInformativeColor, #0854a0); }
    .banner-text { flex: 1; display: flex; flex-direction: column; gap: 0.125rem; }
    .banner-label { font-size: 0.75rem; color: var(--sapContent_LabelColor); }
    .banner-target { font-size: 0.875rem; }
  `],
})
export class CrossAppLinkComponent {
  @Input({ required: true }) targetApp!: AppId;
  @Input({ required: true }) targetRoute!: string;
  @Input({ required: true }) targetLabel!: string;
  @Input() icon = 'action';
  @Input() relationLabel = 'Related feature in another app:';

  private readonly ws = inject(WorkspaceService);

  get appDisplayName(): string {
    switch (this.targetApp) {
      case 'aifabric': return 'AI Fabric Console';
      case 'training': return 'Training Console';
      case 'joule': return 'Joule Playground';
      default: return this.targetApp;
    }
  }

  navigate(): void {
    const active = this.ws.activeWorkspace();
    const wsParam = active ? `?workspace=${active.id}` : '';
    window.location.href = `/${this.targetApp}${this.targetRoute}${wsParam}`;
  }
}
