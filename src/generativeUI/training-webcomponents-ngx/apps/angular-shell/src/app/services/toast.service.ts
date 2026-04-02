import { Injectable, signal, computed } from '@angular/core';

export type ToastType = 'success' | 'error' | 'warning' | 'info';

export interface Toast {
  id: string;
  type: ToastType;
  message: string;
  title?: string;
  duration: number;
}

@Injectable({ providedIn: 'root' })
export class ToastService {
  private _toasts = signal<Toast[]>([]);
  
  readonly toasts = this._toasts.asReadonly();
  readonly hasToasts = computed(() => this._toasts().length > 0);

  private idCounter = 0;

  show(message: string, type: ToastType = 'info', title?: string, duration = 5000): string {
    const id = `toast-${++this.idCounter}`;
    const toast: Toast = { id, type, message, title, duration };
    
    this._toasts.update((currentToasts: Toast[]) => [...currentToasts, toast]);

    if (duration > 0) {
      setTimeout(() => this.dismiss(id), duration);
    }

    return id;
  }

  success(message: string, title?: string, duration?: number): string {
    return this.show(message, 'success', title ?? 'Success', duration);
  }

  error(message: string, title?: string, duration?: number): string {
    return this.show(message, 'error', title ?? 'Error', duration ?? 8000);
  }

  warning(message: string, title?: string, duration?: number): string {
    return this.show(message, 'warning', title ?? 'Warning', duration ?? 6000);
  }

  info(message: string, title?: string, duration?: number): string {
    return this.show(message, 'info', title ?? 'Info', duration);
  }

  dismiss(id: string): void {
    this._toasts.update((currentToasts: Toast[]) => currentToasts.filter((t: Toast) => t.id !== id));
  }

  dismissAll(): void {
    this._toasts.set([]);
  }
}