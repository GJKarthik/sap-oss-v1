/**
 * Structured Parser — client-side parsing of CSV, JSON, TMX, and XLSX files
 * into normalized TermPair[] or ParagraphPair[].
 *
 * All parsers return a common ParseResult shape.
 */

import { TermPair, ParagraphPair, PairType } from '../pair-studio.types';

export interface ParseResult {
  termPairs: TermPair[];
  paragraphPairs: ParagraphPair[];
  errors: string[];
}

export interface ParseOptions {
  defaultPairType: PairType;
  defaultSourceLang: string;
  defaultTargetLang: string;
  defaultCategory: string;
}

const DEFAULT_OPTIONS: ParseOptions = {
  defaultPairType: 'translation',
  defaultSourceLang: 'en',
  defaultTargetLang: 'ar',
  defaultCategory: 'general',
};

/**
 * Detect file format and parse accordingly.
 */
export async function parseStructuredFile(
  file: File,
  options: Partial<ParseOptions> = {}
): Promise<ParseResult> {
  const opts = { ...DEFAULT_OPTIONS, ...options };
  const ext = file.name.split('.').pop()?.toLowerCase() || '';

  switch (ext) {
    case 'csv':
      return parseCsv(await file.text(), opts);
    case 'json':
      return parseJson(await file.text(), opts);
    case 'tmx':
      return parseTmx(await file.text(), opts);
    case 'xlsx':
      return parseXlsx(file, opts);
    default:
      return { termPairs: [], paragraphPairs: [], errors: [`Unsupported file type: .${ext}`] };
  }
}

// ---------------------------------------------------------------------------
// CSV Parser
// ---------------------------------------------------------------------------

/**
 * Parse CSV content. Expects headers in first row.
 * Flexible header matching: source_text/source, target_text/target, etc.
 */
export function parseCsv(content: string, options: ParseOptions): ParseResult {
  const errors: string[] = [];
  const termPairs: TermPair[] = [];

  // Handle BOM
  const cleaned = content.replace(/^\uFEFF/, '');
  const lines = splitCsvLines(cleaned);

  if (lines.length < 2) {
    errors.push('CSV file has no data rows');
    return { termPairs, paragraphPairs: [], errors };
  }

  const headers = parseCsvRow(lines[0]).map((h) => h.toLowerCase().trim());
  const colMap = mapColumns(headers);

  if (colMap.source < 0 || colMap.target < 0) {
    errors.push(`Missing required column: ${colMap.source < 0 ? 'source_text' : 'target_text'}`);
    return { termPairs, paragraphPairs: [], errors };
  }

  for (let i = 1; i < lines.length; i++) {
    const cols = parseCsvRow(lines[i]);
    const source = cols[colMap.source]?.trim();
    const target = cols[colMap.target]?.trim();
    if (!source || !target) continue;

    termPairs.push({
      sourceTerm: source,
      targetTerm: target,
      sourceLang: cols[colMap.sourceLang]?.trim() || options.defaultSourceLang,
      targetLang: cols[colMap.targetLang]?.trim() || options.defaultTargetLang,
      pairType: (cols[colMap.pairType]?.trim() as PairType) || options.defaultPairType,
      category: cols[colMap.category]?.trim() || options.defaultCategory,
      confidence: parseFloat(cols[colMap.confidence]) || 1.0,
      existsInGlossary: false,
      status: 'pending',
    });
  }

  return { termPairs, paragraphPairs: [], errors };
}

// ---------------------------------------------------------------------------
// JSON Parser
// ---------------------------------------------------------------------------

export function parseJson(content: string, options: ParseOptions): ParseResult {
  const errors: string[] = [];
  const termPairs: TermPair[] = [];

  try {
    const data = JSON.parse(content);
    const items = Array.isArray(data) ? data : data.entries || data.pairs || data.terms || [];

    if (!Array.isArray(items)) {
      errors.push('JSON must contain an array of term/pair objects');
      return { termPairs, paragraphPairs: [], errors };
    }

    for (const item of items) {
      const source = item.source_text || item.source || item.sourceTerm || '';
      const target = item.target_text || item.target || item.targetTerm || '';
      if (!source || !target) continue;

      termPairs.push({
        sourceTerm: source,
        targetTerm: target,
        sourceLang: item.source_lang || item.sourceLang || options.defaultSourceLang,
        targetLang: item.target_lang || item.targetLang || options.defaultTargetLang,
        pairType: item.pair_type || item.pairType || options.defaultPairType,
        category: item.category || options.defaultCategory,
        confidence: typeof item.confidence === 'number' ? item.confidence : 1.0,
        existsInGlossary: false,
        status: 'pending',
      });
    }
  } catch {
    errors.push('Invalid JSON format');
  }

  return { termPairs, paragraphPairs: [], errors };
}

// ---------------------------------------------------------------------------
// TMX Parser (Translation Memory eXchange)
// ---------------------------------------------------------------------------

export function parseTmx(content: string, options: ParseOptions): ParseResult {
  const errors: string[] = [];
  const termPairs: TermPair[] = [];

  try {
    const parser = new DOMParser();
    const doc = parser.parseFromString(content, 'text/xml');

    const parseError = doc.querySelector('parsererror');
    if (parseError) {
      errors.push('Invalid TMX XML: ' + parseError.textContent?.substring(0, 100));
      return { termPairs, paragraphPairs: [], errors };
    }

    const tus = doc.querySelectorAll('tu');
    if (tus.length === 0) {
      errors.push('Invalid TMX: no <tu> elements found');
      return { termPairs, paragraphPairs: [], errors };
    }

    tus.forEach((tu) => {
      const tuvs = tu.querySelectorAll('tuv');
      if (tuvs.length < 2) return;

      const firstLang = tuvs[0].getAttribute('xml:lang') || tuvs[0].getAttribute('lang') || options.defaultSourceLang;
      const firstText = tuvs[0].querySelector('seg')?.textContent?.trim() || '';
      const secondLang = tuvs[1].getAttribute('xml:lang') || tuvs[1].getAttribute('lang') || options.defaultTargetLang;
      const secondText = tuvs[1].querySelector('seg')?.textContent?.trim() || '';

      if (!firstText || !secondText) return;

      termPairs.push({
        sourceTerm: firstText,
        targetTerm: secondText,
        sourceLang: firstLang,
        targetLang: secondLang,
        pairType: options.defaultPairType,
        category: tu.getAttribute('tuid') || options.defaultCategory,
        confidence: 1.0,
        existsInGlossary: false,
        status: 'pending',
      });
    });
  } catch {
    errors.push('Failed to parse TMX file');
  }

  return { termPairs, paragraphPairs: [], errors };
}

// ---------------------------------------------------------------------------
// XLSX Parser (uses SheetJS)
// ---------------------------------------------------------------------------

export async function parseXlsx(file: File, options: ParseOptions): Promise<ParseResult> {
  const errors: string[] = [];
  const termPairs: TermPair[] = [];

  try {
    const { read, utils } = await import('xlsx');
    const buffer = await file.arrayBuffer();
    const wb = read(buffer, { type: 'array' });
    const firstSheet = wb.SheetNames[0];
    if (!firstSheet) {
      errors.push('XLSX file has no sheets');
      return { termPairs, paragraphPairs: [], errors };
    }

    const rows: Record<string, string>[] = utils.sheet_to_json(wb.Sheets[firstSheet], { defval: '' });

    if (rows.length === 0) {
      errors.push('XLSX sheet is empty');
      return { termPairs, paragraphPairs: [], errors };
    }

    const headers = Object.keys(rows[0]).map((h) => h.toLowerCase().trim());
    const colMap = mapColumns(headers);
    const headerKeys = Object.keys(rows[0]);

    if (colMap.source < 0 || colMap.target < 0) {
      errors.push(`Missing required column: ${colMap.source < 0 ? 'source_text' : 'target_text'}`);
      return { termPairs, paragraphPairs: [], errors };
    }

    for (const row of rows) {
      const source = String(row[headerKeys[colMap.source]] || '').trim();
      const target = String(row[headerKeys[colMap.target]] || '').trim();
      if (!source || !target) continue;

      termPairs.push({
        sourceTerm: source,
        targetTerm: target,
        sourceLang: String(row[headerKeys[colMap.sourceLang]] || '').trim() || options.defaultSourceLang,
        targetLang: String(row[headerKeys[colMap.targetLang]] || '').trim() || options.defaultTargetLang,
        pairType: (String(row[headerKeys[colMap.pairType]] || '').trim() as PairType) || options.defaultPairType,
        category: String(row[headerKeys[colMap.category]] || '').trim() || options.defaultCategory,
        confidence: parseFloat(String(row[headerKeys[colMap.confidence]])) || 1.0,
        existsInGlossary: false,
        status: 'pending',
      });
    }
  } catch {
    errors.push('Failed to parse XLSX file. Ensure the file is a valid Excel document.');
  }

  return { termPairs, paragraphPairs: [], errors };
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

interface ColumnMapping {
  source: number;
  target: number;
  sourceLang: number;
  targetLang: number;
  category: number;
  confidence: number;
  pairType: number;
}

const SOURCE_ALIASES = ['source_text', 'source', 'sourceterm', 'src', 'en', 'english', 'term'];
const TARGET_ALIASES = ['target_text', 'target', 'targetterm', 'tgt', 'ar', 'arabic', 'translation'];
const SOURCE_LANG_ALIASES = ['source_lang', 'sourcelang', 'src_lang', 'slang'];
const TARGET_LANG_ALIASES = ['target_lang', 'targetlang', 'tgt_lang', 'tlang'];
const CATEGORY_ALIASES = ['category', 'cat', 'domain', 'type'];
const CONFIDENCE_ALIASES = ['confidence', 'conf', 'score'];
const PAIR_TYPE_ALIASES = ['pair_type', 'pairtype', 'type'];

function findColumn(headers: string[], aliases: string[]): number {
  for (const alias of aliases) {
    const idx = headers.indexOf(alias);
    if (idx >= 0) return idx;
  }
  return -1;
}

function mapColumns(headers: string[]): ColumnMapping {
  return {
    source: findColumn(headers, SOURCE_ALIASES),
    target: findColumn(headers, TARGET_ALIASES),
    sourceLang: findColumn(headers, SOURCE_LANG_ALIASES),
    targetLang: findColumn(headers, TARGET_LANG_ALIASES),
    category: findColumn(headers, CATEGORY_ALIASES),
    confidence: findColumn(headers, CONFIDENCE_ALIASES),
    pairType: findColumn(headers, PAIR_TYPE_ALIASES),
  };
}

/**
 * Split CSV content into lines, respecting quoted fields with embedded newlines.
 */
function splitCsvLines(content: string): string[] {
  const lines: string[] = [];
  let current = '';
  let inQuotes = false;

  for (let i = 0; i < content.length; i++) {
    const ch = content[i];
    if (ch === '"') {
      inQuotes = !inQuotes;
      current += ch;
    } else if ((ch === '\n' || ch === '\r') && !inQuotes) {
      if (ch === '\r' && content[i + 1] === '\n') i++;
      if (current.trim()) lines.push(current);
      current = '';
    } else {
      current += ch;
    }
  }
  if (current.trim()) lines.push(current);
  return lines;
}

/**
 * Parse a single CSV row into columns, handling quoted fields.
 */
function parseCsvRow(line: string): string[] {
  const cols: string[] = [];
  let current = '';
  let inQuotes = false;

  for (let i = 0; i < line.length; i++) {
    const ch = line[i];
    if (ch === '"') {
      if (inQuotes && line[i + 1] === '"') {
        current += '"';
        i++;
      } else {
        inQuotes = !inQuotes;
      }
    } else if (ch === ',' && !inQuotes) {
      cols.push(current);
      current = '';
    } else {
      current += ch;
    }
  }
  cols.push(current);
  return cols;
}
