import { CommonModule } from '@angular/common';
import { Component, CUSTOM_ELEMENTS_SCHEMA, inject } from '@angular/core';
import { Router } from '@angular/router';

@Component({
  selector: 'app-welcome',
  standalone: true,
  imports: [CommonModule],
  schemas: [CUSTOM_ELEMENTS_SCHEMA],
  template: `
    <section class="page">
      <ui5-card>
        <ui5-card-header
          slot="header"
          title-text="AI Verify Process Checks"
          subtitle-text="Replaced Streamlit runtime with Angular + UI5"
        >
          <ui5-icon slot="avatar" name="official-service"></ui5-icon>
        </ui5-card-header>

        <div class="content">
          <p>
            This is the integrated Moonshot Process Check application. Complete governance checks, upload
            Moonshot run results, and generate report artifacts from one UI.
          </p>

          <div class="steps">
            <div class="step"><strong>1.</strong> Getting Started</div>
            <div class="step"><strong>2.</strong> Process Checks</div>
            <div class="step"><strong>3.</strong> Upload Technical Results</div>
            <div class="step"><strong>4.</strong> Generate Report</div>
            <div class="step"><strong>5.</strong> Moonshot Runtime Console</div>
          </div>

          <div class="actions">
            <ui5-button design="Emphasized" icon="navigation-right-arrow" (click)="go('/getting-started')">
              Start Assessment
            </ui5-button>
            <ui5-button design="Transparent" icon="machine" (click)="go('/overview')">
              Open Runtime Overview
            </ui5-button>
          </div>
        </div>
      </ui5-card>
    </section>
  `,
  styles: [
    `
      .page {
        display: grid;
      }

      .content {
        padding: 1rem;
        display: grid;
        gap: 1rem;
      }

      .steps {
        display: grid;
        gap: 0.5rem;
      }

      .step {
        padding: 0.55rem 0.7rem;
        border: 1px solid var(--moonshot-border);
        border-radius: 8px;
        background: var(--moonshot-panel);
      }

      .actions {
        display: flex;
        gap: 0.6rem;
        flex-wrap: wrap;
      }
    `,
  ],
})
export class WelcomeComponent {
  private readonly router = inject(Router);

  go(path: string): void {
    void this.router.navigateByUrl(path);
  }
}
