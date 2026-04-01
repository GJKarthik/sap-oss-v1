import { HttpClient } from '@angular/common/http';
import { of } from 'rxjs';
import { GenerativeRuntimeService } from './generative-runtime.service';

function makeHttp() {
  return {
    post: jest.fn(),
  } as unknown as HttpClient;
}

describe('GenerativeRuntimeService', () => {
  it('accepts schema wrapper response contract', () => {
    const http = makeHttp();
    (http.post as jest.Mock).mockReturnValue(of({ schema: { type: 'ui5-card' } }));
    const service = new GenerativeRuntimeService(http);
    let result: unknown;

    service.generateSchema('build card').subscribe((schema) => {
      result = schema;
    });

    expect(result).toEqual({ type: 'ui5-card' });
  });

  it('throws for invalid schema contract', () => {
    const http = makeHttp();
    (http.post as jest.Mock).mockReturnValue(of({ schema: { bad: true } }));
    const service = new GenerativeRuntimeService(http);
    let capturedError = '';

    service.generateSchema('invalid').subscribe({
      error: (err: Error) => {
        capturedError = err.message;
      },
    });

    expect(capturedError).toContain('Invalid generative schema contract');
  });
});
