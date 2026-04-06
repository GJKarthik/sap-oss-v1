import { ApplicationConfig, provideZoneChangeDetection, ErrorHandler, provideAppInitializer, inject } from '@angular/core';
import { provideRouter, withComponentInputBinding, withViewTransitions } from '@angular/router';
import { provideHttpClient, withInterceptors, withFetch } from '@angular/common/http';
import { routes } from './app.routes';
import { authInterceptor } from './interceptors/auth.interceptor';
import { cacheInterceptor } from './interceptors/cache.interceptor';
import { diagnosticsInterceptor } from './interceptors/diagnostics.interceptor';
import { errorInterceptor } from './interceptors/error.interceptor';
import { timeoutInterceptor } from './interceptors/timeout.interceptor';
import { GlobalErrorHandler } from './core/global-error-handler';
import { I18nService } from './services/i18n.service';

/**
 * Application configuration with providers for routing, HTTP client,
 * and interceptors for auth and error handling.
 */
export const appConfig: ApplicationConfig = {
  providers: [
    provideZoneChangeDetection({ eventCoalescing: true }),
    { provide: ErrorHandler, useClass: GlobalErrorHandler },
    provideAppInitializer(() => inject(I18nService).loadTranslations()),
    provideRouter(
      routes,
      withComponentInputBinding(),
      withViewTransitions()
    ),
    provideHttpClient(
      withFetch(),
      withInterceptors([authInterceptor, timeoutInterceptor, cacheInterceptor, diagnosticsInterceptor, errorInterceptor])
    ),
  ],
};