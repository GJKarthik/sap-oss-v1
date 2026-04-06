/**
 * Error Boundary Component
 * 
 * A component for graceful error handling and display.
 * Can be used to wrap sections that might fail and show a user-friendly error state.
 */

import { Component, ErrorHandler, EventEmitter, Input, Output } from '@angular/core';
import { CommonModule } from '@angular/common';
import { Ui5WebcomponentsModule } from '@ui5/webcomponents-ngx';

export interface ErrorInfo {
  message: string;
  code?: string;
  details?: string;
  timestamp?: Date;
  retryable?: boolean;
}

@Component({
  selector: 'app-error-boundary',
  standalone: true,
  imports: [CommonModule, Ui5WebcomponentsModule],
  template: `
    <div *ngIf="hasError; else contentTemplate" class="error-boundary" role="alert" aria-live="assertive">
      <div class="error-content">
        <div class="error-icon">
          <ui5-icon [name]="errorIcon" aria-hidden="true"></ui5-icon>
        </div>
        
        <h3 class="error-title">{{ errorTitle }}</h3>
        
        <p class="error-message">{{ error?.message || 'An unexpected error occurred.' }}</p>
        
        <div class="error-details" *ngIf="showDetails && error?.details">
          <ui5-panel 
            header-text="Technical Details" 
            [collapsed]="true"
            accessible-role="Region">
            <pre class="error-stack">{{ error.details }}</pre>
          </ui5-panel>
        </div>
        
        <div class="error-code" *ngIf="error?.code">
          <span class="code-label">Error Code:</span>
          <code>{{ error.code }}</code>
        </div>
        
        <div class="error-actions">
          <ui5-button 
            *ngIf="error?.retryable !== false"
            design="Emphasized" 
            icon="refresh"
            (click)="onRetry()">
            Try Again
          </ui5-button>
          
          <ui5-button 
            design="Default" 
            icon="home"
            (click)="onGoHome()">
            Go to Dashboard
          </ui5-button>
          
          <ui5-button 
            *ngIf="showReportButton"
            design="Transparent" 
            icon="feedback"
            (click)="onReport()">
            Report Issue
          </ui5-button>
        </div>
        
        <p class="error-timestamp" *ngIf="error?.timestamp">
          Occurred at: {{ error.timestamp | date:'medium' }}
        </p>
      </div>
    </div>
    
    <ng-template #contentTemplate>
      <ng-content></ng-content>
    </ng-template>
  `,
  styles: [`
    .error-boundary {
      display: flex;
      align-items: center;
      justify-content: center;
      min-height: 300px;
      padding: 2rem;
      background: var(--sapBackgroundColor);
    }
    
    .error-content {
      text-align: center;
      max-width: 500px;
    }
    
    .error-icon {
      margin-bottom: 1rem;
    }
    
    .error-icon ui5-icon {
      font-size: 4rem;
      color: var(--sapNegativeColor, #b00);
    }
    
    .error-title {
      margin: 0 0 0.5rem 0;
      font-size: var(--sapFontHeader3Size, 1.25rem);
      font-weight: 600;
      color: var(--sapTextColor);
    }
    
    .error-message {
      margin: 0 0 1.5rem 0;
      color: var(--sapContent_LabelColor);
      line-height: 1.5;
    }
    
    .error-details {
      margin-bottom: 1.5rem;
      text-align: left;
    }
    
    .error-stack {
      font-family: monospace;
      font-size: var(--sapFontSmallSize);
      background: var(--sapList_Background);
      padding: 1rem;
      overflow: auto;
      max-height: 200px;
      margin: 0;
      border-radius: 4px;
    }
    
    .error-code {
      margin-bottom: 1.5rem;
      font-size: var(--sapFontSmallSize);
      color: var(--sapContent_LabelColor);
    }
    
    .code-label {
      margin-right: 0.5rem;
    }
    
    .error-code code {
      background: var(--sapList_Background);
      padding: 0.125rem 0.5rem;
      border-radius: 4px;
      font-family: monospace;
    }
    
    .error-actions {
      display: flex;
      justify-content: center;
      gap: 0.75rem;
      flex-wrap: wrap;
      margin-bottom: 1rem;
    }
    
    .error-timestamp {
      margin: 0;
      font-size: var(--sapFontSmallSize);
      color: var(--sapContent_LabelColor);
    }
  `]
})
export class ErrorBoundaryComponent {
  @Input() hasError = false;
  @Input() error: ErrorInfo | null = null;
  @Input() errorTitle = 'Something went wrong';
  @Input() errorIcon = 'message-error';
  @Input() showDetails = true;
  @Input() showReportButton = true;
  
  @Output() retry = new EventEmitter<void>();
  @Output() goHome = new EventEmitter<void>();
  @Output() report = new EventEmitter<ErrorInfo | null>();

  onRetry(): void {
    this.retry.emit();
  }

  onGoHome(): void {
    this.goHome.emit();
  }

  onReport(): void {
    this.report.emit(this.error);
  }
}

/**
 * Global Error Handler Service
 * 
 * Captures unhandled errors and provides centralized error handling.
 */
import { Injectable, NgZone, inject } from '@angular/core';
import { Router } from '@angular/router';
import { BehaviorSubject } from 'rxjs';
import { environment } from '../../../../environments/environment';

@Injectable({
  providedIn: 'root'
})
export class GlobalErrorHandler implements ErrorHandler {
  private readonly errorSubject = new BehaviorSubject<ErrorInfo | null>(null);
  readonly error$ = this.errorSubject.asObservable();
  private readonly ngZone = inject(NgZone);
  private readonly router = inject(Router);

  handleError(error: Error): void {
    // Log to console in development
    if (!environment.production) {
      console.error('Global error caught:', error);
    }

    const errorInfo: ErrorInfo = {
      message: this.getUserFriendlyMessage(error),
      details: error.stack,
      timestamp: new Date(),
      retryable: this.isRetryable(error)
    };

    // Update error state
    this.ngZone.run(() => {
      this.errorSubject.next(errorInfo);
    });

    // Optionally navigate to error page for critical errors
    if (this.isCriticalError(error)) {
      this.ngZone.run(() => {
        void this.router.navigate(['/error'], { 
          queryParams: { message: errorInfo.message } 
        });
      });
    }
  }

  clearError(): void {
    this.errorSubject.next(null);
  }

  private getUserFriendlyMessage(error: Error): string {
    // Map common error types to user-friendly messages
    if (error.name === 'HttpErrorResponse') {
      return 'Unable to connect to the server. Please check your connection and try again.';
    }
    if (error.name === 'TimeoutError') {
      return 'The request took too long. Please try again.';
    }
    if (error.message?.includes('ChunkLoadError')) {
      return 'Failed to load application resources. Please refresh the page.';
    }
    if (error.message?.includes('NetworkError')) {
      return 'Network error. Please check your internet connection.';
    }
    
    // Return generic message for unknown errors
    return error.message || 'An unexpected error occurred. Please try again.';
  }

  private isRetryable(error: Error): boolean {
    // Network and timeout errors are typically retryable
    return error.name === 'HttpErrorResponse' || 
           error.name === 'TimeoutError' ||
           error.message?.includes('NetworkError') === true;
  }

  private isCriticalError(error: Error): boolean {
    // ChunkLoadError requires page refresh
    return error.message?.includes('ChunkLoadError') === true;
  }
}