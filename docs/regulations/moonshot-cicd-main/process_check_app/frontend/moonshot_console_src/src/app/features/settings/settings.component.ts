import { CommonModule } from '@angular/common';
import { Component, CUSTOM_ELEMENTS_SCHEMA, DestroyRef, inject } from '@angular/core';
import { takeUntilDestroyed } from '@angular/core/rxjs-interop';

import { MoonshotApiService } from '../../core/services/moonshot-api.service';

@Component({
  selector: 'app-settings',
  standalone: true,
  imports: [CommonModule],
  schemas: [CUSTOM_ELEMENTS_SCHEMA],
  template: `
    <section class="page">
      <div>
        <ui5-title level="H2">Settings</ui5-title>
        <p class="subtitle">Configure backend URL and offline behavior.</p>
      </div>

      <ui5-card>
        <ui5-card-header slot="header" title-text="Moonshot Backend"></ui5-card-header>
        <div class="card-content form-grid">
          <label class="field">
            <span>Backend URL</span>
            <ui5-input [value]="baseUrl" placeholder="http://localhost:8088" (input)="baseUrl = valueFromEvent($event)"></ui5-input>
          </label>

          <label class="field">
            <span>Timeout (ms)</span>
            <ui5-input [value]="timeoutMsText" type="Number" (input)="timeoutMsText = valueFromEvent($event)"></ui5-input>
          </label>

          <label class="field inline">
            <span>Mock fallback</span>
            <ui5-checkbox [checked]="useMockFallback" (change)="useMockFallback = checkedFromEvent($event)">
              Enable mocked responses when backend is unavailable
            </ui5-checkbox>
          </label>
        </div>

        <div class="actions">
          <ui5-button design="Emphasized" icon="save" (click)="save()">Save</ui5-button>
          <ui5-button design="Transparent" icon="connected" (click)="testConnection()" [disabled]="testing">
            {{ testing ? 'Testing...' : 'Test Connection' }}
          </ui5-button>
        </div>
      </ui5-card>

      <ui5-message-strip *ngIf="message" [design]="messageDesign">{{ message }}</ui5-message-strip>
    </section>
  `,
  styles: [
    `
      .page {
        display: grid;
        gap: 1rem;
      }

      .subtitle {
        margin: 0.4rem 0 0;
        color: var(--sapContent_LabelColor);
      }

      .card-content {
        padding: 1rem;
      }

      .form-grid {
        display: grid;
        grid-template-columns: repeat(auto-fit, minmax(240px, 1fr));
        gap: 0.9rem;
      }

      .field {
        display: grid;
        gap: 0.35rem;
      }

      .field span {
        color: var(--sapContent_LabelColor);
        font-size: 0.78rem;
      }

      .inline {
        align-items: end;
      }

      .actions {
        padding: 0 1rem 1rem;
        display: flex;
        gap: 0.5rem;
      }
    `,
  ],
})
export class SettingsComponent {
  private readonly destroyRef = inject(DestroyRef);
  private readonly moonshot = inject(MoonshotApiService);

  baseUrl = this.moonshot.getConfig().baseUrl;
  timeoutMsText = String(this.moonshot.getConfig().timeoutMs);
  useMockFallback = this.moonshot.getConfig().useMockFallback;

  testing = false;
  message = '';
  messageDesign: 'Positive' | 'Negative' | 'Warning' | 'Information' = 'Information';

  save(): void {
    const timeout = Number.parseInt(this.timeoutMsText, 10);
    this.moonshot.setConfig({
      baseUrl: this.baseUrl.trim(),
      timeoutMs: Number.isFinite(timeout) ? timeout : 30000,
      useMockFallback: this.useMockFallback,
    });

    this.message = 'Settings saved.';
    this.messageDesign = 'Positive';
  }

  testConnection(): void {
    this.testing = true;
    this.message = '';

    this.save();
    this.moonshot
      .checkHealth()
      .pipe(takeUntilDestroyed(this.destroyRef))
      .subscribe({
        next: (health) => {
          this.testing = false;
          if (health.status === 'ok') {
            this.message = 'Connection test succeeded.';
            this.messageDesign = 'Positive';
          } else {
            this.message = 'Connection test returned a non-ok status.';
            this.messageDesign = 'Warning';
          }
        },
        error: (error: Error) => {
          this.testing = false;
          this.message = error.message;
          this.messageDesign = 'Negative';
        },
      });
  }

  valueFromEvent(event: Event): string {
    const target = event.target as { value?: string };
    return target.value ?? '';
  }

  checkedFromEvent(event: Event): boolean {
    const target = event.target as { checked?: boolean };
    return !!target.checked;
  }
}
