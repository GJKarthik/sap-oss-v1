import { ErrorHandler, Injectable, Injector, NgZone } from '@angular/core';
import { ToastService } from '../services/toast.service';
import { LogService } from '../services/log.service';

@Injectable()
export class GlobalErrorHandler implements ErrorHandler {
  constructor(private injector: Injector, private zone: NgZone) {}

  handleError(error: unknown): void {
    const toast = this.injector.get(ToastService);
    let message = 'An unexpected error occurred';
    
    if (error instanceof Error) {
      message = error.message;
    } else if (typeof error === 'string') {
      message = error;
    } else if (error && typeof error === 'object' && 'toString' in error) {
      message = error.toString();
    }

    // Ensure toast execution is running inside the Angular zone
    this.zone.run(() => {
      toast.error(message, 'Application Error');
    });

    const log = this.injector.get(LogService);
    log.error('Unhandled application error', 'GlobalErrorHandler', error);
  }
}
