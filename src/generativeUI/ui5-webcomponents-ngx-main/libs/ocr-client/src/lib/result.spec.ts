import { buildResult } from './result';

describe('buildResult', () => {
  it('builds a ScanResult from raw API response', () => {
    const raw = {
      file_path: '/test.pdf',
      total_pages: 2,
      overall_confidence: 91.5,
      total_processing_time_ms: 1230,
      pages: [
        { page_number: 1, text: 'Hello', confidence: 95.0 },
        { page_number: 2, text: 'World', confidence: 88.0 },
      ],
    };

    const result = buildResult(raw);

    expect(result.text).toBe('Hello\n\nWorld');
    expect(result.pages).toHaveLength(2);
    expect(result.pages[0].page).toBe(1);
    expect(result.pages[0].text).toBe('Hello');
    expect(result.pages[0].confidence).toBe(95.0);
    expect(result.pages[1].page).toBe(2);
    expect(result.confidence).toBe(91.5);
    expect(result.totalPages).toBe(2);
    expect(result.processingTime).toBe(1.23);
  });

  it('handles empty pages', () => {
    const result = buildResult({ total_pages: 0, pages: [] });

    expect(result.text).toBe('');
    expect(result.pages).toHaveLength(0);
    expect(result.totalPages).toBe(0);
  });

  it('toJSON produces valid JSON', () => {
    const raw = {
      total_pages: 1,
      overall_confidence: 80,
      pages: [{ page_number: 1, text: 'Test', confidence: 80 }],
    };

    const result = buildResult(raw);
    const parsed = JSON.parse(result.toJSON());

    expect(parsed.text).toBe('Test');
    expect(parsed.pages).toHaveLength(1);
    expect(parsed.confidence).toBe(80);
  });

  it('handles missing fields gracefully', () => {
    const result = buildResult({});

    expect(result.text).toBe('');
    expect(result.pages).toHaveLength(0);
    expect(result.confidence).toBe(0);
    expect(result.totalPages).toBe(0);
    expect(result.processingTime).toBe(0);
  });
});
