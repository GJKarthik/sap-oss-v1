/**
 * Cross-App Link Banner Component — SAP AI Workbench
 *
 * Displays a contextual banner linking to a related feature in another app.
 * Carries workspace context so the target app auto-joins the same workspace.
 */

import { Component, CUSTOM_ELEMENTS_SCHEMA, Input, inject } from '@angular/core';
import { I18nService } from '../services/i18n.service';
import { AppId, AppLinkService } from '../services/app-link.service';

@Component({
  selector: 'app-cross-app-link',
  standalone: true,
  schemas: [CUSTOM_ELEMENTS_SCHEMA],
  template: `
    <div class="cross-app-banner" role="complementary" [attr.aria-label]="resolvedRelationLabel + ' ' + resolvedTargetLabel">
      <ui5-icon [attr.name]="icon" class="banner-icon"></ui5-icon>
      <div class="banner-text">
        <span class="banner-label">{{ resolvedRelationLabel }}</span>
        <span class="banner-target"><strong>{{ resolvedTargetLabel }}</strong> {{ i18n.t('crossApp.inApp') }} {{ appDisplayName }}</span>
      </div>
      <ui5-button design="Transparent" icon="action" (click)="navigate()">{{ i18n.t('crossApp.open') }}</ui5-button>
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
  @Input() targetLabel = '';
  @Input() targetLabelKey = '';
  @Input() icon = 'action';
  @Input() relationLabel = '';
  @Input() relationLabelKey = '';

  readonly i18n = inject(I18nService);
  private readonly appLinks = inject(AppLinkService);

  get appDisplayName(): string {
    return this.i18n.t(this.appLinks.appDisplayNameKey(this.targetApp));
  }

  get resolvedTargetLabel(): string {
    if (this.targetLabelKey) {
      return this.i18n.t(this.targetLabelKey);
    }

    const inferredKey = this.appLinks.targetLabelKey(this.targetApp, this.targetRoute);
    if (inferredKey) {
      return this.i18n.t(inferredKey);
    }

    return this.targetLabel || this.targetRoute;
  }

  get resolvedRelationLabel(): string {
    if (this.relationLabelKey) {
      return this.i18n.t(this.relationLabelKey);
    }

    return this.relationLabel || this.i18n.t('crossApp.related');
  }

  navigate(): void {
    this.appLinks.navigate(this.targetApp, this.targetRoute);
  }
}
