import { parseCsv, parseJson, ParseResult } from './structured-parser';
import { PairType } from '../pair-studio.types';

const DEFAULT_OPTS = {
  defaultPairType: 'translation' as PairType,
  defaultSourceLang: 'en',
  defaultTargetLang: 'ar',
  defaultCategory: 'general',
};

describe('parseCsv', () => {
  it('should parse a basic CSV with standard headers', () => {
    const csv = `source_text,target_text,category
Revenue,إيرادات,financial
Balance,رصيد,financial`;

    const result = parseCsv(csv, DEFAULT_OPTS);
    expect(result.errors).toHaveLength(0);
    expect(result.termPairs).toHaveLength(2);
    expect(result.termPairs[0].sourceTerm).toBe('Revenue');
    expect(result.termPairs[0].targetTerm).toBe('إيرادات');
    expect(result.termPairs[0].category).toBe('financial');
  });

  it('should accept alias headers (source, target)', () => {
    const csv = `source,target
Hello,مرحبا`;

    const result = parseCsv(csv, DEFAULT_OPTS);
    expect(result.errors).toHaveLength(0);
    expect(result.termPairs).toHaveLength(1);
  });

  it('should error on missing required columns', () => {
    const csv = `name,description
foo,bar`;

    const result = parseCsv(csv, DEFAULT_OPTS);
    expect(result.errors.length).toBeGreaterThan(0);
    expect(result.termPairs).toHaveLength(0);
  });

  it('should skip rows with empty source or target', () => {
    const csv = `source_text,target_text
Revenue,إيرادات
,empty_source
empty_target,`;

    const result = parseCsv(csv, DEFAULT_OPTS);
    expect(result.termPairs).toHaveLength(1);
  });

  it('should handle quoted fields with commas', () => {
    const csv = `source_text,target_text
"Revenue, Total",إيرادات إجمالية`;

    const result = parseCsv(csv, DEFAULT_OPTS);
    expect(result.termPairs).toHaveLength(1);
    expect(result.termPairs[0].sourceTerm).toBe('Revenue, Total');
  });

  it('should apply defaults for missing optional columns', () => {
    const csv = `source_text,target_text
Test,اختبار`;

    const result = parseCsv(csv, DEFAULT_OPTS);
    expect(result.termPairs[0].sourceLang).toBe('en');
    expect(result.termPairs[0].targetLang).toBe('ar');
    expect(result.termPairs[0].pairType).toBe('translation');
    expect(result.termPairs[0].confidence).toBe(1.0);
  });

  it('should handle BOM character', () => {
    const csv = `\uFEFFsource_text,target_text
Revenue,إيرادات`;

    const result = parseCsv(csv, DEFAULT_OPTS);
    expect(result.errors).toHaveLength(0);
    expect(result.termPairs).toHaveLength(1);
  });

  it('should error on CSV with only headers', () => {
    const csv = `source_text,target_text`;

    const result = parseCsv(csv, DEFAULT_OPTS);
    expect(result.errors.length).toBeGreaterThan(0);
  });

  it('should read source_lang and target_lang from columns', () => {
    const csv = `source_text,target_text,source_lang,target_lang
Hello,Bonjour,en,fr`;

    const result = parseCsv(csv, DEFAULT_OPTS);
    expect(result.termPairs[0].sourceLang).toBe('en');
    expect(result.termPairs[0].targetLang).toBe('fr');
  });

  it('should set all pairs to pending status', () => {
    const csv = `source_text,target_text
A,B
C,D`;

    const result = parseCsv(csv, DEFAULT_OPTS);
    result.termPairs.forEach((tp) => {
      expect(tp.status).toBe('pending');
      expect(tp.existsInGlossary).toBe(false);
    });
  });
});

describe('parseJson', () => {
  it('should parse a JSON array of term objects', () => {
    const json = JSON.stringify([
      { source_text: 'Revenue', target_text: 'إيرادات', category: 'financial' },
      { source_text: 'Balance', target_text: 'رصيد', category: 'financial' },
    ]);

    const result = parseJson(json, DEFAULT_OPTS);
    expect(result.errors).toHaveLength(0);
    expect(result.termPairs).toHaveLength(2);
    expect(result.termPairs[0].sourceTerm).toBe('Revenue');
  });

  it('should accept wrapped JSON with entries key', () => {
    const json = JSON.stringify({
      entries: [{ source: 'A', target: 'ب' }],
    });

    const result = parseJson(json, DEFAULT_OPTS);
    expect(result.termPairs).toHaveLength(1);
  });

  it('should accept alternative field names (sourceTerm, targetTerm)', () => {
    const json = JSON.stringify([
      { sourceTerm: 'Test', targetTerm: 'اختبار' },
    ]);

    const result = parseJson(json, DEFAULT_OPTS);
    expect(result.termPairs).toHaveLength(1);
  });

  it('should error on invalid JSON', () => {
    const result = parseJson('not json at all', DEFAULT_OPTS);
    expect(result.errors.length).toBeGreaterThan(0);
    expect(result.termPairs).toHaveLength(0);
  });

  it('should skip entries without source or target', () => {
    const json = JSON.stringify([
      { source_text: 'Valid', target_text: 'صالح' },
      { source_text: '', target_text: 'empty' },
      { source_text: 'noTarget' },
    ]);

    const result = parseJson(json, DEFAULT_OPTS);
    expect(result.termPairs).toHaveLength(1);
  });

  it('should preserve confidence from data', () => {
    const json = JSON.stringify([
      { source_text: 'A', target_text: 'ب', confidence: 0.75 },
    ]);

    const result = parseJson(json, DEFAULT_OPTS);
    expect(result.termPairs[0].confidence).toBe(0.75);
  });

  it('should apply defaults when fields are missing', () => {
    const json = JSON.stringify([{ source: 'X', target: 'ع' }]);

    const result = parseJson(json, DEFAULT_OPTS);
    expect(result.termPairs[0].sourceLang).toBe('en');
    expect(result.termPairs[0].targetLang).toBe('ar');
    expect(result.termPairs[0].pairType).toBe('translation');
    expect(result.termPairs[0].category).toBe('general');
  });
});
