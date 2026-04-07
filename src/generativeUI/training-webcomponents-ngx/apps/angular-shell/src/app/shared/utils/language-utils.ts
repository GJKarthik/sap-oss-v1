/**
 * Language detection and normalization utilities.
 */

export type Language = 'en' | 'ar' | 'fr';

const ARABIC_RANGE = /[\u0600-\u06FF\u0750-\u077F\uFB50-\uFDFF\uFE70-\uFEFF]/;
const FRENCH_MARKERS = /\b(le|la|les|un|une|des|du|au|aux|est|sont|dans|pour|avec|que|qui|ce|cette|ces|nous|vous|ils|elles)\b/i;

/**
 * Detect the primary language of a text string.
 * Returns the detected language code, falling back to the provided default.
 */
export function detectTextLanguage(text: string, defaultLang: string = 'en'): Language {
  if (!text || text.trim().length === 0) return (defaultLang as Language) || 'en';

  // Count Arabic characters
  const arabicChars = (text.match(new RegExp(ARABIC_RANGE.source, 'g')) || []).length;
  const totalChars = text.replace(/\s/g, '').length;

  if (totalChars > 0 && arabicChars / totalChars > 0.3) {
    return 'ar';
  }

  // Check for French markers
  const frenchMatches = (text.match(FRENCH_MARKERS) || []).length;
  const wordCount = text.split(/\s+/).length;
  if (wordCount > 3 && frenchMatches / wordCount > 0.15) {
    return 'fr';
  }

  return (defaultLang as Language) || 'en';
}

/**
 * Normalize a language code string to a supported Language value.
 * Returns undefined if the code is not recognized.
 */
export function normalizeLanguageCode(code: string | undefined | null): Language | undefined {
  if (!code) return undefined;
  const lower = code.toLowerCase().trim();
  if (lower === 'ar' || lower === 'arabic' || lower.startsWith('ar-')) return 'ar';
  if (lower === 'fr' || lower === 'french' || lower.startsWith('fr-')) return 'fr';
  if (lower === 'en' || lower === 'english' || lower.startsWith('en-')) return 'en';
  return undefined;
}
