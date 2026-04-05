import { buildResult } from './result';
import { OCRConfig, ScanOptions, ScanResult } from './types';

const DEFAULT_TIMEOUT = 120_000;

/** First bytes of a PDF file (`%PDF`). */
const PDF_MAGIC = new Uint8Array([0x25, 0x50, 0x44, 0x46]);

function looksLikePdf(buffer: ArrayBuffer): boolean {
  const u8 = new Uint8Array(buffer);
  if (u8.length < PDF_MAGIC.length) {
    return false;
  }
  for (let i = 0; i < PDF_MAGIC.length; i++) {
    if (u8[i] !== PDF_MAGIC[i]) {
      return false;
    }
  }
  return true;
}

/** First *maxBytes* of a blob (handles engines without ``slice().arrayBuffer``). */
async function blobHeadArrayBuffer(blob: Blob, maxBytes: number): Promise<ArrayBuffer> {
  const sliced = blob.slice(0, maxBytes);
  if (typeof sliced.arrayBuffer === 'function') {
    return sliced.arrayBuffer();
  }
  if (typeof blob.arrayBuffer === 'function') {
    const full = await blob.arrayBuffer();
    return full.byteLength <= maxBytes ? full : full.slice(0, maxBytes);
  }
  if (typeof Response !== 'undefined') {
    return new Response(sliced).arrayBuffer();
  }
  throw new TypeError('Cannot read blob header: missing Blob#arrayBuffer');
}

/**
 * OCR client. One class, three methods.
 *
 * @example
 * ```ts
 * const ocr = new OCR({ endpoint: 'http://localhost:8000' });
 *
 * // Scan a file
 * const result = await ocr.scan(file);
 * console.log(result.text);
 *
 * // Check service health
 * const healthy = await ocr.healthy();
 * ```
 */
export class OCR {
  private readonly endpoint: string;
  private readonly timeout: number;
  private readonly headers: Record<string, string>;

  constructor(config: OCRConfig) {
    this.endpoint = config.endpoint.replace(/\/+$/, '');
    this.timeout = config.timeout ?? DEFAULT_TIMEOUT;
    this.headers = config.headers ?? {};
  }

  /**
   * Scan a document. Accepts a File, Blob, or URL string.
   *
   * - `.pdf` → PDF endpoint
   * - everything else → image endpoint
   */
  async scan(
    input: File | Blob | string,
    options?: ScanOptions,
  ): Promise<ScanResult> {
    const { file, isPdf } = await this.resolveInput(input);
    const path = isPdf ? '/ocr/pdf' : '/ocr/image';

    const params = new URLSearchParams();
    if (options?.startPage) params.set('start_page', String(options.startPage));
    if (options?.endPage) params.set('end_page', String(options.endPage));
    if (options?.detectTables === false) params.set('detect_tables', 'false');
    if (options?.callbackUrl) params.set('callback_url', options.callbackUrl);

    const qs = params.toString();
    const url = `${this.endpoint}${path}${qs ? '?' + qs : ''}`;

    const form = new FormData();
    form.append('file', file);

    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), this.timeout);

    try {
      const resp = await fetch(url, {
        method: 'POST',
        headers: this.headers,
        body: form,
        signal: controller.signal,
      });

      if (!resp.ok) {
        const detail = await resp.text().catch(() => resp.statusText);
        throw new Error(`OCR failed (${resp.status}): ${detail}`);
      }

      const raw = await resp.json();
      return buildResult(raw);
    } finally {
      clearTimeout(timer);
    }
  }

  /**
   * Check if the OCR service is reachable and healthy.
   */
  async healthy(): Promise<boolean> {
    try {
      const resp = await fetch(`${this.endpoint}/ocr/health`, {
        headers: this.headers,
        signal: AbortSignal.timeout(5_000),
      });
      if (!resp.ok) return false;
      const data = await resp.json();
      return (
        data.status === 'healthy' ||
        data.status === 'ok' ||
        data.status === 'degraded'
      );
    } catch {
      return false;
    }
  }

  /** Normalize input to a File/Blob + detect PDF. */
  private async resolveInput(
    input: File | Blob | string,
  ): Promise<{ file: File | Blob; isPdf: boolean }> {
    if (typeof input === 'string') {
      // URL or file path — fetch it
      const resp = await fetch(input);
      if (!resp.ok) throw new Error(`Cannot fetch ${input}: ${resp.status}`);
      const blob = await resp.blob();
      const name = input.split('/').pop() || 'document';
      const head = await blobHeadArrayBuffer(blob, 8);
      const isPdf =
        name.toLowerCase().endsWith('.pdf') || looksLikePdf(head);
      return { file: new File([blob], name), isPdf };
    }

    const name = input instanceof File ? input.name : 'upload';
    const head = await blobHeadArrayBuffer(input, 8);
    const isPdf =
      name.toLowerCase().endsWith('.pdf') || looksLikePdf(head);
    return { file: input, isPdf };
  }
}
