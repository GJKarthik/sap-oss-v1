import { Component, OnInit, OnDestroy, ChangeDetectorRef } from '@angular/core';
import { GenerativeNode } from './generative-renderer.component';
import { GenerativeIntentService, UIIntent } from './generative-intent.service';
import { Subscription } from 'rxjs';
import { GenerativeRuntimeService } from './generative-runtime.service';
import { LiveDemoHealthService } from '../../core/live-demo-health.service';

@Component({
  selector: 'app-generative-page',
  template: `
    <div style="padding: 2rem;">
      <ui5-title level="H2" style="margin-bottom: 1rem;">{{ 'GENERATIVE_PAGE_TITLE' | ui5I18n }}</ui5-title>
      
      <div style="display: flex; gap: 1rem; margin-bottom: 2rem;">
        <ui5-input #promptInput [attr.placeholder]="'GENERATIVE_PROMPT_PLACEHOLDER' | ui5I18n" style="flex: 1;"></ui5-input>
        <ui5-button design="Emphasized" [disabled]="routeBlocked || loading" (click)="generateUI(promptInput.value)">{{ 'GENERATIVE_BTN' | ui5I18n }}</ui5-button>
      </div>

      <ui5-message-strip *ngIf="routeBlocked" design="Negative" hide-close-button style="margin-bottom: 1rem;">
        {{ blockingReason }}
      </ui5-message-strip>

      <div *ngIf="loading" style="margin-bottom: 1rem;">
        <ui5-busy-indicator active size="M"></ui5-busy-indicator>
        <span style="margin-left: 0.5rem; color: var(--sapContent_LabelColor);">{{ 'GENERATIVE_LOADING' | ui5I18n }}</span>
      </div>

      <ui5-message-strip *ngIf="lastError" design="Negative" hide-close-button style="margin-bottom: 1rem;">
        {{ lastError }}
      </ui5-message-strip>

      <div *ngIf="lastIntent" style="margin-bottom: 1rem; padding: 0.5rem; background: var(--sapInformationBackground); border: 1px solid var(--sapInformationBorderColor); border-radius: 4px;">
        <strong>{{ 'GENERATIVE_LAST_INTENT' | ui5I18n }}</strong> {{ lastIntent.action }} <br/>
        <small>Payload: {{ lastIntent.payload | json }}</small>
      </div>

      <div style="min-height: 400px; border: 1px solid var(--sapList_BorderColor); padding: 1rem; border-radius: 4px; background: var(--sapList_Background);">
        <app-generative-renderer *ngIf="uiSchema" [node]="uiSchema"></app-generative-renderer>
        <div *ngIf="!uiSchema && !loading" style="color: var(--sapContent_LabelColor); text-align: center; margin-top: 2rem;">
          {{ 'GENERATIVE_EMPTY_HINT' | ui5I18n }}
        </div>
      </div>
    </div>
  `,
  standalone: false
})
export class GenerativePageComponent implements OnInit, OnDestroy {
  uiSchema: GenerativeNode | null = null;
  loading = false;
  lastIntent: UIIntent | null = null;
  lastError: string | null = null;
  routeBlocked = false;
  blockingReason = '';
  private sub?: Subscription;

  constructor(
    private cdr: ChangeDetectorRef,
    private intentService: GenerativeIntentService,
    private runtimeService: GenerativeRuntimeService,
    private liveHealthService: LiveDemoHealthService,
  ) {}

  ngOnInit(): void {
    this.liveHealthService.checkRouteReadiness('generative').subscribe((readiness) => {
      this.routeBlocked = readiness.blocking;
      const failed = readiness.checks.find((check) => !check.ok);
      this.blockingReason = failed
        ? `Live service required: ${failed.name} (${failed.status || 'no status'})`
        : '';
      this.cdr.detectChanges();
    });

    this.sub = this.intentService.intents$.subscribe(intent => {
      this.lastIntent = intent;
      this.cdr.detectChanges();
      
      if (intent.action === 'submit_form') {
        this.generateUI('Show success message for ' + intent.payload?.firstName);
      }
    });
  }

  ngOnDestroy(): void {
    this.sub?.unsubscribe();
  }

  generateUI(prompt: string): void {
    if (!prompt || this.routeBlocked) return;
    this.loading = true;
    this.lastError = null;
    this.uiSchema = null;

    this.runtimeService.generateSchema(prompt).subscribe({
      next: (schema) => {
        this.uiSchema = schema;
        this.loading = false;
        this.cdr.detectChanges();
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
