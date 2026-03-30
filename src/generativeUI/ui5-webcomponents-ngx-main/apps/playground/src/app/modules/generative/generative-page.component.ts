import { Component, OnInit, OnDestroy, ChangeDetectorRef } from '@angular/core';
import { GenerativeNode } from './generative-renderer.component';
import { GenerativeIntentService, UIIntent } from './generative-intent.service';
import { Subscription } from 'rxjs';

@Component({
  selector: 'app-generative-page',
  template: `
    <div style="padding: 2rem;">
      <ui5-title level="H2" style="margin-bottom: 1rem;">Fluid Generative UI Demo</ui5-title>
      
      <div style="display: flex; gap: 1rem; margin-bottom: 2rem;">
        <ui5-input #promptInput placeholder="Ask the AI to generate a Fiori screen..." style="flex: 1;"></ui5-input>
        <ui5-button design="Emphasized" (click)="generateUI(promptInput.value)">Generate</ui5-button>
      </div>

      <div *ngIf="loading" style="margin-bottom: 1rem;">
        <ui5-busy-indicator active size="M"></ui5-busy-indicator>
        <span style="margin-left: 0.5rem; color: var(--sapContent_LabelColor);">Thinking & Streaming...</span>
      </div>

      <div *ngIf="lastIntent" style="margin-bottom: 1rem; padding: 0.5rem; background: var(--sapInformationBackground); border: 1px solid var(--sapInformationBorderColor); border-radius: 4px;">
        <strong>Last Intent Bubbled to Agent:</strong> {{ lastIntent.action }} <br/>
        <small>Payload: {{ lastIntent.payload | json }}</small>
      </div>

      <div style="min-height: 400px; border: 1px solid var(--sapList_BorderColor); padding: 1rem; border-radius: 4px; background: var(--sapList_Background);">
        <app-generative-renderer *ngIf="uiSchema" [node]="uiSchema"></app-generative-renderer>
        <div *ngIf="!uiSchema && !loading" style="color: var(--sapContent_LabelColor); text-align: center; margin-top: 2rem;">
          No UI generated yet. Try asking for an "Interactive Profile Form".
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
  private sub?: Subscription;

  constructor(private cdr: ChangeDetectorRef, private intentService: GenerativeIntentService) {}

  ngOnInit(): void {
    this.sub = this.intentService.intents$.subscribe(intent => {
      this.lastIntent = intent;
      this.cdr.detectChanges();
      
      // If the intent is "submit", we simulate the generative engine streaming a success message.
      if (intent.action === 'submit_form') {
        this.generateUI('Show success message for ' + intent.payload?.firstName);
      }
    });
  }

  ngOnDestroy(): void {
    this.sub?.unsubscribe();
  }

  generateUI(prompt: string): void {
    if (!prompt) return;
    this.loading = true;
    this.uiSchema = null;
    
    // Simulate streaming the new interactive components
    setTimeout(() => {
      this.uiSchema = { type: 'ui5-card', children: [] };
      this.cdr.detectChanges();
    }, 500);

    setTimeout(() => {
      if (this.uiSchema && this.uiSchema.children) {
        this.uiSchema.children.push({ 
          type: 'div', 
          props: { slot: 'header' },
          children: [{ type: 'ui5-card-header', props: { 'title-text': prompt, 'subtitle-text': 'Interactive' } }] 
        });
      }
      this.cdr.detectChanges();
    }, 1200);

    setTimeout(() => {
      if (this.uiSchema && this.uiSchema.children) {
        this.uiSchema.children.push({ 
          type: 'ui5-input', 
          props: { placeholder: 'Enter Name' }, 
          intent: { action: 'update_name', payload: {} } 
        });
        this.uiSchema.children.push({ 
          type: 'ui5-button', 
          props: { design: 'Emphasized' }, 
          content: 'Submit to Agent',
          intent: { action: 'submit_form', payload: { firstName: 'Dynamic User' } }
        });
        this.loading = false;
      }
      this.cdr.detectChanges();
    }, 1800);
  }
}
