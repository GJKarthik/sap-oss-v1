import { TestBed } from '@angular/core/testing';
import { clearCache, layout, prepare } from '@chenglou/pretext';
import { TextLayoutService } from './text-layout.service';

jest.mock('@chenglou/pretext', () => ({
  clearCache: jest.fn(),
  layout: jest.fn(),
  prepare: jest.fn(),
}));

describe('TextLayoutService', () => {
  let service: TextLayoutService;

  beforeEach(() => {
    jest.clearAllMocks();
    TestBed.configureTestingModule({
      providers: [TextLayoutService],
    });
    service = TestBed.inject(TextLayoutService);
  });

  it('caches prepared text and reuses it across repeated measurements', () => {
    (prepare as jest.Mock).mockReturnValue({ token: 'prepared' });
    (layout as jest.Mock).mockReturnValue({ lineCount: 2, height: 44 });

    const first = service.measureHeight('hello world', { maxWidth: 300, lineHeight: 22 });
    const second = service.measureHeight('hello world', { maxWidth: 400, lineHeight: 22 });

    expect(first).toBe(44);
    expect(second).toBe(44);
    expect(prepare).toHaveBeenCalledTimes(1);
    expect(layout).toHaveBeenCalledTimes(2);
  });

  it('falls back to heuristic height when pretext throws', () => {
    (prepare as jest.Mock).mockImplementation(() => {
      throw new Error('canvas unavailable');
    });

    const height = service.measureHeight('a long line that still needs a stable fallback', {
      maxWidth: 180,
      lineHeight: 20,
      minLines: 2,
    });

    expect(height).toBeGreaterThanOrEqual(40);
  });

  it('honors min/max line bounds from layout result', () => {
    (prepare as jest.Mock).mockReturnValue({ token: 'prepared' });
    (layout as jest.Mock).mockReturnValue({ lineCount: 9, height: 198 });

    const height = service.measureHeight('bounded text', {
      maxWidth: 240,
      lineHeight: 22,
      minLines: 1,
      maxLines: 3,
    });

    expect(height).toBe(66);
  });

  it('clears internal and pretext caches', () => {
    service.clear();
    expect(clearCache).toHaveBeenCalledTimes(1);
  });
});

