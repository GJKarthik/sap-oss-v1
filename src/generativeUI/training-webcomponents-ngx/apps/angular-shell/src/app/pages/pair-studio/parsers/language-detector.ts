/**
 * Language Detector — per-paragraph language classification.
 *
 * Uses Unicode range analysis to classify text as Arabic, Latin-based
 * (English/French/German/Indonesian), CJK (Chinese/Korean), or mixed.
 * No external dependencies required.
 */

export interface LanguageDetection {
  lang: string;
  confidence: number;
  isAmbiguous: boolean;
}

// Unicode ranges
const ARABIC_RANGE = /[\u0600-\u06FF\u0750-\u077F\u08A0-\u08FF\uFB50-\uFDFF\uFE70-\uFEFF]/g;
const LATIN_RANGE = /[A-Za-z\u00C0-\u024F\u1E00-\u1EFF]/g;
const CJK_RANGE = /[\u4E00-\u9FFF\u3400-\u4DBF\uF900-\uFAFF]/g;
const HANGUL_RANGE = /[\uAC00-\uD7AF\u1100-\u11FF\u3130-\u318F]/g;
const TASHKEEL_RANGE = /[\u064B-\u065F\u0670]/g;

/**
 * Strip Arabic diacritics (tashkeel) for normalized matching.
 */
export function stripTashkeel(text: string): string {
  return text.replace(TASHKEEL_RANGE, '');
}

/**
 * Count characters matching each Unicode range in the given text.
 */
function countScripts(text: string): {
  arabic: number;
  latin: number;
  cjk: number;
  hangul: number;
  total: number;
} {
  const arabic = (text.match(ARABIC_RANGE) || []).length;
  const latin = (text.match(LATIN_RANGE) || []).length;
  const cjk = (text.match(CJK_RANGE) || []).length;
  const hangul = (text.match(HANGUL_RANGE) || []).length;
  const total = arabic + latin + cjk + hangul;
  return { arabic, latin, cjk, hangul, total };
}

// Simple word-frequency heuristics to distinguish Latin-script languages
const FRENCH_MARKERS = /\b(le|la|les|de|du|des|un|une|est|sont|dans|pour|avec|sur|que|qui|ce|cette|ces|au|aux|nous|vous|ils|elles|ont|pas|par|mais|ou|et|en|à)\b/gi;
const GERMAN_MARKERS = /\b(der|die|das|ein|eine|und|ist|sind|von|mit|auf|für|den|dem|des|nicht|sich|auch|nach|bei|aus|noch|wie|nur|kann|wird|zum|zur|über|haben|sein|werden)\b/gi;
const INDONESIAN_MARKERS = /\b(dan|yang|di|ini|itu|untuk|dengan|dari|ke|pada|tidak|akan|ada|juga|sudah|oleh|atau|saya|mereka|bisa|kami|kita|telah|sedang|lebih)\b/gi;

function countMarkers(text: string, pattern: RegExp): number {
  return (text.match(pattern) || []).length;
}

/**
 * Detect the dominant language of a text paragraph.
 */
export function detectLanguage(text: string): LanguageDetection {
  if (!text || text.trim().length === 0) {
    return { lang: 'unknown', confidence: 0, isAmbiguous: true };
  }

  const counts = countScripts(text);

  if (counts.total === 0) {
    return { lang: 'unknown', confidence: 0, isAmbiguous: true };
  }

  const arabicRatio = counts.arabic / counts.total;
  const latinRatio = counts.latin / counts.total;
  const cjkRatio = counts.cjk / counts.total;
  const hangulRatio = counts.hangul / counts.total;

  // Dominant script detection
  if (arabicRatio > 0.6) {
    return {
      lang: 'ar',
      confidence: Math.min(1, arabicRatio + 0.1),
      isAmbiguous: arabicRatio < 0.7,
    };
  }

  if (hangulRatio > 0.3) {
    return {
      lang: 'ko',
      confidence: Math.min(1, hangulRatio + 0.2),
      isAmbiguous: hangulRatio < 0.5,
    };
  }

  if (cjkRatio > 0.3) {
    return {
      lang: 'zh',
      confidence: Math.min(1, cjkRatio + 0.2),
      isAmbiguous: cjkRatio < 0.5,
    };
  }

  if (latinRatio > 0.6) {
    // Distinguish among Latin-script languages via word frequency
    const frCount = countMarkers(text, FRENCH_MARKERS);
    const deCount = countMarkers(text, GERMAN_MARKERS);
    const idCount = countMarkers(text, INDONESIAN_MARKERS);
    const wordCount = text.split(/\s+/).length;
    const frRatio = wordCount > 0 ? frCount / wordCount : 0;
    const deRatio = wordCount > 0 ? deCount / wordCount : 0;
    const idRatio = wordCount > 0 ? idCount / wordCount : 0;

    if (frRatio > 0.12 && frRatio > deRatio && frRatio > idRatio) {
      return { lang: 'fr', confidence: Math.min(1, 0.7 + frRatio), isAmbiguous: frRatio < 0.15 };
    }
    if (deRatio > 0.12 && deRatio > frRatio && deRatio > idRatio) {
      return { lang: 'de', confidence: Math.min(1, 0.7 + deRatio), isAmbiguous: deRatio < 0.15 };
    }
    if (idRatio > 0.12 && idRatio > frRatio && idRatio > deRatio) {
      return { lang: 'id', confidence: Math.min(1, 0.7 + idRatio), isAmbiguous: idRatio < 0.15 };
    }

    // Default to English for Latin script
    return {
      lang: 'en',
      confidence: Math.min(1, latinRatio + 0.1),
      isAmbiguous: latinRatio < 0.7,
    };
  }

  // Mixed or low-confidence
  const dominant = Math.max(arabicRatio, latinRatio, cjkRatio, hangulRatio);
  let lang = 'unknown';
  if (dominant === arabicRatio) lang = 'ar';
  else if (dominant === hangulRatio) lang = 'ko';
  else if (dominant === cjkRatio) lang = 'zh';
  else lang = 'en';

  return { lang, confidence: dominant, isAmbiguous: true };
}

/**
 * Detect languages for multiple paragraphs, returning per-paragraph results.
 */
export function detectLanguages(paragraphs: string[]): LanguageDetection[] {
  return paragraphs.map(detectLanguage);
}

/**
 * Detect whether a number string uses Arabic-Indic numerals (٠١٢٣٤٥٦٧٨٩).
 */
export function hasArabicIndicNumerals(text: string): boolean {
  return /[\u0660-\u0669]/.test(text);
}

/**
 * Normalize Arabic-Indic numerals to Western Arabic numerals.
 */
export function normalizeNumerals(text: string): string {
  return text.replace(/[\u0660-\u0669]/g, (ch) =>
    String(ch.charCodeAt(0) - 0x0660)
  );
}
