import { HttpRequest, type HttpHandler, type HttpEvent } from '@angular/common/http';
import { of, firstValueFrom } from 'rxjs';
import { RequestTraceInterceptor } from './request-trace.interceptor';

describe('RequestTraceInterceptor', () => {
  it('adds x-correlation-id header when missing', async () => {
    const interceptor = new RequestTraceInterceptor();
    const request = new HttpRequest('GET', '/health');
    const handle = jest.fn().mockReturnValue(of({} as HttpEvent<unknown>));
    const handler: HttpHandler = {
      handle,
    };

    await firstValueFrom(interceptor.intercept(request, handler));

    expect(handle).toHaveBeenCalledTimes(1);
    const forwarded = handle.mock.calls[0][0] as HttpRequest<unknown>;
    expect(forwarded.headers.has('x-correlation-id')).toBe(true);
  });

  it('preserves existing x-correlation-id header', async () => {
    const interceptor = new RequestTraceInterceptor();
    const request = new HttpRequest('GET', '/health', {
      headers: undefined,
    }).clone({ setHeaders: { 'x-correlation-id': 'fixed-id' } });
    const handle = jest.fn().mockReturnValue(of({} as HttpEvent<unknown>));
    const handler: HttpHandler = {
      handle,
    };

    await firstValueFrom(interceptor.intercept(request, handler));

    expect(handle).toHaveBeenCalledTimes(1);
    const forwarded = handle.mock.calls[0][0] as HttpRequest<unknown>;
    expect(forwarded.headers.get('x-correlation-id')).toBe('fixed-id');
  });
});
