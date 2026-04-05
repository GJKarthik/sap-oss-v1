import { OCR } from './ocr';

function u8FromParts(parts: BlobPart[]): Uint8Array {
  const chunks: Uint8Array[] = [];
  let len = 0;
  for (const p of parts) {
    let u: Uint8Array;
    if (p instanceof Uint8Array) {
      u = p;
    } else if (p instanceof ArrayBuffer) {
      u = new Uint8Array(p);
    } else if (typeof p === 'string') {
      u = new TextEncoder().encode(p);
    } else {
      u = new Uint8Array(0);
    }
    chunks.push(u);
    len += u.length;
  }
  const merged = new Uint8Array(len);
  let o = 0;
  for (const u of chunks) {
    merged.set(u, o);
    o += u.length;
  }
  return merged;
}

/** Minimal Blob-like for Jest (no reliance on global Blob#arrayBuffer). */
function mockBlobBytes(u8: Uint8Array) {
  return {
    slice(start = 0, end = u8.length) {
      const sub = u8.subarray(start, end);
      return {
        async arrayBuffer(): Promise<ArrayBuffer> {
          const c = new Uint8Array(sub.byteLength);
          c.set(sub);
          return c.buffer;
        },
      };
    },
    async arrayBuffer(): Promise<ArrayBuffer> {
      const c = new Uint8Array(u8.byteLength);
      c.set(u8);
      return c.buffer;
    },
  };
}

// Mock fetch globally
const mockFetch = jest.fn();
(global as any).fetch = mockFetch;
(global as any).FormData = class {
  private data: Record<string, any> = {};
  append(key: string, value: any) {
    this.data[key] = value;
  }
};
(global as any).File = class {
  private readonly _bytes: Uint8Array;

  constructor(parts: BlobPart[], public name: string) {
    this._bytes = u8FromParts(parts);
  }

  slice(start = 0, end = this._bytes.length): Blob {
    return mockBlobBytes(this._bytes.subarray(start, end)) as unknown as Blob;
  }

  arrayBuffer(): Promise<ArrayBuffer> {
    const c = new Uint8Array(this._bytes.byteLength);
    c.set(this._bytes);
    return Promise.resolve(c.buffer);
  }
};
(global as any).AbortSignal = {
  timeout: () => new AbortController().signal,
};

const MOCK_RESPONSE = {
  total_pages: 1,
  overall_confidence: 92.0,
  total_processing_time_s: 0.5,
  pages: [{ page_number: 1, text: 'Hello World', confidence: 92.0 }],
};

describe('OCR', () => {
  let ocr: OCR;

  beforeEach(() => {
    mockFetch.mockReset();
    ocr = new OCR({ endpoint: 'http://localhost:8000' });
  });

  describe('scan', () => {
    it('sends PDF to /ocr/pdf', async () => {
      mockFetch.mockResolvedValue({
        ok: true,
        json: () => Promise.resolve(MOCK_RESPONSE),
      });

      const blob = new (global as any).File([], 'test.pdf');
      const result = await ocr.scan(blob);

      expect(mockFetch).toHaveBeenCalledTimes(1);
      const [url] = mockFetch.mock.calls[0];
      expect(url).toBe('http://localhost:8000/ocr/pdf');
      expect(result.text).toBe('Hello World');
      expect(result.confidence).toBe(92.0);
      expect(result.totalPages).toBe(1);
    });

    it('sends PDF to /ocr/pdf when magic bytes match without .pdf name', async () => {
      mockFetch.mockResolvedValue({
        ok: true,
        json: () => Promise.resolve(MOCK_RESPONSE),
      });
      const pdfMagic = new Uint8Array([0x25, 0x50, 0x44, 0x46, 0x2d, 0x31]); // %PDF-1
      const file = new (global as any).File([pdfMagic], 'upload.bin');
      await ocr.scan(file);
      const [url] = mockFetch.mock.calls[0];
      expect(url).toBe('http://localhost:8000/ocr/pdf');
    });

    it('sends image to /ocr/image', async () => {
      mockFetch.mockResolvedValue({
        ok: true,
        json: () => Promise.resolve({
          page_number: 1,
          text: 'Image text',
          confidence: 85.0,
        }),
      });

      const blob = new (global as any).File([], 'scan.png');
      const result = await ocr.scan(blob);

      const [url] = mockFetch.mock.calls[0];
      expect(url).toBe('http://localhost:8000/ocr/image');
    });

    it('passes options as query params', async () => {
      mockFetch.mockResolvedValue({
        ok: true,
        json: () => Promise.resolve(MOCK_RESPONSE),
      });

      const blob = new (global as any).File([], 'doc.pdf');
      await ocr.scan(blob, { startPage: 2, endPage: 5, detectTables: false });

      const [url] = mockFetch.mock.calls[0];
      expect(url).toContain('start_page=2');
      expect(url).toContain('end_page=5');
      expect(url).toContain('detect_tables=false');
    });

    it('throws on non-OK response', async () => {
      mockFetch.mockResolvedValue({
        ok: false,
        status: 500,
        statusText: 'Internal Server Error',
        text: () => Promise.resolve('something broke'),
      });

      const blob = new (global as any).File([], 'bad.pdf');
      await expect(ocr.scan(blob)).rejects.toThrow('OCR failed (500)');
    });

    it('fetches URL input before scanning', async () => {
      mockFetch
        // First call: fetch the URL
        .mockResolvedValueOnce({
          ok: true,
          blob: () => Promise.resolve(mockBlobBytes(new Uint8Array(0))),
        })
        // Second call: POST to OCR
        .mockResolvedValueOnce({
          ok: true,
          json: () => Promise.resolve(MOCK_RESPONSE),
        });

      const result = await ocr.scan('https://example.com/doc.pdf');

      expect(mockFetch).toHaveBeenCalledTimes(2);
      expect(result.text).toBe('Hello World');
    });
  });

  describe('healthy', () => {
    it('returns true when service is healthy', async () => {
      mockFetch.mockResolvedValue({
        ok: true,
        json: () => Promise.resolve({ status: 'healthy' }),
      });

      expect(await ocr.healthy()).toBe(true);
    });

    it('returns true when service is ok', async () => {
      mockFetch.mockResolvedValue({
        ok: true,
        json: () => Promise.resolve({ status: 'ok' }),
      });

      expect(await ocr.healthy()).toBe(true);
    });

    it('returns true when service is degraded', async () => {
      mockFetch.mockResolvedValue({
        ok: true,
        json: () => Promise.resolve({ status: 'degraded' }),
      });

      expect(await ocr.healthy()).toBe(true);
    });

    it('returns false on network error', async () => {
      mockFetch.mockRejectedValue(new Error('ECONNREFUSED'));

      expect(await ocr.healthy()).toBe(false);
    });

    it('returns false on non-OK response', async () => {
      mockFetch.mockResolvedValue({ ok: false, status: 503 });

      expect(await ocr.healthy()).toBe(false);
    });
  });
});
