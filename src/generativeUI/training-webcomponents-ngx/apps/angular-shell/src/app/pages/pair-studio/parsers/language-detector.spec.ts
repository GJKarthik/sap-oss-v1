import { detectLanguage, normalizeNumerals } from './language-detector';

describe('detectLanguage', () => {
  it('should detect Arabic text', () => {
    const result = detectLanguage('هذا نص عربي للاختبار');
    expect(result.lang).toBe('ar');
    expect(result.confidence).toBeGreaterThan(0.7);
  });

  it('should detect English text', () => {
    const result = detectLanguage('This is an English test paragraph with multiple words.');
    expect(result.lang).toBe('en');
    expect(result.confidence).toBeGreaterThan(0.5);
  });

  it('should detect Korean text', () => {
    const result = detectLanguage('이것은 한국어 테스트 텍스트입니다');
    expect(result.lang).toBe('ko');
    expect(result.confidence).toBeGreaterThan(0.7);
  });

  it('should detect Chinese text', () => {
    const result = detectLanguage('这是一个中文测试文本');
    expect(result.lang).toBe('zh');
    expect(result.confidence).toBeGreaterThan(0.7);
  });

  it('should return "unknown" for empty or very short text', () => {
    const result = detectLanguage('');
    expect(result.lang).toBe('unknown');
    expect(result.confidence).toBe(0);
  });

  it('should handle mixed-script text with majority wins', () => {
    const result = detectLanguage('مرحبا hello عالم world هذا نص مختلط');
    // Arabic characters outnumber Latin
    expect(result.lang).toBe('ar');
  });

  it('should detect French text', () => {
    const result = detectLanguage("C'est un texte français avec des accents éàü pour le test");
    expect(result.lang).toBe('fr');
  });

  it('should detect German text', () => {
    const result = detectLanguage('Dies ist ein deutscher Text mit Umlauten über Straße');
    expect(result.lang).toBe('de');
  });
});

describe('normalizeNumerals', () => {
  it('should convert Arabic-Indic numerals to Western', () => {
    const result = normalizeNumerals('١٢٣٤٥');
    expect(result).toBe('12345');
  });

  it('should leave Western numerals unchanged', () => {
    const result = normalizeNumerals('12345');
    expect(result).toBe('12345');
  });

  it('should handle mixed numerals', () => {
    const result = normalizeNumerals('Total: ١٢٣ items = 123');
    expect(result).toContain('123');
  });
});
