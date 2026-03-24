import { Component, DestroyRef, inject } from '@angular/core';
import { CommonModule } from '@angular/common';
import { FormsModule } from '@angular/forms';
import { Router } from '@angular/router';
import { Ui5WebcomponentsModule } from '@ui5/webcomponents-ngx';
import { takeUntilDestroyed } from '@angular/core/rxjs-interop';
import { AuthService } from '../../services/auth.service';

@Component({
  selector: 'app-login',
  standalone: true,
  imports: [CommonModule, FormsModule, Ui5WebcomponentsModule],
  template: `
    <div class="login-container">
      <ui5-card class="login-card">
        <ui5-card-header slot="header" title-text="SAP AI Fabric Console" subtitle-text="Sign in to continue"></ui5-card-header>
        <div class="login-form">
          <ui5-input ngDefaultControl [(ngModel)]="username" placeholder="Username" type="Text"></ui5-input>
          <ui5-input ngDefaultControl [(ngModel)]="password" placeholder="Password" type="Password"></ui5-input>
          <ui5-button design="Emphasized" (click)="login()" [disabled]="loading">
            {{ loading ? 'Signing in...' : 'Sign In' }}
          </ui5-button>
          <ui5-message-strip *ngIf="error" design="Negative">{{ error }}</ui5-message-strip>
        </div>
      </ui5-card>
    </div>
  `,
  styles: [`
    .login-container { display: flex; justify-content: center; align-items: center; height: 100vh; background: var(--sapBackgroundColor); }
    .login-card { width: 400px; }
    .login-form { padding: 1.5rem; display: flex; flex-direction: column; gap: 1rem; }
    .login-form ui5-input { width: 100%; }
  `]
})
export class LoginComponent {
  private readonly authService = inject(AuthService);
  private readonly router = inject(Router);
  private readonly destroyRef = inject(DestroyRef);

  username = '';
  password = '';
  loading = false;
  error = '';

  login(): void {
    this.loading = true;
    this.error = '';
    this.authService.login(this.username, this.password)
      .pipe(takeUntilDestroyed(this.destroyRef))
      .subscribe({
        next: () => { this.router.navigate(['/dashboard']); },
        error: (err) => { this.error = err.message || 'Invalid credentials'; this.loading = false; }
      });
  }
}
