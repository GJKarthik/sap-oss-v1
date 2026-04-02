import { Component, CUSTOM_ELEMENTS_SCHEMA, signal } from '@angular/core';
import { CommonModule } from '@angular/common';
import { FormsModule } from '@angular/forms';
import { Router } from '@angular/router';
import { Ui5WebcomponentsModule } from '@ui5/webcomponents-ngx';
import '@ui5/webcomponents-icons/dist/AllIcons.js';
import { AuthService } from '../../services/auth.service';

@Component({
  selector: 'app-login',
  standalone: true,
  imports: [CommonModule, FormsModule, Ui5WebcomponentsModule],
  schemas: [CUSTOM_ELEMENTS_SCHEMA],
  template: `
    <div class="login-page">
      <ui5-card class="login-card">
        <div style="padding: 2.5rem 2rem;">
          <div class="login-brand">
            <ui5-icon name="key" class="login-logo"></ui5-icon>
            <ui5-title level="H3">Training Console</ui5-title>
            <p class="login-subtitle">SAP AI Training Platform</p>
          </div>
          <form class="login-form" (ngSubmit)="submit()">
            <div class="field-group">
              <ui5-label for="apiKey">API Key <span class="text-muted">(optional)</span></ui5-label>
              <ui5-input id="apiKey" type="Password"
                [value]="apiKey" (input)="apiKey = $any($event).target.value"
                placeholder="Enter API key or leave blank"
                style="width: 100%;"
                [disabled]="loading()">
              </ui5-input>
            </div>
            <ui5-button design="Emphasized" type="Submit"
              style="width: 100%;"
              [disabled]="loading()" (click)="submit()">
              @if (loading()) {
                Signing in…
              } @else {
                Enter Console
              }
            </ui5-button>
          </form>
          <p class="login-footer">Powered by SAP AI Core</p>
        </div>
      </ui5-card>
    </div>
  `,
  styles: [`
    .login-page {
      display: flex; align-items: center; justify-content: center;
      min-height: 100vh;
      background: linear-gradient(135deg, #1a2a3a 0%, var(--sapShellColor, #354a5e) 50%, #2c3e50 100%);
    }
    .login-card { width: 100%; max-width: 380px; animation: cardIn 0.4s ease-out; }
    .login-brand { text-align: center; margin-bottom: 1.75rem; }
    .login-logo {
      font-size: 2rem; color: var(--sapBrandColor, #0854a0);
      margin-bottom: 0.625rem; display: block;
    }
    .login-subtitle {
      font-size: 0.75rem; color: var(--sapContent_LabelColor, #6a6d70);
      margin: 0.25rem 0 0; letter-spacing: 0.02em;
    }
    .login-form { display: flex; flex-direction: column; gap: 1.25rem; }
    .login-footer {
      text-align: center; margin: 1.5rem 0 0;
      font-size: 0.6875rem; color: var(--sapContent_LabelColor, #6a6d70);
      letter-spacing: 0.03em;
    }
    @keyframes cardIn {
      from { transform: translateY(1rem) scale(0.97); opacity: 0; }
      to   { transform: translateY(0) scale(1); opacity: 1; }
    }
  `],
})
export class LoginComponent {
  apiKey = '';
  loading = signal(false);

  constructor(private auth: AuthService, private router: Router) {}

  submit(): void {
    this.loading.set(true);
    if (this.apiKey.trim()) {
      this.auth.setToken(this.apiKey.trim());
    }
    setTimeout(() => {
      this.router.navigate(['/dashboard']);
      this.loading.set(false);
    }, 600);
  }
}
