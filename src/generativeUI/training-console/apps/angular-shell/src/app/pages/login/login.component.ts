import { Component, CUSTOM_ELEMENTS_SCHEMA, signal } from '@angular/core';
import { CommonModule } from '@angular/common';
import { FormsModule } from '@angular/forms';
import { Router } from '@angular/router';
import { AuthService } from '../../services/auth.service';

@Component({
  selector: 'app-login',
  standalone: true,
  imports: [CommonModule, FormsModule],
  schemas: [CUSTOM_ELEMENTS_SCHEMA],
  template: `
    <div class="login-page">
      <div class="login-card">
        <div class="login-brand">
          <div class="login-logo">◆</div>
          <h1 class="login-title">Training Console</h1>
          <p class="login-subtitle">SAP AI Training Platform</p>
        </div>
        <form class="login-form" (ngSubmit)="submit()">
          <div class="field-group">
            <label class="field-label" for="apiKey">API Key <span class="text-muted">(optional)</span></label>
            <input id="apiKey" type="password" class="login-input"
              [(ngModel)]="apiKey" name="apiKey"
              placeholder="Enter API key or leave blank"
              autocomplete="current-password" [disabled]="loading()" />
          </div>
          <button type="submit" class="login-submit" [disabled]="loading()" [class.is-loading]="loading()">
            @if (loading()) {
              <span class="spinner"></span> Signing in…
            } @else {
              Enter Console
            }
          </button>
        </form>
        <p class="login-footer">Powered by SAP AI Core</p>
      </div>
    </div>
  `,
  styles: [`
    .login-page {
      display: flex; align-items: center; justify-content: center;
      min-height: 100vh;
      background: linear-gradient(135deg, #1a2a3a 0%, var(--sapShellColor, #354a5e) 50%, #2c3e50 100%);
    }
    .login-card {
      background: var(--sapBaseColor, #fff); border-radius: 0.75rem;
      padding: 2.5rem 2rem; width: 100%; max-width: 340px;
      box-shadow: 0 12px 40px rgba(0,0,0,0.25);
      animation: cardIn 0.4s ease-out;
    }
    .login-brand { text-align: center; margin-bottom: 1.75rem; }
    .login-logo {
      font-size: 2rem; color: var(--sapBrandColor, #0854a0);
      margin-bottom: 0.625rem; display: block;
    }
    .login-title {
      font-size: 1.25rem; font-weight: 700;
      color: var(--sapTextColor, #32363a); margin: 0 0 0.25rem;
    }
    .login-subtitle {
      font-size: 0.75rem; color: var(--sapContent_LabelColor, #6a6d70);
      margin: 0; letter-spacing: 0.02em;
    }
    .login-form { display: flex; flex-direction: column; gap: 1.25rem; }
    .login-input {
      width: 100%; box-sizing: border-box;
      padding: 0.5rem 0.75rem;
      border: 1px solid var(--sapField_BorderColor, #89919a);
      border-radius: 0.375rem; font-size: 0.875rem;
      background: var(--sapField_Background, #fff);
      color: var(--sapTextColor, #32363a);
      transition: border-color 0.15s, box-shadow 0.15s;
      &:focus {
        outline: none; border-color: var(--sapBrandColor, #0854a0);
        box-shadow: 0 0 0 3px rgba(8,84,160,0.12);
      }
    }
    .login-submit {
      width: 100%; padding: 0.625rem;
      background: var(--sapBrandColor, #0854a0); color: #fff;
      border: none; border-radius: 0.375rem;
      font-size: 0.875rem; font-weight: 600; cursor: pointer;
      transition: background 0.15s, transform 0.1s;
      display: flex; align-items: center; justify-content: center; gap: 0.5rem;
      &:hover:not(:disabled) { background: var(--sapButton_Hover_Background, #0a6ed1); }
      &:active:not(:disabled) { transform: scale(0.99); }
      &:disabled { opacity: 0.7; cursor: not-allowed; }
    }
    .spinner {
      width: 0.875rem; height: 0.875rem; border: 2px solid rgba(255,255,255,0.3);
      border-top-color: #fff; border-radius: 50%;
      animation: spin 0.6s linear infinite; display: inline-block;
    }
    .login-footer {
      text-align: center; margin: 1.5rem 0 0;
      font-size: 0.6875rem; color: var(--sapContent_LabelColor, #6a6d70);
      letter-spacing: 0.03em;
    }
    @keyframes cardIn {
      from { transform: translateY(1rem) scale(0.97); opacity: 0; }
      to   { transform: translateY(0) scale(1); opacity: 1; }
    }
    @keyframes spin { to { transform: rotate(360deg); } }
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
