/**
 * Configuration for the OCR client.
 * Only `endpoint` is required. Everything else has sensible defaults.
 */
export interface OCRConfig {
  /** URL of the OCR service (e.g. "http://localhost:8000"). */
  endpoint: string;

  /** Request timeout in milliseconds. Default: 120_000 (2 min). */
  timeout?: number;

  /** Custom headers sent with every request. */
  headers?: Record<string, string>;
}

/**
 * Options for a single scan call.
 */
export interface ScanOptions {
  /** First page to process (1-based). Default: all. */
  startPage?: number;

  /** Last page to process (1-based). Default: all. */
  endPage?: number;

  /** Detect tables in the document. Default: true. */
  detectTables?: boolean;

  /** URL to POST the result to when done. */
  callbackUrl?: string;
}

/**
 * Text extracted from a single page.
 */
export interface PageResult {
  /** 1-based page number. */
  page: number;

  /** Extracted text. */
  text: string;

  /** OCR confidence (0–100). */
  confidence: number;
}

/**
 * Result of scanning a document.
 */
export interface ScanResult {
  /** Full extracted text (all pages joined). */
  text: string;

  /** Per-page results. */
  pages: PageResult[];

  /** Overall confidence (0–100). */
  confidence: number;

  /** Total pages in the document. */
  totalPages: number;

  /** Processing time in seconds. */
  processingTime: number;

  /** Save the result to a JSON string. */
  toJSON(): string;
}

