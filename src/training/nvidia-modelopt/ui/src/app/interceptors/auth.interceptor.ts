import { HttpInterceptorFn, HttpRequest, HttpHandlerFn } from '@angular/common/http';

/**
 * Authentication interceptor for API requests.
 * Adds Authorization header if token is available.
 *
 * Security note: sessionStorage is used instead of localStorage so that
 * API keys are scoped to the browser tab and cleared when the tab closes,
 * reducing the window of exposure from XSS attacks.
 */

const STORAGE_KEY = 'modelopt_api_key';

export const authInterceptor: HttpInterceptorFn = (
  req: HttpRequest<unknown>,
  next: HttpHandlerFn
) => {
  const token = sessionStorage.getItem(STORAGE_KEY);

  if (token) {
    const authReq = req.clone({
      setHeaders: {
        Authorization: `Bearer ${token}`
      }
    });
    return next(authReq);
  }

  return next(req);
};