import {
  HttpEvent,
  HttpHandler,
  HttpInterceptor,
  HttpRequest,
} from '@angular/common/http';
import { Injectable } from '@angular/core';
import { Observable } from 'rxjs';

@Injectable()
export class RequestTraceInterceptor implements HttpInterceptor {
  intercept(
    request: HttpRequest<unknown>,
    next: HttpHandler,
  ): Observable<HttpEvent<unknown>> {
    if (request.headers.has('x-correlation-id')) {
      return next.handle(request);
    }

    const tracedRequest = request.clone({
      setHeaders: {
        'x-correlation-id': this.createCorrelationId(),
      },
    });
    return next.handle(tracedRequest);
  }

  private createCorrelationId(): string {
    if (typeof crypto !== 'undefined' && typeof crypto.randomUUID === 'function') {
      return crypto.randomUUID();
    }
    return `cid-${Date.now()}-${Math.floor(Math.random() * 1_000_000)}`;
  }
}
