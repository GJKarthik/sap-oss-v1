import { OCR } from './ocr';
import { ScanOptions, ScanResult } from './types';

/**
 * Default endpoint — can be overridden via environment or by using
 * the OCR class directly.
 */
const DEFAULT_ENDPOINT =
  (typeof process !== 'undefined' && process.env?.['OCR_ENDPOINT']) ||
  'http://localhost:8000';

/**
 * Scan a document in one line.
 *
 * @example
 * ```ts
 * import { scan } from '@ui5/ocr-client';
 *
 * const result = await scan('invoice.pdf');
 * console.log(result.text);
 * ```
 *
 * @param input - File, Blob, or URL to the document.
 * @param options - Optional: page range, table detection, callback URL.
 * @returns The extracted text and per-page results.
 */
export async function scan(
  input: File | Blob | string,
  options?: ScanOptions,
): Promise<ScanResult> {
  const ocr = new OCR({ endpoint: DEFAULT_ENDPOINT });
  return ocr.scan(input, options);
}

