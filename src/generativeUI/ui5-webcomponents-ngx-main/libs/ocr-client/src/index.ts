/**
 * @ui5/ocr-client — One function to extract text from any document.
 *
 * @example
 * ```ts
 * import { scan } from '@ui5/ocr-client';
 *
 * const result = await scan('invoice.pdf');
 * console.log(result.text);
 * ```
 *
 * @example
 * ```ts
 * import { OCR } from '@ui5/ocr-client';
 *
 * const ocr = new OCR({ endpoint: 'https://ocr.mycompany.com' });
 * const result = await ocr.scan(pdfBlob);
 * result.pages.forEach(p => console.log(p.text));
 * ```
 */

export { scan } from './lib/scan';
export { OCR } from './lib/ocr';
export type { ScanResult, PageResult, ScanOptions, OCRConfig } from './lib/types';

