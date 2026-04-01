import { Component, CUSTOM_ELEMENTS_SCHEMA, ChangeDetectionStrategy, inject } from '@angular/core';
import { CommonModule } from '@angular/common';
import { ToastService, Toast, ToastType } from '../../services/toast.service';

@Component({
  selector: 'app-toast',
  standalone: true,
  imports: [CommonModule],
  schemas: [CUSTOM_ELEMENTS_SCHEMA],
  changeDetection: ChangeDetectionStrategy.OnPush,
  template: `
    <div class="toast-container" *ngIf="toastService.hasToasts()">
      @for (toast of toastService.toasts(); track toast.id) {
        <div class="toast toast--{{ toast.type }}" role="alert"
          [attr.aria-live]="toast.type === 'error' ? 'assertive' : 'polite'">
          <div class="toast-body">
            <div class="toast-icon">{{ getIcon(toast.type) }}</div>
            <div class="toast-content">
              <div class="toast-title" *ngIf="toast.title">{{ toast.title }}</div>
              <div class="toast-message">{{ toast.message }}</div>
            </div>
            <button class="toast-close" (click)="toastService.dismiss(toast.id)"
              aria-label="Dismiss notification">✕</button>
          </div>
          @if (toast.duration > 0) {
            <div class="toast-progress" [style.animation-duration.ms]="toast.duration"></div>
          }
        </div>
      }
    </div>
  `,
  styles: [`
    .toast-container {
      position: fixed; top: 3.25rem; right: 1rem; z-index: 10000;
      display: flex; flex-direction: column; gap: 0.5rem;
      max-width: 380px; pointer-events: none;
    }
    .toast {
      border-radius: 0.5rem; overflow: hidden;
      box-shadow: 0 4px 16px rgba(0,0,0,0.12), 0 1px 3px rgba(0,0,0,0.08);
      animation: toastIn 0.3s cubic-bezier(0.21,1.02,0.73,1);
      pointer-events: auto; background: var(--sapBaseColor, #fff);
      border-left: 4px solid;
    }
    .toast-body {
      display: flex; align-items: flex-start;
      gap: 0.625rem; padding: 0.75rem 0.875rem;
    }
    .toast--success { border-left-color: var(--sapPositiveColor, #2b7d2b); }
    .toast--error   { border-left-color: var(--sapNegativeColor, #b00020); }
    .toast--warning { border-left-color: var(--sapCriticalColor, #e78c07); }
    .toast--info    { border-left-color: var(--sapInformativeColor, #0854a0); }
    .toast-icon { font-size: 1.125rem; flex-shrink: 0; line-height: 1.4; }
    .toast--success .toast-icon { color: var(--sapPositiveColor, #2b7d2b); }
    .toast--error .toast-icon   { color: var(--sapNegativeColor, #b00020); }
    .toast--warning .toast-icon { color: var(--sapCriticalColor, #e78c07); }
    .toast--info .toast-icon    { color: var(--sapInformativeColor, #0854a0); }
    .toast-content { flex: 1; min-width: 0; }
    .toast-title {
      font-weight: 600; font-size: 0.8125rem;
      color: var(--sapTextColor, #32363a); margin-bottom: 0.125rem;
    }
    .toast-message {
      font-size: 0.75rem; color: var(--sapContent_LabelColor, #6a6d70);
      word-break: break-word; line-height: 1.4;
    }
    .toast-close {
      background: transparent; border: none; cursor: pointer;
      padding: 0.125rem 0.25rem; font-size: 0.75rem;
      color: var(--sapContent_LabelColor, #6a6d70);
      border-radius: 0.25rem; transition: background 0.15s; line-height: 1;
      &:hover { background: rgba(0,0,0,0.05); color: var(--sapTextColor, #32363a); }
    }
    .toast-progress {
      height: 2px; background: currentColor; opacity: 0.3;
      animation: progressShrink linear forwards;
      transform-origin: left;
    }
    .toast--success .toast-progress { color: var(--sapPositiveColor, #2b7d2b); }
    .toast--error .toast-progress   { color: var(--sapNegativeColor, #b00020); }
    .toast--warning .toast-progress { color: var(--sapCriticalColor, #e78c07); }
    .toast--info .toast-progress    { color: var(--sapInformativeColor, #0854a0); }

    @keyframes toastIn {
      from { transform: translateX(100%) scale(0.95); opacity: 0; }
      to   { transform: translateX(0) scale(1); opacity: 1; }
    }
    @keyframes progressShrink {
      from { transform: scaleX(1); }
      to   { transform: scaleX(0); }
    }
  `],
})
export class ToastComponent {
  toastService = inject(ToastService);

  getIcon(type: ToastType): string {
    const icons: Record<ToastType, string> = {
      success: '✓', error: '✕', warning: '⚠', info: 'ℹ',
    };
    return icons[type];
  }
}