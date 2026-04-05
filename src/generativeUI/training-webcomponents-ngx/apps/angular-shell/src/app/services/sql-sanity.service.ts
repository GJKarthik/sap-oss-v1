import { Injectable } from '@angular/core';

export interface SqlSanityResult {
  isValid: boolean;
  score: number; // 0 to 1
  warnings: string[];
  isRisky: boolean;
}

@Injectable({
  providedIn: 'root'
})
export class SqlSanityService {
  private readonly restrictedKeywords = ['DROP', 'DELETE', 'TRUNCATE', 'GRANT', 'REVOKE', 'UPDATE', 'INSERT'];
  private readonly mandatoryKeywords = ['SELECT', 'FROM'];

  check(sql: string): SqlSanityResult {
    const upperSql = sql.toUpperCase();
    const warnings: string[] = [];
    let score = 1.0;

    // 1. Basic Balance Check
    const openParens = (sql.match(/\(/g) || []).length;
    const closeParens = (sql.match(/\)/g) || []).length;
    if (openParens !== closeParens) {
      warnings.push('Unbalanced parentheses detected');
      score -= 0.4;
    }

    // 2. Mandatory Keywords
    for (const kw of this.mandatoryKeywords) {
      if (!upperSql.includes(kw)) {
        warnings.push(`Missing mandatory keyword: ${kw}`);
        score -= 0.3;
      }
    }

    // 3. Restricted/Risky Keywords
    let isRisky = false;
    for (const kw of this.restrictedKeywords) {
      if (new RegExp(`\\b${kw}\\b`).test(upperSql)) {
        warnings.push(`Risky data-modifying keyword detected: ${kw}`);
        isRisky = true;
        score -= 0.5;
      }
    }

    // 4. Quotation Balance
    const singleQuotes = (sql.match(/'/g) || []).length;
    if (singleQuotes % 2 !== 0) {
      warnings.push('Unbalanced single quotes');
      score -= 0.3;
    }

    return {
      isValid: score > 0.5,
      score: Math.max(0, score),
      warnings,
      isRisky
    };
  }

  /** Extract SQL blocks from markdown-like text. */
  extractSqlBlocks(text: string): string[] {
    const regex = /```sql([\s\S]*?)```/g;
    const matches: string[] = [];
    let match;
    while ((match = regex.exec(text)) !== null) {
      matches.push(match[1].trim());
    }
    
    // If no markdown blocks, check if the whole text looks like a SQL query
    if (matches.length === 0 && (text.toUpperCase().includes('SELECT') && text.toUpperCase().includes('FROM'))) {
      matches.push(text.trim());
    }
    
    return matches;
  }
}
