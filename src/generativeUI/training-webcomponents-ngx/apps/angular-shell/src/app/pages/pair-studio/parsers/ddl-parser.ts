/**
 * DDL Parser — extracts column definitions from SQL/HANA DDL files
 * and converts them to TermPair[] with pairType='db_field_mapping'.
 *
 * Supported formats:
 *  - Standard SQL: CREATE TABLE ... ( col TYPE, ... )
 *  - HANA Column Store: CREATE COLUMN TABLE ...
 *  - .hdbtable JSON format: { "columns": [...] }
 *  - .hdbdd CDS-like definitions
 */

import { TermPair, DbContext } from '../pair-studio.types';
import { expandColumnName } from './abbreviation-expander';

export interface DdlColumn {
  tableName: string;
  columnName: string;
  dataType: string;
}

export interface DdlParseResult {
  columns: DdlColumn[];
  termPairs: TermPair[];
  errors: string[];
}

/**
 * Parse DDL content (auto-detects format) and return term pairs.
 */
export function parseDdl(content: string, fileName: string): DdlParseResult {
  const trimmed = content.trim();
  const errors: string[] = [];

  // Detect format
  if (fileName.endsWith('.hdbtable') || (trimmed.startsWith('{') && trimmed.includes('"columns"'))) {
    return parseHdbTable(trimmed, fileName, errors);
  }

  if (/CREATE\s+(COLUMN\s+)?TABLE/i.test(trimmed)) {
    return parseSqlDdl(trimmed, errors);
  }

  if (fileName.endsWith('.hdbdd') || /^(namespace|context|entity)\s/m.test(trimmed)) {
    return parseHdbdd(trimmed, errors);
  }

  // Fallback: try SQL anyway
  if (trimmed.toUpperCase().includes('CREATE')) {
    return parseSqlDdl(trimmed, errors);
  }

  errors.push(`Unrecognized DDL format in ${fileName}`);
  return { columns: [], termPairs: [], errors };
}

/**
 * Parse standard SQL CREATE TABLE statements.
 * Handles: CREATE TABLE, CREATE COLUMN TABLE (HANA), with optional schema prefix.
 */
function parseSqlDdl(content: string, errors: string[]): DdlParseResult {
  const columns: DdlColumn[] = [];

  // Match CREATE TABLE header to find table name, then extract body with balanced parens
  const headerRegex = /CREATE\s+(?:COLUMN\s+)?TABLE\s+(?:"?[\w./]+"?\s*\.\s*)?(?:"?([\w./]+)"?)\s*\(/gi;
  let headerMatch: RegExpExecArray | null;

  while ((headerMatch = headerRegex.exec(content)) !== null) {
    const tableName = headerMatch[1];
    const bodyStart = headerMatch.index + headerMatch[0].length;
    const body = extractBalancedBody(content, bodyStart);
    if (!body) continue;

    const colLines = splitColumnDefinitions(body);

    for (const line of colLines) {
      const parsed = parseColumnLine(line, tableName);
      if (parsed) {
        columns.push(parsed);
      }
    }
  }

  if (columns.length === 0) {
    errors.push('No columns extracted from SQL DDL. The syntax may be non-standard.');
  }

  return {
    columns,
    termPairs: columnsToTermPairs(columns),
    errors,
  };
}

/**
 * Parse .hdbtable JSON format.
 * Expected: { "schemaName": "...", "tableType": "...", "columns": [ { "name": "...", "sqlType": "..." }, ... ] }
 */
function parseHdbTable(content: string, fileName: string, errors: string[]): DdlParseResult {
  const columns: DdlColumn[] = [];

  try {
    const parsed = JSON.parse(content);
    const tableName = parsed.tableType?.replace(/\./g, '_') || fileName.replace('.hdbtable', '');
    const cols = parsed.columns || [];

    for (const col of cols) {
      if (col.name) {
        columns.push({
          tableName,
          columnName: col.name,
          dataType: col.sqlType || col.type || 'UNKNOWN',
        });
      }
    }
  } catch {
    errors.push(`Failed to parse JSON in ${fileName}`);
  }

  return {
    columns,
    termPairs: columnsToTermPairs(columns),
    errors,
  };
}

/**
 * Parse .hdbdd CDS-like entity definitions.
 * Simple regex-based extraction of entity → element pairs.
 */
function parseHdbdd(content: string, errors: string[]): DdlParseResult {
  const columns: DdlColumn[] = [];

  const entityRegex = /entity\s+"?([\w.]+)"?\s*\{([\s\S]*?)\}/gi;
  let entityMatch: RegExpExecArray | null;

  while ((entityMatch = entityRegex.exec(content)) !== null) {
    const entityName = entityMatch[1];
    const body = entityMatch[2];
    // Match: key? elementName : Type;
    const elemRegex = /(?:key\s+)?(\w+)\s*:\s*([\w.()]+(?:\([\d,]+\))?)\s*;/gi;
    let elemMatch: RegExpExecArray | null;

    while ((elemMatch = elemRegex.exec(body)) !== null) {
      columns.push({
        tableName: entityName,
        columnName: elemMatch[1],
        dataType: elemMatch[2],
      });
    }
  }

  if (columns.length === 0) {
    errors.push('No elements extracted from .hdbdd file.');
  }

  return {
    columns,
    termPairs: columnsToTermPairs(columns),
    errors,
  };
}

/**
 * Extract content between balanced parentheses starting at the given offset.
 * The offset should point to the first character AFTER the opening '('.
 */
function extractBalancedBody(content: string, startOffset: number): string | null {
  let depth = 1;
  let i = startOffset;
  while (i < content.length && depth > 0) {
    if (content[i] === '(') depth++;
    else if (content[i] === ')') depth--;
    if (depth > 0) i++;
  }
  if (depth !== 0) return null;
  return content.substring(startOffset, i);
}

/**
 * Split the body of a CREATE TABLE into individual column definition lines,
 * handling constraints (PRIMARY KEY, FOREIGN KEY, UNIQUE, CHECK, CONSTRAINT).
 */
function splitColumnDefinitions(body: string): string[] {
  const lines: string[] = [];
  let depth = 0;
  let current = '';

  for (const char of body) {
    if (char === '(') depth++;
    else if (char === ')') depth--;

    if (char === ',' && depth === 0) {
      lines.push(current.trim());
      current = '';
    } else {
      current += char;
    }
  }
  if (current.trim()) {
    lines.push(current.trim());
  }

  // Filter out constraint lines
  const constraintPattern = /^\s*(PRIMARY\s+KEY|FOREIGN\s+KEY|UNIQUE|CHECK|CONSTRAINT)\b/i;
  return lines.filter((line) => !constraintPattern.test(line));
}

/**
 * Parse a single column definition line.
 * Handles: "COL_NAME" TYPE(size), COL_NAME TYPE, with optional NOT NULL, DEFAULT, etc.
 */
function parseColumnLine(line: string, tableName: string): DdlColumn | null {
  // Remove inline comments
  const clean = line.replace(/--.*$/, '').trim();
  if (!clean) return null;

  // Match: optional quotes, column name, then type
  const match = clean.match(/^"?([\w]+)"?\s+([\w]+(?:\s*\([\d\s,]+\))?)/);
  if (!match) return null;

  return {
    tableName,
    columnName: match[1],
    dataType: match[2].replace(/\s+/g, ''),
  };
}

/**
 * Convert parsed columns to TermPair[] using abbreviation expansion.
 */
function columnsToTermPairs(columns: DdlColumn[]): TermPair[] {
  return columns.map((col) => {
    const expansion = expandColumnName(col.columnName);
    const dbContext: DbContext = {
      tableName: col.tableName,
      columnName: col.columnName,
      dataType: col.dataType,
    };

    return {
      sourceTerm: col.columnName,
      targetTerm: expansion.naturalName,
      sourceLang: 'en',
      targetLang: 'en',
      pairType: 'db_field_mapping' as const,
      category: 'schema',
      confidence: expansion.confidence,
      dbContext,
      existsInGlossary: false,
      status: expansion.confidence >= 0.9 ? 'approved' as const : 'pending' as const,
    };
  });
}
