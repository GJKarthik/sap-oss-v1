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
      <div class="generative-hero">
        <span class="generative-hero__eyebrow">{{ 'NAV_GENERATIVE' | ui5I18n }}</span>
        <ui5-title level="H2">{{ 'GENERATIVE_PAGE_TITLE' | ui5I18n }}</ui5-title>
        <p>{{ 'HOME_CARD_GENERATIVE_DESC' | ui5I18n }}</p>
      </div>

      <div class="generative-grid">
        <ui5-card class="generative-card">
          <ui5-card-header
            slot="header"
            [attr.title-text]="'HOME_CARD_GENERATIVE_TITLE' | ui5I18n"
            [attr.subtitle-text]="'HOME_CARD_GENERATIVE_SUBTITLE' | ui5I18n">
          </ui5-card-header>
          <div class="generative-card__body generative-card__body--composer">
            <ui5-input
              #promptInput
              [value]="prompt"
              [attr.placeholder]="'GENERATIVE_PROMPT_PLACEHOLDER' | ui5I18n"
              (input)="prompt = $any($event.target).value">
            </ui5-input>
            <ui5-button design="Emphasized" [disabled]="routeBlocked || loading" (click)="generateUI(prompt)">
              {{ 'GENERATIVE_BTN' | ui5I18n }}
            </ui5-button>
            <div class="generative-suggestions">
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

        <div class="generative-status">
          <ui5-message-strip *ngIf="routeBlocked" design="Negative" hide-close-button>
            {{ blockingReason }}
          </ui5-message-strip>

          <div *ngIf="loading" class="generative-loading" role="status" aria-label="Generating UI">
            <div class="generative-skeleton-card">
              <div class="generative-skeleton-card__header">
                <div class="generative-skeleton__bar generative-skeleton--header"></div>
              </div>
              <div class="generative-skeleton-card__body">
                <div class="generative-skeleton__bar generative-skeleton--wide"></div>
                <div class="generative-skeleton__bar generative-skeleton--medium"></div>
                <div class="generative-skeleton__bar generative-skeleton--narrow"></div>
              </div>
              <div class="generative-skeleton-card__footer">
                <div class="generative-skeleton__bar generative-skeleton--btn"></div>
              </div>
            </div>
            <span>{{ 'GENERATIVE_LOADING' | ui5I18n }}</span>
          </div>

          <ui5-message-strip *ngIf="lastError" design="Negative" hide-close-button>
            {{ lastError }}
          </ui5-message-strip>

          <ui5-button *ngIf="lastError && prompt" design="Emphasized" (click)="generateUI(prompt)">
            {{ 'READINESS_CHECK_NOW' | ui5I18n }}
          </ui5-button>

          <ui5-card *ngIf="lastIntent" class="generative-card generative-card--intent">
            <ui5-card-header
              slot="header"
              [attr.title-text]="'GENERATIVE_LAST_INTENT' | ui5I18n"
              [attr.subtitle-text]="lastIntent.action">
            </ui5-card-header>
            <div class="generative-card__body">
              <pre>{{ prettyPrint(lastIntent.payload) }}</pre>
            </div>
          </ui5-card>
        </div>

        <div class="generative-render">
          <div class="generative-render__header">
            <div class="generative-render__title-row">
              <div>
                <ui5-title level="H4">{{ 'HOME_CARD_GENERATIVE_TITLE' | ui5I18n }}</ui5-title>
                <p>{{ 'HOME_CARD_GENERATIVE_SUBTITLE' | ui5I18n }}</p>
              </div>
            </div>
          </div>

          <ui5-message-strip *ngIf="saveMessage" [design]="saveMessageDesign" (close)="saveMessage = ''">
            {{ saveMessage }}
          </ui5-message-strip>

          <div class="generative-render__stage">
            <app-generative-renderer *ngIf="uiSchema" [node]="uiSchema"></app-generative-renderer>
            <div *ngIf="!uiSchema && !loading" class="generative-empty">
              {{ 'GENERATIVE_EMPTY_HINT' | ui5I18n }}
            </div>
          </div>
        </div>
      </div>
    </section>
  `,
  styles: [`
    .generative-page {
      display: grid;
      gap: 1.5rem;
      padding: 2rem;
      min-height: 100%;
      background:
        radial-gradient(circle at top right, color-mix(in srgb, var(--sapBrandColor, #0854a0) 10%, transparent), transparent 32%),
        var(--sapBackgroundColor, #f5f5f5);
    }

    .generative-hero {
      display: grid;
      gap: 0.5rem;
      padding: 1.5rem;
      border-radius: 1rem;
      background: linear-gradient(135deg, rgba(255, 255, 255, 0.94), rgba(232, 244, 253, 0.7));
      border: 1px solid color-mix(in srgb, var(--sapList_BorderColor, #d9d9d9) 88%, white);
      box-shadow: var(--sapContent_Shadow1, 0 2px 8px rgba(0, 0, 0, 0.12));
    }

    .generative-hero__eyebrow {
      display: inline-flex;
      align-items: center;
      width: fit-content;
      padding: 0.25rem 0.55rem;
      border-radius: 999px;
      background: color-mix(in srgb, var(--sapBrandColor, #0854a0) 12%, white);
      color: var(--sapBrandColor, #0854a0);
      font-size: 0.75rem;
      font-weight: 700;
    }

    .generative-hero ui5-title,
    .generative-hero p {
      margin: 0;
    }

    .generative-hero p {
      color: var(--sapContent_LabelColor, #6a6d70);
      max-width: 48rem;
      line-height: 1.5;
    }

    .generative-grid {
      display: grid;
      gap: 1rem;
      grid-template-columns: minmax(320px, 420px) minmax(0, 1fr);
      align-items: start;
    }

    .generative-card {
      overflow: hidden;
    }

    .generative-card__body {
      display: grid;
      gap: 0.9rem;
      padding: 1rem;
    }

    .generative-card__body--composer {
      align-items: start;
    }

    .generative-suggestions {
      display: grid;
      gap: 0.5rem;
    }

    .generative-suggestions__title {
      color: var(--sapContent_LabelColor, #6a6d70);
      font-size: 0.8rem;
      font-weight: 700;
      text-transform: uppercase;
      letter-spacing: 0.03em;
    }

    .generative-suggestions__items {
      display: flex;
      flex-wrap: wrap;
      gap: 0.5rem;
    }

    .generative-status {
      display: grid;
      gap: 1rem;
    }

    .generative-loading {
      display: flex;
      flex-direction: column;
      gap: 0.6rem;
      color: var(--sapContent_LabelColor, #6a6d70);
      padding: 0.85rem 1rem;
      border-radius: 0.75rem;
      background: rgba(255, 255, 255, 0.82);
      border: 1px solid color-mix(in srgb, var(--sapList_BorderColor, #d9d9d9) 88%, white);
    }

    .generative-skeleton-card {
      border-radius: 1rem;
      border: 1px solid color-mix(in srgb, var(--sapList_BorderColor, #d9d9d9) 88%, white);
      background: rgba(255, 255, 255, 0.84);
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
      background: linear-gradient(90deg, var(--sapList_Background, #f5f5f5) 25%, rgba(255,255,255,0.6) 50%, var(--sapList_Background, #f5f5f5) 75%);
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
      background: rgba(255, 255, 255, 0.84);
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
