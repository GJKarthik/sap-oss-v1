import { Component, CUSTOM_ELEMENTS_SCHEMA } from '@angular/core';
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
          <span class="login-icon"><ui5-icon name="machine"></ui5-icon></span>
          <h1 class="login-title">Training Console</h1>
          <p class="login-subtitle">SAP AI Training Platform</p>
        </div>

        <form class="login-form" (ngSubmit)="submit()">
          <div class="field-group">
            <label class="field-label" for="apiKey">API Key <span class="text-muted">(optional)</span></label>
            <input
              id="apiKey"
              type="password"
              class="login-input"
              [(ngModel)]="apiKey"
              name="apiKey"
              placeholder="Enter API key or leave blank"
              autocomplete="current-password"
            />
          </div>

          <button type="submit" class="login-submit">Enter Console</button>
        </form>
      </div>
    </div>
  `,
  styles: [
    `
      .login-page {
        display: flex;
        align-items: center;
        justify-content: center;
        min-height: 100vh;
        background: var(--sapShellColor, #354a5e);
      }

      .login-card {
        background: var(--sapBaseColor, #fff);
        border-radius: 0.5rem;
        padding: 2.5rem;
        width: 100%;
        max-width: 360px;
        box-shadow: 0 8px 32px rgba(0, 0, 0, 0.2);
      }

      .login-brand {
        text-align: center;
        margin-bottom: 2rem;
      }

      .login-icon {
        font-size: 2.5rem;
        display: block;
        margin-bottom: 0.5rem;
      }

      .login-title {
        font-size: 1.25rem;
        font-weight: 700;
        color: var(--sapTextColor, #32363a);
        margin: 0 0 0.25rem;
      }

      .login-subtitle {
        font-size: 0.8125rem;
        color: var(--sapContent_LabelColor, #6a6d70);
        margin: 0;
      }

      .login-form {
        display: flex;
        flex-direction: column;
        gap: 1.25rem;
      }

      .login-input {
        width: 100%;
        box-sizing: border-box;
        padding: 0.5rem 0.75rem;
        border: 1px solid var(--sapField_BorderColor, #89919a);
        border-radius: 0.25rem;
        font-size: 0.875rem;
        background: var(--sapField_Background, #fff);
        color: var(--sapTextColor, #32363a);

        &:focus {
          outline: 2px solid var(--sapContent_FocusColor, #0854a0);
          outline-offset: 1px;
        }
      }

      .login-submit {
        width: 100%;
        padding: 0.625rem;
        background: var(--sapBrandColor, #0854a0);
        color: #fff;
        border: none;
        border-radius: 0.25rem;
        font-size: 0.9375rem;
        font-weight: 600;
        cursor: pointer;
        transition: background 0.15s;

        &:hover {
          background: var(--sapButton_Hover_Background, #0a6ed1);
        }
      }
    `,
  ],
})
export class LoginComponent {
  apiKey = '';

  constructor(
    private auth: AuthService,
    private router: Router
  ) {}

  submit(): void {
    if (this.apiKey.trim()) {
      this.auth.setToken(this.apiKey.trim());
    }
    this.router.navigate(['/dashboard']);
  }
}
