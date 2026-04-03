import { OCR } from './ocr';

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
  constructor(
    public parts: any[],
    public name: string,
  ) {}
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
          blob: () => Promise.resolve(new Blob()),
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

