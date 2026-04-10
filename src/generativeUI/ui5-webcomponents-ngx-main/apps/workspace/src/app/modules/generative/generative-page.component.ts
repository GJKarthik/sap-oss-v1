import { Component, OnInit, OnDestroy, ChangeDetectorRef } from '@angular/core';
import { GenerativeNode } from './generative-renderer.component';
import { GenerativeIntentService, UIIntent } from './generative-intent.service';
import { Subscription } from 'rxjs';
import { GenerativeRuntimeService } from './generative-runtime.service';
import { ExperienceHealthService } from '../../core/experience-health.service';
import { WorkspaceHistoryService } from '../../core/workspace-history.service';

@Component({
  selector: 'app-generative-page',
  template: `
    <section class="generative-page" role="main" aria-label="Generative UI workspace">
      <header class="generative-header">
        <div class="generative-header__copy">
          <span class="generative-header__eyebrow">{{ 'NAV_GENERATIVE' | ui5I18n }}</span>
          <ui5-title level="H2">{{ 'GENERATIVE_PAGE_TITLE' | ui5I18n }}</ui5-title>
          <p>{{ 'HOME_CARD_GENERATIVE_DESC' | ui5I18n }}</p>
        </div>
      </header>

      <div class="generative-grid">
        <aside class="generative-sidebar">
          <ui5-card class="generative-card">
            <ui5-card-header
              slot="header"
              [attr.title-text]="'HOME_CARD_GENERATIVE_TITLE' | ui5I18n"
              [attr.subtitle-text]="'HOME_CARD_GENERATIVE_SUBTITLE' | ui5I18n">
            </ui5-card-header>
            <div class="generative-card__body">
              <ui5-textarea
                #promptInput
                [value]="prompt"
                [rows]="3"
                growing
                [attr.placeholder]="'GENERATIVE_PROMPT_PLACEHOLDER' | ui5I18n"
                (input)="prompt = $any($event.target).value">
              </ui5-textarea>
              <ui5-button design="Emphasized" [disabled]="routeBlocked || loading" (click)="generateUI(prompt)">
                {{ 'GENERATIVE_BTN' | ui5I18n }}
              </ui5-button>
              
              <div class="generative-suggestions">
                <span class="generative-suggestions__title">Quick Starts</span>
                <div class="generative-suggestions__items">
                  <ui5-button
                    *ngFor="let starterPrompt of starterPrompts"
                    design="Transparent"
                    (click)="setPrompt(starterPrompt)">
                    {{ starterPrompt }}
                  </ui5-button>
                </div>
              </div>
            </div>
          </ui5-card>

          <ui5-card *ngIf="lastIntent" class="generative-card generative-card--intent">
            <ui5-card-header
              slot="header"
              [attr.title-text]="'GENERATIVE_LAST_INTENT' | ui5I18n"
              [attr.subtitle-text]="lastIntent.action">
            </ui5-card-header>
            <div class="generative-card__body">
              <pre class="intent-pre">{{ prettyPrint(lastIntent.payload) }}</pre>
            </div>
          </ui5-card>
        </aside>

        <main class="generative-main">
          <div *ngIf="loading" class="generative-loading-stage">
            <div class="liquid-skeleton">
              <div class="liquid-skeleton__header"></div>
              <div class="liquid-skeleton__body">
                <div class="liquid-skeleton__line"></div>
                <div class="liquid-skeleton__line"></div>
                <div class="liquid-skeleton__line"></div>
              </div>
            </div>
            <span class="loading-label">{{ 'GENERATIVE_LOADING' | ui5I18n }}</span>
          </div>

          <div *ngIf="!loading && uiSchema" class="generative-stage">
            <app-generative-renderer [node]="uiSchema"></app-generative-renderer>
          </div>

          <div *ngIf="!uiSchema && !loading" class="generative-empty-stage">
             <ui5-icon name="collections-insight"></ui5-icon>
             <p>{{ 'GENERATIVE_EMPTY_HINT' | ui5I18n }}</p>
          </div>
          
          <ui5-message-strip *ngIf="lastError" design="Negative" class="error-strip">
            {{ lastError }}
          </ui5-message-strip>
        </main>
      </div>
    </section>
  `,
  styles: [`
    .generative-page {
      display: flex;
      flex-direction: column;
      gap: 2.5rem;
      padding: clamp(1.5rem, 4vw, 3rem);
      min-height: 100%;
      background:
        radial-gradient(circle at 100% 100%, rgba(0, 112, 242, 0.08), transparent 40rem),
        var(--bg-primary);
    }

    .generative-header__eyebrow {
      font-size: 0.8125rem;
      font-weight: 700;
      letter-spacing: 0.1em;
      text-transform: uppercase;
      color: var(--color-primary);
      margin-bottom: 0.5rem;
      display: block;
    }

    .generative-header p {
      margin: 0.5rem 0 0;
      max-width: 50ch;
      font-size: 1.15rem;
      color: var(--text-secondary);
      line-height: 1.5;
    }

    .generative-grid {
      display: grid;
      grid-template-columns: 420px 1fr;
      gap: 2rem;
      align-items: start;
    }

    .generative-sidebar {
      display: flex;
      flex-direction: column;
      gap: 1.5rem;
    }

    .generative-card {
      background: var(--liquid-glass-bg);
      backdrop-filter: var(--liquid-glass-blur);
      -webkit-backdrop-filter: var(--liquid-glass-blur);
      border-radius: 28px;
      border: var(--liquid-glass-border);
      box-shadow: var(--liquid-glass-shadow);
      
      &::part(content) {
        background: transparent;
      }
    }

    .generative-card__body {
      padding: 1.5rem;
      display: flex;
      flex-direction: column;
      gap: 1.25rem;
    }

    .generative-suggestions__title {
      font-size: 0.75rem;
      font-weight: 700;
      text-transform: uppercase;
      color: var(--text-secondary);
      letter-spacing: 0.05em;
      margin-bottom: 0.5rem;
      display: block;
    }

    .intent-pre {
      font-family: var(--sapFontFamilyMono, monospace);
      font-size: 0.8125rem;
      background: rgba(0, 0, 0, 0.03);
      padding: 1rem;
      border-radius: 12px;
      overflow-x: auto;
    }

    .generative-main {
      min-height: 600px;
      display: flex;
      flex-direction: column;
    }

    .generative-stage {
      flex: 1;
      background: var(--surface-secondary);
      border-radius: 32px;
      border: 1px solid rgba(0, 0, 0, 0.05);
      padding: 2.5rem;
      box-shadow: inset 0 2px 10px rgba(0, 0, 0, 0.02);
    }

    .generative-loading-stage, .generative-empty-stage {
      flex: 1;
      display: flex;
      flex-direction: column;
      align-items: center;
      justify-content: center;
      gap: 2rem;
      background: var(--liquid-glass-bg);
      border-radius: 32px;
      border: 1px dashed rgba(0, 0, 0, 0.1);
    }

    .generative-empty-stage {
      ui5-icon {
        font-size: 4rem;
        color: var(--color-primary);
        opacity: 0.3;
      }
      p {
        font-size: 1.25rem;
        color: var(--text-secondary);
        font-weight: 500;
      }
    }

    .loading-label {
      font-weight: 600;
      color: var(--color-primary);
      letter-spacing: 0.02em;
    }

    .liquid-skeleton {
      width: 400px;
      display: flex;
      flex-direction: column;
      gap: 1rem;
      opacity: 0.5;
    }

    .liquid-skeleton__header {
      height: 40px;
      width: 60%;
      background: linear-gradient(90deg, #eee 25%, #f5f5f5 50%, #eee 75%);
      background-size: 200% 100%;
      animation: skeleton-shimmer 2s infinite linear;
      border-radius: 8px;
    }

    .liquid-skeleton__line {
      height: 16px;
      background: linear-gradient(90deg, #eee 25%, #f5f5f5 50%, #eee 75%);
      background-size: 200% 100%;
      animation: skeleton-shimmer 2s infinite linear;
      border-radius: 4px;
      margin-bottom: 0.5rem;
      
      &:nth-child(2) { width: 85%; }
      &:nth-child(3) { width: 65%; }
    }

    @keyframes skeleton-shimmer {
      0% { background-position: 200% 0; }
      100% { background-position: -200% 0; }
    }

    .error-strip {
      margin-top: 1.5rem;
    }

    @media (max-width: 1024px) {
      .generative-grid { grid-template-columns: 1fr; }
      .generative-sidebar { width: 100%; }
    }
  `],

      gap: 1rem;
    }

    .generative-loading {
      display: flex;
      flex-direction: column;
      gap: 0.6rem;
      color: var(--sapContent_LabelColor, #6a6d70);
      padding: 0.85rem 1rem;
      border-radius: 0.75rem;
      background: var(--liquid-glass-bg);
      border: 1px solid color-mix(in srgb, var(--sapList_BorderColor, #d9d9d9) 88%, white);
    }

    .generative-skeleton-card {
      border-radius: 1rem;
      border: 1px solid color-mix(in srgb, var(--sapList_BorderColor, #d9d9d9) 88%, white);
      background: var(--liquid-glass-bg);
      overflow: hidden;
    }

    .generative-skeleton-card__header {
      padding: 1rem;
      border-bottom: 1px solid color-mix(in srgb, var(--sapList_BorderColor, #d9d9d9) 88%, white);
    }

    .generative-skeleton-card__body {
      display: flex;
      flex-direction: column;
      gap: 0.6rem;
      padding: 1rem;
    }

    .generative-skeleton-card__footer {
      padding: 0.75rem 1rem;
      border-top: 1px solid color-mix(in srgb, var(--sapList_BorderColor, #d9d9d9) 88%, white);
    }

    .generative-skeleton__bar {
      border-radius: 0.375rem;
      background: linear-gradient(90deg, var(--sapList_Background, #f5f5f5) 25%, var(--liquid-glass-bg) 50%, var(--sapList_Background, #f5f5f5) 75%);
      background-size: 200% 100%;
      animation: shimmer 1.5s ease-in-out infinite;
    }

    .generative-skeleton--header { height: 0.875rem; width: 35%; }
    .generative-skeleton--wide { height: 0.75rem; width: 100%; }
    .generative-skeleton--medium { height: 0.75rem; width: 75%; }
    .generative-skeleton--narrow { height: 0.75rem; width: 50%; }
    .generative-skeleton--btn { height: 2rem; width: 7rem; border-radius: 0.5rem; }

    @keyframes shimmer {
      0% { background-position: 200% 0; }
      100% { background-position: -200% 0; }
    }

    @media (prefers-reduced-motion: reduce) {
      .generative-skeleton__bar { animation: none; }
    }

    .generative-card--intent pre {
      margin: 0;
      white-space: pre-wrap;
      word-break: break-word;
      padding: 0.85rem;
      border-radius: 0.75rem;
      background: var(--sapList_Background, #f5f5f5);
      border: 1px solid var(--sapList_BorderColor, #d9d9d9);
      font-size: 0.8rem;
    }

    .generative-render {
      grid-column: 1 / -1;
      display: grid;
      gap: 0.75rem;
    }

    .generative-render__header {
      display: grid;
      gap: 0.35rem;
    }

    .generative-render__title-row {
      display: flex;
      justify-content: space-between;
      align-items: flex-start;
      flex-wrap: wrap;
      gap: 0.5rem;
    }

    .generative-render__actions {
      display: flex;
      gap: 0.5rem;
    }

    .generative-render__header ui5-title,
    .generative-render__header p {
      margin: 0;
    }

    .generative-render__header p {
      color: var(--sapContent_LabelColor, #6a6d70);
    }

    .generative-render__stage {
      min-height: 420px;
      padding: 1rem;
      border-radius: 1rem;
      border: 1px solid color-mix(in srgb, var(--sapList_BorderColor, #d9d9d9) 88%, white);
      background: var(--liquid-glass-bg);
      box-shadow: var(--sapContent_Shadow1, 0 2px 8px rgba(0, 0, 0, 0.12));
    }

    .generative-empty {
      display: grid;
      place-items: center;
      min-height: 320px;
      color: var(--sapContent_LabelColor, #6a6d70);
      text-align: center;
      padding: 1rem;
      border-radius: 0.9rem;
      border: 1px dashed color-mix(in srgb, var(--sapList_BorderColor, #d9d9d9) 88%, white);
      background: color-mix(in srgb, white 92%, var(--sapList_Background, #f5f5f5));
    }

    @media (max-width: 960px) {
      .generative-page {
        padding: 1rem;
      }

      .generative-grid {
        grid-template-columns: 1fr;
      }
    }
  `],
  standalone: false
})
export class GenerativePageComponent implements OnInit, OnDestroy {
  uiSchema: GenerativeNode | null = null;
  loading = false;
  lastIntent: UIIntent | null = null;
  lastError: string | null = null;
  routeBlocked = false;
  blockingReason = '';
  prompt = '';
  saveMessage = '';
  saveMessageDesign: 'Positive' | 'Negative' = 'Positive';
  readonly starterPrompts = [
    'Design an interactive employee profile form with approval controls',
    'Create a procurement review dashboard with alerts and actions',
    'Build a customer service workspace with timeline and notes',
  ];
  private sub?: Subscription;

  constructor(
    private cdr: ChangeDetectorRef,
    private intentService: GenerativeIntentService,
    private runtimeService: GenerativeRuntimeService,
    private liveHealthService: ExperienceHealthService,
    private historyService: WorkspaceHistoryService,
  ) {}

  ngOnInit(): void {
    this.liveHealthService.checkRouteReadiness('generative').subscribe((readiness) => {
      this.routeBlocked = readiness.blocking;
      const failed = readiness.checks.find((check) => !check.ok);
      this.blockingReason = failed
        ? `Service required: ${failed.name} (${failed.status || 'no status'})`
        : '';
      this.cdr.detectChanges();
    });

    this.sub = this.intentService.intents$.subscribe(intent => {
      this.lastIntent = intent;
      this.cdr.detectChanges();
      
      if (intent.action === 'submit_form') {
        this.prompt = 'Show success message for ' + intent.payload?.firstName;
        this.generateUI(this.prompt);
      }
    });
  }

  ngOnDestroy(): void {
    this.sub?.unsubscribe();
  }

  setPrompt(prompt: string): void {
    this.prompt = prompt;
  }

  prettyPrint(value: unknown): string {
    return JSON.stringify(value ?? {}, null, 2);
  }

  saveTemplate(): void {
    if (!this.uiSchema) return;
    const template = {
      prompt: this.prompt,
      schema: this.uiSchema,
      savedAt: new Date().toISOString(),
    };
    this.historyService.saveEntry('generative-template', template).subscribe({
      next: () => {
        this.saveMessage = 'Template saved to workspace history.';
        this.saveMessageDesign = 'Positive';
        this.cdr.detectChanges();
      },
      error: () => {
        this.saveMessage = 'Failed to save template.';
        this.saveMessageDesign = 'Negative';
        this.cdr.detectChanges();
      }
    });
  }

  shareSchema(): void {
    if (!this.uiSchema) return;
    const exportData = {
      prompt: this.prompt,
      schema: this.uiSchema,
      exportedAt: new Date().toISOString(),
    };
    const blob = new Blob([JSON.stringify(exportData, null, 2)], { type: 'application/json' });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = `generative-ui-${new Date().toISOString().slice(0, 10)}.json`;
    a.click();
    URL.revokeObjectURL(url);
  }

  generateUI(prompt: string): void {
    if (!prompt || this.routeBlocked) return;
    this.prompt = prompt;
    this.loading = true;
    this.lastError = null;
    this.uiSchema = null;

    this.runtimeService.generateSchema(prompt).subscribe({
      next: (schema) => {
        this.uiSchema = schema;
        this.loading = false;
        this.cdr.detectChanges();
        this.historyService.saveEntry('generative', {
          prompt: this.prompt,
          schema,
        }).subscribe();
      },
      error: (error: { message?: string }) => {
        this.uiSchema = null;
        this.lastError = error?.message ?? 'Failed to generate schema from live backend';
        this.loading = false;
        this.cdr.detectChanges();
      },
    });
  }
}
