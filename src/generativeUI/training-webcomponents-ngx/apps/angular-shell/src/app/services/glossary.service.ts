import { Injectable, signal, computed, inject } from '@angular/core';
import { TranslationMemoryService, TMEntry } from './translation-memory.service';

export interface GlossaryEntry {
  ar: string;
  en: string;
  category: 'income_statement' | 'balance_sheet' | 'regulatory' | 'general';
  ifrs_context?: string;
  definition_ar?: string;
  definition_en?: string;
}

@Injectable({
  providedIn: 'root'
})
export class GlossaryService {
  private readonly tm = inject(TranslationMemoryService);
  private readonly _overrides = signal<TMEntry[]>([]);

  private readonly _entries = signal<GlossaryEntry[]>([
    // --- Income Statement (IFRS 9 / IAS 1) ---
    { ar: 'دخل العمولات الخاصة', en: 'Special Commission Income', category: 'income_statement', ifrs_context: 'Effective Interest Rate' },
    { ar: 'مصاريف العمولات الخاصة', en: 'Special Commission Expense', category: 'income_statement' },
    { ar: 'صافي دخل العمولات الخاصة', en: 'Net Special Commission Income', category: 'income_statement' },
    { ar: 'أتعاب وعمولات بنكية', en: 'Fees and Commission Income', category: 'income_statement' },
    { ar: 'دخل متاجرة', en: 'Trading Income', category: 'income_statement' },
    { ar: 'مكاسب استثمارات', en: 'Investment Gains', category: 'income_statement' },
    { ar: 'مصاريف عمومية وإدارية', en: 'General and Administrative Expenses', category: 'income_statement' },
    { ar: 'مخصصات خسائر الائتمان', en: 'Provision for Credit Losses', category: 'income_statement', ifrs_context: 'ECL Model' },
    { ar: 'صافي دخل العمليات', en: 'Net Operating Income', category: 'income_statement' },
    { ar: 'دخل شامل آخر', en: 'Other Comprehensive Income (OCI)', category: 'income_statement' },

    // --- Balance Sheet (IFRS 7 / IFRS 9 / IFRS 16) ---
    { ar: 'النقد وما في حكمه', en: 'Cash and Cash Equivalents', category: 'balance_sheet', ifrs_context: 'IAS 7' },
    { ar: 'ودائع لدى مؤسسة النقد', en: 'Statutory Deposits with Central Bank', category: 'balance_sheet' },
    { ar: 'قروض وسلف للعملاء بالصافي', en: 'Loans and Advances to Customers, Net', category: 'balance_sheet', ifrs_context: 'Amortised Cost' },
    { ar: 'استثمارات بالقيمة العادلة', en: 'Investments at Fair Value', category: 'balance_sheet', ifrs_context: 'FVTPL/FVOCI' },
    { ar: 'عقارات ومعدات', en: 'Property and Equipment', category: 'balance_sheet', ifrs_context: 'IAS 16' },
    { ar: 'أصول ضريبية مؤجلة', en: 'Deferred Tax Assets', category: 'balance_sheet', ifrs_context: 'IAS 12' },
    { ar: 'ودائع العملاء', en: 'Customer Deposits', category: 'balance_sheet' },
    { ar: 'قروض طويلة الأجل', en: 'Term Loans', category: 'balance_sheet' },
    { ar: 'الالتزامات العرضية والارتباطات', en: 'Commitments and Contingencies', category: 'balance_sheet', ifrs_context: 'Off-Balance Sheet' },

    // --- Equity (IAS 1) ---
    { ar: 'رأس المال المدفوع', en: 'Paid-up Capital', category: 'regulatory' },
    { ar: 'الاحتياطي النظامي', en: 'Statutory Reserve', category: 'regulatory' },
    { ar: 'الأرباح المبقاة', en: 'Retained Earnings', category: 'balance_sheet' },
    { ar: 'أسهم الخزينة', en: 'Treasury Shares', category: 'balance_sheet' },

    // --- Technical Metrics ---
    { ar: 'معدل كفاية رأس المال', en: 'Capital Adequacy Ratio (CAR)', category: 'regulatory', ifrs_context: 'Basel III' },
    { ar: 'نسبة القروض إلى الودائع', en: 'Loan to Deposit Ratio (LDR)', category: 'regulatory' }
  ]);

  readonly entries = this._entries.asReadonly();

  constructor() {
    this.loadOverrides();
  }

  loadOverrides(): void {
    this.tm.list().subscribe({
      next: entries => this._overrides.set(entries.filter(e => e.is_approved)),
      error: () => console.warn('Failed to load TM overrides')
    });
  }

  /** Map for fast O(1) lookup in both directions. */
  readonly arToEnMap = computed(() => {
    const map = new Map<string, string>();
    this._entries().forEach(e => map.set(e.ar, e.en));
    return map;
  });

  readonly enToArMap = computed(() => {
    const map = new Map<string, string>();
    this._entries().forEach(e => map.set(e.en, e.ar));
    return map;
  });

  /** Search across entries. */
  search(query: string): GlossaryEntry[] {
    const q = query.toLowerCase();
    return this._entries().filter(e => 
      e.ar.includes(q) || e.en.toLowerCase().includes(q)
    );
  }

  /** Find entry for a specific term. */
  getEntry(term: string): GlossaryEntry | undefined {
    return this._entries().find(e => e.ar === term || e.en === term);
  }

  /** 
   * Cross-checks text for non-standard technical terms.
   * Useful for auditing LLM translations.
   */
  crossCheck(text: string, targetLang: 'ar' | 'en'): string[] {
    const findings: string[] = [];
    const sourceMap = targetLang === 'ar' ? this.enToArMap() : this.arToEnMap();
    
    sourceMap.forEach((target, source) => {
      // If the source term is found but the corresponding target term is NOT in the text
      // (Simplified logic: in a real system we'd use NLP to verify mapping alignment)
      if (text.toLowerCase().includes(source.toLowerCase()) && !text.includes(target)) {
        findings.push(`Potential non-standard term for "${source}". Expected "${target}".`);
      }
    });
    
    return findings;
  }

  /**
   * Generates a string of strict linguistic constraints for LLM system prompts.
   */
  getSystemPromptSnippet(): string {
    let snippet = '\n[STRICT LINGUISTIC CONSTRAINTS - IFRS/CPA BANKING STANDARDS]\n';
    snippet += 'You MUST use the following official translations for all technical banking terms:\n';
    
    this._entries().forEach(e => {
      snippet += `- ${e.en} <-> ${e.ar} (${e.category})\n`;
    });

    const overrides = this._overrides();
    if (overrides.length > 0) {
      snippet += '\n[CORRECTION OVERRIDES - MUST FOLLOW THESE INSTEAD OF GENERAL KNOWLEDGE]\n';
      overrides.forEach(o => {
        snippet += `- ${o.source_text} -> ${o.target_text} (${o.source_lang} to ${o.target_lang})\n`;
      });
    }
    
    snippet += '\nAvoid generic translations. For example, use "Commission" (عمولة) instead of "Interest" (فائدة) where specified by regional banking standards.\n';
    return snippet;
  }
}
