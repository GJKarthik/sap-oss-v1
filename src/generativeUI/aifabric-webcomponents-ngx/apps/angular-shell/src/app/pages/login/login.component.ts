import { Component, DestroyRef, inject } from '@angular/core';
import { CommonModule } from '@angular/common';
import { FormsModule } from '@angular/forms';
import { Router } from '@angular/router';
import { Ui5WebcomponentsModule } from '@ui5/webcomponents-ngx';
import { takeUntilDestroyed } from '@angular/core/rxjs-interop';
import { AuthService } from '../../services/auth.service';
import { TranslatePipe, I18nService } from '../../shared/services/i18n.service';

@Component({
  selector: 'app-login',
  standalone: true,
  imports: [CommonModule, FormsModule, Ui5WebcomponentsModule, TranslatePipe],
  template: `
    <div class="login-container" role="main" aria-labelledby="login-title">
      <ui5-card class="login-card">
        <ui5-card-header
          slot="header"
          [attr.title-text]="i18n.t('auth.title')"
          [attr.subtitle-text]="i18n.t('auth.subtitle')"
          id="login-title">
        </ui5-card-header>
        <form class="login-form" (ngSubmit)="login()" #loginForm="ngForm">
          <div class="form-field">
            <label for="username-input" class="field-label">
              {{ 'auth.username' | translate }} <span class="required" aria-hidden="true">*</span>
            </label>
            <ui5-input
              id="username-input"
              ngDefaultControl
              [(ngModel)]="username"
              name="username"
              [attr.placeholder]="i18n.t('auth.enterUsername')"
              type="Text"
              [attr.accessible-name]="i18n.t('auth.username')"
              [attr.value-state]="usernameError ? 'Negative' : 'None'"
              [attr.value-state-message]="usernameError"
              required
              (input)="clearFieldError('username')">
            </ui5-input>
            <span *ngIf="usernameError" class="error-text" role="alert">{{ usernameError }}</span>
          </div>

          <div class="form-field">
            <label for="password-input" class="field-label">
              {{ 'auth.password' | translate }} <span class="required" aria-hidden="true">*</span>
            </label>
            <div class="password-wrapper">
              <ui5-input
                id="password-input"
                ngDefaultControl
                [(ngModel)]="password"
                name="password"
                [attr.placeholder]="i18n.t('auth.enterPassword')"
                [type]="showPassword ? 'Text' : 'Password'"
                [attr.accessible-name]="i18n.t('auth.password')"
                [attr.value-state]="passwordError ? 'Negative' : 'None'"
                required
                (input)="clearFieldError('password')">
              </ui5-input>
              <ui5-button
                design="Transparent"
                [icon]="showPassword ? 'hide' : 'show'"
                (click)="togglePasswordVisibility()"
                [attr.aria-label]="i18n.t(showPassword ? 'auth.hidePassword' : 'auth.showPassword')"
                [attr.aria-pressed]="showPassword"
                type="Button"
                class="password-toggle">
              </ui5-button>
            </div>
            <span *ngIf="passwordError" class="error-text" role="alert">{{ passwordError }}</span>
          </div>

          <ui5-button
            design="Emphasized"
            (click)="login()"
            [disabled]="loading"
            aria-describedby="login-status"
            type="Submit">
            <ui5-busy-indicator *ngIf="loading" size="S" active style="margin-right: 0.5rem;"></ui5-busy-indicator>
            {{ loading ? ('auth.signingIn' | translate) : ('auth.signIn' | translate) }}
          </ui5-button>

          <div id="login-status" class="visually-hidden" aria-live="polite">
            {{ loading ? ('auth.signingInWait' | translate) : '' }}
          </div>

          <ui5-message-strip
            *ngIf="error"
            design="Negative"
            [hideCloseButton]="false"
            (close)="error = ''"
            role="alert">
            {{ error }}
          </ui5-message-strip>
        </form>
      </ui5-card>
    </div>
  `,
  styles: [`
    .login-container {
      display: flex;
      justify-content: center;
      align-items: center;
      min-height: 100vh;
      padding: 1rem;
      background: var(--sapBackgroundColor);
    }

    .login-card {
      width: 100%;
      max-width: 400px;
    }

    .login-form {
      padding: 1.5rem;
      display: flex;
      flex-direction: column;
      gap: 1.25rem;
    }

    .form-field {
      display: flex;
      flex-direction: column;
      gap: 0.5rem;
    }

    .field-label {
      font-size: var(--sapFontSize);
      color: var(--sapContent_LabelColor);
      font-weight: 500;
    }

    .required {
      color: var(--sapNegativeColor, #b00);
    }

    .password-wrapper {
      display: flex;
      gap: 0.25rem;
      align-items: center;
    }

    .password-wrapper ui5-input {
      flex: 1;
    }

    .password-toggle {
      flex-shrink: 0;
    }

    .login-form ui5-input {
      width: 100%;
    }

    .error-text {
      font-size: var(--sapFontSmallSize);
      color: var(--sapNegativeColor, #b00);
    }

    .visually-hidden {
      position: absolute;
      width: 1px;
      height: 1px;
      padding: 0;
      margin: -1px;
      overflow: hidden;
      clip: rect(0, 0, 0, 0);
      white-space: nowrap;
      border: 0;
    }
  `]
})
export class LoginComponent {
  private readonly authService = inject(AuthService);
  private readonly router = inject(Router);
  private readonly destroyRef = inject(DestroyRef);
  readonly i18n = inject(I18nService);

  username = '';
  password = '';
  loading = false;
  error = '';
  showPassword = false;
  usernameError = '';
  passwordError = '';

  togglePasswordVisibility(): void {
    this.showPassword = !this.showPassword;
  }

  clearFieldError(field: 'username' | 'password'): void {
    if (field === 'username') {
      this.usernameError = '';
    } else {
      this.passwordError = '';
    }
  }

  private validateForm(): boolean {
    let isValid = true;
    this.usernameError = '';
    this.passwordError = '';

    if (!this.username.trim()) {
      this.usernameError = this.i18n.t('auth.usernameRequired');
      isValid = false;
    }

    if (!this.password) {
      this.passwordError = this.i18n.t('auth.passwordRequired');
      isValid = false;
    } else if (this.password.length < 3) {
      this.passwordError = this.i18n.t('auth.passwordMinLength', { length: '3' });
      isValid = false;
    }

    return isValid;
  }

  login(): void {
    if (!this.validateForm()) {
      return;
    }

    this.loading = true;
    this.error = '';
    this.authService.login(this.username, this.password)
      .pipe(takeUntilDestroyed(this.destroyRef))
      .subscribe({
        next: () => {
          void this.router.navigate(['/dashboard']);
        },
        error: (err) => {
          this.error = err.message || this.i18n.t('auth.invalidCredentials');
          this.loading = false;
        }
      });
  }
}
