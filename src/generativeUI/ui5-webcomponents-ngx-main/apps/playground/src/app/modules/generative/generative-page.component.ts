import { Component, OnInit, ChangeDetectorRef } from '@angular/core';
import { GenerativeNode } from './generative-renderer.component';

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

      <div style="min-height: 400px; border: 1px solid var(--sapList_BorderColor); padding: 1rem; border-radius: 4px; background: var(--sapList_Background);">
        <app-generative-renderer *ngIf="uiSchema" [node]="uiSchema"></app-generative-renderer>
        <div *ngIf="!uiSchema && !loading" style="color: var(--sapContent_LabelColor); text-align: center; margin-top: 2rem;">
          No UI generated yet. Try asking for a "User Profile Card" or a "Task List".
        </div>
      </div>
    </div>
  `,
  standalone: false
})
export class GenerativePageComponent implements OnInit {
  uiSchema: GenerativeNode | null = null;
  loading = false;

  constructor(private cdr: ChangeDetectorRef) {}

  ngOnInit(): void {}

  generateUI(prompt: string): void {
    if (!prompt) return;
    this.loading = true;
    this.uiSchema = null;
    
    // In a real implementation this would be an SSE stream from the AI Agent.
    // We simulate a streaming chunk arrival to demonstrate the "Fluid" Generative UI.
    
    // Simulate streaming chunks every 500ms
    setTimeout(() => {
      this.uiSchema = { type: 'ui5-card', props: { titleText: 'Generated UI', subtitleText: 'Streaming...' }, children: [] };
      this.cdr.detectChanges();
    }, 500);

    setTimeout(() => {
      if (this.uiSchema && this.uiSchema.children) {
        this.uiSchema.children.push({ type: 'ui5-list', props: { headerText: prompt }, children: [] });
      }
      this.cdr.detectChanges();
    }, 1200);

    setTimeout(() => {
      if (this.uiSchema && this.uiSchema.children && this.uiSchema.children[0].children) {
        this.uiSchema.children[0].children.push({ type: 'ui5-li', props: { description: 'Item 1' }, content: 'First dynamic item' });
      }
      this.cdr.detectChanges();
    }, 1800);

    setTimeout(() => {
      if (this.uiSchema && this.uiSchema.children && this.uiSchema.children[0].children) {
        this.uiSchema.children[0].children.push({ type: 'ui5-li', props: { description: 'Item 2' }, content: 'Second simulated item' });
        this.loading = false;
        this.uiSchema.props = { ...this.uiSchema.props, subtitleText: 'Complete' };
      }
      this.cdr.detectChanges();
    }, 2500);
  }
}
