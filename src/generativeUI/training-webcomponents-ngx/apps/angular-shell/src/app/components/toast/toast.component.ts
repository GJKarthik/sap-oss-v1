import { Component, CUSTOM_ELEMENTS_SCHEMA, ChangeDetectionStrategy, inject } from '@angular/core';
import { CommonModule } from '@angular/common';
import { ToastService, ToastType } from '../../services/toast.service';
import '@ui5/webcomponents/dist/Button.js';

@Component({
  selector: 'app-toast',
  standalone: true,
  imports: [CommonModule],
  schemas: [CUSTOM_ELEMENTS_SCHEMA],
  changeDetection: ChangeDetectionStrategy.OnPush,
  template: `
    <div class="toast-container" *ngIf="toastService.hasToasts()">
      @for (toast of toastService.toasts(); track toast.id) {
        <div 
          class="toast toast--{{ toast.type }}"
          role="alert"
          [attr.aria-live]="toast.type === 'error' ? 'assertive' : 'polite'"
        >
          <div class="toast-icon"><ui5-icon [name]="getIcon(toast.type)"></ui5-icon></div>
          <div class="toast-content">
            <div class="toast-title" *ngIf="toast.title">{{ toast.title }}</div>
            <div class="toast-message">{{ toast.message }}</div>
          </div>
          <ui5-button
            design="Transparent"
            icon="decline"
            (click)="toastService.dismiss(toast.id)"
            aria-label="Dismiss notification"
          >
          </ui5-button>
        </div>
      }
    </div>
  `,
  styles: [`
    .toast-container {
      position: fixed;
      top: 1rem;
      right: 1rem;
      z-index: 10000;
      display: flex;
      flex-direction: column;
      gap: 0.5rem;
      max-width: 400px;
      pointer-events: none;
    }

    .toast {
      display: flex;
      align-items: flex-start;
      gap: 0.75rem;
      padding: 0.875rem 1rem;
      border-radius: 0.5rem;
      box-shadow: 0 4px 12px rgba(0, 0, 0, 0.15);
      animation: slideIn 0.25s ease-out;
      pointer-events: auto;
      background: var(--sapBaseColor, #fff);
      border-left: 4px solid;
    }

    .toast--success {
      border-left-color: var(--sapPositiveColor, #107e3e);
      background: #f1fdf4;
    }

    .toast--error {
      border-left-color: var(--sapNegativeColor, #bb0000);
      background: #fff5f5;
    }

    .toast--warning {
      border-left-color: var(--sapWarningColor, #df6e0c);
      background: #fffbf0;
    }

    .toast--info {
      border-left-color: var(--sapInformativeColor, #0854a0);
      background: #f5faff;
    }

    .toast-icon {
      font-size: 1.25rem;
      flex-shrink: 0;
    }

    .toast-content {
      flex: 1;
      min-width: 0;
    }

    .toast-title {
      font-weight: 600;
      font-size: 0.875rem;
      color: var(--sapTextColor, #32363a);
      margin-bottom: 0.25rem;
    }

    .toast-message {
      font-size: 0.8125rem;
      color: var(--sapContent_LabelColor, #6a6d70);
      word-break: break-word;
    }

    .toast-close {
      background: transparent;
      border: none;
      cursor: pointer;
      padding: 0.25rem;
      font-size: 0.875rem;
      color: var(--sapContent_LabelColor, #6a6d70);
      border-radius: 0.25rem;
      transition: background 0.15s;

      &:hover {
        background: rgba(0, 0, 0, 0.05);
        color: var(--sapTextColor, #32363a);
      }
    }

    @keyframes slideIn {
      from {
        transform: translateX(100%);
        opacity: 0;
      }
      to {
        transform: translateX(0);
        opacity: 1;
      }
    }
  `],
})
export class ToastComponent {
  toastService = inject(ToastService);

  getIcon(type: ToastType): string {
    const icons: Record<ToastType, string> = {
      success: 'accept',
      error: 'error',
      warning: 'alert',
      info: 'information',
    };
    return icons[type];
  }
}
