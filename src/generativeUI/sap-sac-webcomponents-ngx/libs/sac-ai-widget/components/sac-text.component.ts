// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2024 SAP SE
/**
 * SAC Text Components — P2-002 Expansion
 *
 * Accessible text/content widgets for SAC layouts:
 * - sac-heading: Semantic headings (h1-h6)
 * - sac-text-block: Rich text content
 * - sac-divider: Visual separator
 *
 * WCAG AA Compliance:
 * - Semantic heading hierarchy
 * - Proper reading order
 * - Sufficient color contrast
 * - Respects user font sizing
 */

import {
  Component,
  Input,
  ChangeDetectionStrategy,
  SecurityContext,
} from '@angular/core';
import { CommonModule } from '@angular/common';
import { DomSanitizer, SafeHtml } from '@angular/platform-browser';
import type { SacHeadingLevel, SacTextAlign } from '../types/sac-widget-schema';

// =============================================================================
// Heading Component
// =============================================================================

@Component({
  selector: 'sac-heading',
  standalone: true,
  imports: [CommonModule],
  changeDetection: ChangeDetectionStrategy.OnPush,
  template: `
    <ng-container [ngSwitch]="level">
      <h1 *ngSwitchCase="1" [class]="headingClass" [style.text-align]="align">{{ content }}</h1>
      <h2 *ngSwitchCase="2" [class]="headingClass" [style.text-align]="align">{{ content }}</h2>
      <h3 *ngSwitchCase="3" [class]="headingClass" [style.text-align]="align">{{ content }}</h3>
      <h4 *ngSwitchCase="4" [class]="headingClass" [style.text-align]="align">{{ content }}</h4>
      <h5 *ngSwitchCase="5" [class]="headingClass" [style.text-align]="align">{{ content }}</h5>
      <h6 *ngSwitchCase="6" [class]="headingClass" [style.text-align]="align">{{ content }}</h6>
    </ng-container>
  `,
  styles: [`
    :host { display: block; }
    .sac-heading {
      margin: 0; padding: 0;
      color: var(--sapTextColor, #32363a);
      font-family: var(--sapFontFamily, 'SAP 72', Arial, sans-serif);
    }
    .sac-heading--1 { font-size: 32px; font-weight: 700; line-height: 1.25; margin-bottom: 16px; }
    .sac-heading--2 { font-size: 24px; font-weight: 600; line-height: 1.3; margin-bottom: 12px; }
    .sac-heading--3 { font-size: 20px; font-weight: 600; line-height: 1.35; margin-bottom: 8px; }
    .sac-heading--4 { font-size: 18px; font-weight: 600; line-height: 1.4; margin-bottom: 8px; }
    .sac-heading--5 { font-size: 16px; font-weight: 600; line-height: 1.45; margin-bottom: 8px; }
    .sac-heading--6 { font-size: 14px; font-weight: 600; line-height: 1.5; margin-bottom: 8px; }
  `],
})
export class SacHeadingComponent {
  @Input() content = '';
  @Input() level: SacHeadingLevel = 2;
  @Input() align: SacTextAlign = 'left';

  get headingClass(): string {
    return `sac-heading sac-heading--${this.level}`;
  }
}

// =============================================================================
// Text Block Component
// =============================================================================

@Component({
  selector: 'sac-text-block',
  standalone: true,
  imports: [CommonModule],
  changeDetection: ChangeDetectionStrategy.OnPush,
  template: `
    <div class="sac-text-block"
         [style.text-align]="align"
         [class.sac-text-block--markdown]="markdown">
      <ng-container *ngIf="!markdown">{{ content }}</ng-container>
      <ng-container *ngIf="markdown">
        <div [innerHTML]="sanitizedContent" class="sac-text-block__content"></div>
      </ng-container>
    </div>
  `,
  styles: [`
    :host { display: block; }
    .sac-text-block {
      color: var(--sapTextColor, #32363a);
      font-family: var(--sapFontFamily, 'SAP 72', Arial, sans-serif);
      font-size: 14px; line-height: 1.6;
    }
    .sac-text-block__content p { margin: 0 0 8px 0; }
    .sac-text-block__content p:last-child { margin-bottom: 0; }
    .sac-text-block__content strong { font-weight: 600; }
    .sac-text-block__content em { font-style: italic; }
    .sac-text-block__content a {
      color: var(--sapLinkColor, #0854a0);
      text-decoration: underline;
    }
    .sac-text-block__content a:hover { text-decoration: none; }
    .sac-text-block__content a:focus-visible {
      outline: 2px solid var(--sapContent_FocusColor, #0070f2);
      outline-offset: 2px;
    }
    .sac-text-block__content ul, .sac-text-block__content ol {
      margin: 8px 0; padding-left: 24px;
    }
    .sac-text-block__content li { margin: 4px 0; }
    .sac-text-block__content code {
      background: var(--sapShell_Background, #f5f5f5);
      padding: 2px 6px; border-radius: 4px;
      font-family: monospace; font-size: 13px;
    }
  `],
})
export class SacTextBlockComponent {
  @Input() content = '';
  @Input() align: SacTextAlign = 'left';
  @Input() markdown = false;

  constructor(private sanitizer: DomSanitizer) {}

  get sanitizedContent(): SafeHtml {
    // Simple markdown-like parsing (for POC - production would use marked.js)
    let html = this.content
      .replace(/\*\*(.*?)\*\*/g, '<strong>$1</strong>')
      .replace(/\*(.*?)\*/g, '<em>$1</em>')
      .replace(/\[(.*?)\]\((.*?)\)/g, '<a href="$2">$1</a>')
      .replace(/\n\n/g, '</p><p>')
      .replace(/\n/g, '<br>');
    html = `<p>${html}</p>`;
    return this.sanitizer.bypassSecurityTrustHtml(html);
  }
}

// =============================================================================
// Divider Component
// =============================================================================

@Component({
  selector: 'sac-divider',
  standalone: true,
  imports: [CommonModule],
  changeDetection: ChangeDetectionStrategy.OnPush,
  template: `
    <hr class="sac-divider"
        [class.sac-divider--light]="variant === 'light'"
        [class.sac-divider--heavy]="variant === 'heavy'"
        [style.margin-top.px]="spacing * 8"
        [style.margin-bottom.px]="spacing * 8"
        role="separator"
        [attr.aria-label]="ariaLabel" />
  `,
  styles: [`
    .sac-divider {
      border: none; height: 1px;
      background: var(--sapGroup_TitleBorderColor, #d9d9d9);
    }
    .sac-divider--light { background: var(--sapShell_BorderColor, #ebebeb); }
    .sac-divider--heavy {
      height: 2px; background: var(--sapTextColor, #32363a);
    }
  `],
})
export class SacDividerComponent {
  @Input() variant: 'default' | 'light' | 'heavy' = 'default';
  @Input() spacing = 2; // 8px grid units
  @Input() ariaLabel = 'Content separator';
}

