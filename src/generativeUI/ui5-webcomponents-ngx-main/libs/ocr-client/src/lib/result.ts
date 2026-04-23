import { PageResult, ScanResult } from './types';

/**
 * Build a ScanResult from the raw API response.
 * This is internal — users never import this.
 */
export function buildResult(raw: Record<string, any>): ScanResult {
  const pages: PageResult[] = (raw['pages'] || []).map((p: any) => ({
    page: p['page_number'] ?? p['page'] ?? 0,
    text: p['text'] ?? '',
    confidence: p['confidence'] ?? 0,
  }));

  const text = pages.map((p) => p.text).join('\n\n');
  const confidence = raw['overall_confidence'] ?? 0;
  const totalPages = raw['total_pages'] ?? pages.length;
  const processingTime = (raw['total_processing_time_ms'] ?? 0) / 1000;

  return {
    text,
    pages,
    confidence,
    totalPages,
    processingTime,
    toJSON() {
      return JSON.stringify(
        { text, pages, confidence, totalPages, processingTime },
        null,
        2,
      );
    },
  };
}
