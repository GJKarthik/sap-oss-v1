import { TestBed, fakeAsync, tick } from '@angular/core/testing';
import { of, throwError } from 'rxjs';
import { CacheService } from './cache.service';

describe('CacheService', () => {
  let service: CacheService;

  beforeEach(() => {
    TestBed.configureTestingModule({});
    service = TestBed.inject(CacheService);
  });

  // -------------------------------------------------------------------------
  // Fresh hit
  // -------------------------------------------------------------------------
  describe('Fresh cache (within staleTime)', () => {
    it('returns cached value without calling fetchFn again', (done) => {
      const fetchFn = jest.fn().mockReturnValue(of({ value: 42 }));

      service.get('/test', fetchFn).subscribe(() => {
        // Second call – should be a cache hit
        service.get('/test', fetchFn).subscribe((v) => {
          expect(fetchFn).toHaveBeenCalledTimes(1);
          expect((v as { value: number }).value).toBe(42);
          done();
        });
      });
    });
  });

  // -------------------------------------------------------------------------
  // Expired miss
  // -------------------------------------------------------------------------
  describe('Expired cache (beyond maxAge)', () => {
    it('calls fetchFn again when cache is expired', (done) => {
      const fetchFn = jest.fn()
        .mockReturnValueOnce(of({ v: 1 }))
        .mockReturnValueOnce(of({ v: 2 }));

      service.get('/expired', fetchFn, { staleTime: 0, maxAge: 0 }).subscribe(() => {
        setTimeout(() => {
          service.get('/expired', fetchFn, { staleTime: 0, maxAge: 0 }).subscribe((result) => {
            expect(fetchFn).toHaveBeenCalledTimes(2);
            done();
          });
        }, 5);
      });
    });
  });

  // -------------------------------------------------------------------------
  // Cache management
  // -------------------------------------------------------------------------
  describe('invalidate()', () => {
    it('removes the entry so the next get re-fetches', (done) => {
      const fetchFn = jest.fn().mockReturnValue(of({ ok: true }));

      service.get('/inv', fetchFn).subscribe(() => {
        service.invalidate('/inv');
        service.get('/inv', fetchFn).subscribe(() => {
          expect(fetchFn).toHaveBeenCalledTimes(2);
          done();
        });
      });
    });
  });

  describe('clear()', () => {
    it('resets all stats and cache entries', (done) => {
      const fetchFn = jest.fn().mockReturnValue(of({}));

      service.get('/c1', fetchFn).subscribe(() => {
        service.clear();
        expect(service.stats().entries).toBe(0);
        expect(service.stats().hits).toBe(0);
        done();
      });
    });
  });

  describe('has()', () => {
    it('returns false when nothing is cached', () => {
      expect(service.has('/missing')).toBe(false);
    });

    it('returns true immediately after a successful fetch', (done) => {
      service.get('/present', () => of({})).subscribe(() => {
        expect(service.has('/present')).toBe(true);
        done();
      });
    });
  });

  // -------------------------------------------------------------------------
  // Error propagation
  // -------------------------------------------------------------------------
  describe('error handling', () => {
    it('propagates errors and does not cache the failed response', (done) => {
      const fetchFn = jest.fn().mockReturnValue(throwError(() => new Error('fail')));

      service.get('/err', fetchFn).subscribe({
        error: () => {
          expect(service.has('/err')).toBe(false);
          done();
        },
      });
    });
  });

  // -------------------------------------------------------------------------
  // Stats
  // -------------------------------------------------------------------------
  describe('stats()', () => {
    it('increments miss count on first fetch', (done) => {
      service.get('/stat', () => of({})).subscribe(() => {
        expect(service.stats().misses).toBe(1);
        expect(service.stats().hits).toBe(0);
        done();
      });
    });

    it('increments hit count on fresh cache access', (done) => {
      service.get('/stat2', () => of({})).subscribe(() => {
        service.get('/stat2', () => of({})).subscribe(() => {
          expect(service.stats().hits).toBe(1);
          done();
        });
      });
    });
  });
});
