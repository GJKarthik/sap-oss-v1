/**
 * Ingestion Service — orchestrates file format detection, pipeline routing,
 * batch state management, and commit to TM/Glossary.
 */

import { Injectable, inject, signal, computed } from '@angular/core';
import { HttpClient } from '@angular/common/http';
import { Observable, of, catchError, map, tap, switchMap, forkJoin } from 'rxjs';

import { TranslationMemoryService, TMEntry } from './translation-memory.service';
import { GlossaryService } from './glossary.service';
import { OcrService, OcrResult } from './ocr.service';
import { ToastService } from './toast.service';
import { I18nService } from './i18n.service';

import {
  TermPair,
  ParagraphPair,
  PairType,
  PairStatus,
  PipelineKind,
  TrustLevel,
  IngestionBatch,
  IngestionFile,
  CommitResult,
  AlignRequest,
  AlignResponse,
} from '../pages/pair-studio/pair-studio.types';

import { parseStructuredFile, ParseOptions } from '../pages/pair-studio/parsers/structured-parser';
import { parseDdl } from '../pages/pair-studio/parsers/ddl-parser';
import { detectLanguage } from '../pages/pair-studio/parsers/language-detector';

let batchCounter = 0;

@Injectable({ providedIn: 'root' })
export class IngestionService {
  private readonly http = inject(HttpClient);
  private readonly tm = inject(TranslationMemoryService);
  private readonly glossary = inject(GlossaryService);
  private readonly ocr = inject(OcrService);
  private readonly toast = inject(ToastService);
  private readonly i18n = inject(I18nService);

  // ---------------------------------------------------------------------------
  // Batch state (signals)
  // ---------------------------------------------------------------------------

  readonly currentBatch = signal<IngestionBatch | null>(null);
  readonly processing = signal(false);
  readonly progress = signal(0);
  readonly progressLabel = signal('');
  readonly lastCommitResult = signal<CommitResult | null>(null);

  readonly approvedTermCount = computed(() => {
    const batch = this.currentBatch();
    return batch ? batch.termPairs.filter((t) => t.status === 'approved').length : 0;
  });

  readonly rejectedTermCount = computed(() => {
    const batch = this.currentBatch();
    return batch ? batch.termPairs.filter((t) => t.status === 'rejected').length : 0;
  });

  readonly approvedParagraphCount = computed(() => {
    const batch = this.currentBatch();
    return batch ? batch.paragraphPairs.filter((p) => p.status === 'approved').length : 0;
  });

  readonly rejectedParagraphCount = computed(() => {
    const batch = this.currentBatch();
    return batch ? batch.paragraphPairs.filter((p) => p.status === 'rejected').length : 0;
  });

  readonly pendingCount = computed(() => {
    const batch = this.currentBatch();
    if (!batch) return 0;
    return (
      batch.termPairs.filter((t) => t.status === 'pending').length +
      batch.paragraphPairs.filter((p) => p.status === 'pending').length
    );
  });

  // ---------------------------------------------------------------------------
  // Format detection
  // ---------------------------------------------------------------------------

  detectPipeline(files: File[]): PipelineKind {
    if (files.length === 0) return 'structured';

    const extensions = files.map((f) => f.name.split('.').pop()?.toLowerCase() || '');
    const hasDdl = extensions.some((e) => ['sql', 'hdbtable', 'hdbdd'].includes(e));
    const hasPdf = extensions.some((e) => e === 'pdf');
    const pdfCount = extensions.filter((e) => e === 'pdf').length;

    if (hasDdl) return 'schema_import';
    if (pdfCount >= 2) return 'dual_document';
    if (hasPdf) return 'single_bilingual_pdf';
    return 'structured';
  }

  detectPairType(files: File[]): PairType {
    const extensions = files.map((f) => f.name.split('.').pop()?.toLowerCase() || '');
    if (extensions.some((e) => ['sql', 'hdbtable', 'hdbdd'].includes(e))) {
      return 'db_field_mapping';
    }
    return 'translation';
  }

  // ---------------------------------------------------------------------------
  // Process files
  // ---------------------------------------------------------------------------

  async processFiles(
    files: File[],
    pairType: PairType,
    sourceLang: string,
    targetLang: string,
    trustLevel: TrustLevel,
  ): Promise<void> {
    const pipeline = this.detectPipeline(files);
    const batchId = `batch-${++batchCounter}-${Date.now()}`;

    const batch: IngestionBatch = {
      id: batchId,
      files: files.map((f) => ({
        file: f,
        name: f.name,
        type: f.type,
        size: f.size,
      })),
      pairType,
      sourceLang,
      targetLang,
      trustLevel,
      pipeline,
      termPairs: [],
      paragraphPairs: [],
      processing: true,
    };

    this.currentBatch.set(batch);
    this.processing.set(true);
    this.progress.set(0);

    try {
      switch (pipeline) {
        case 'schema_import':
          await this.processSchemaFiles(batch, files);
          break;
        case 'structured':
          await this.processStructuredFiles(batch, files, pairType, sourceLang, targetLang);
          break;
        case 'single_bilingual_pdf':
        case 'dual_document':
          await this.processPdfFiles(batch, files, pipeline, sourceLang, targetLang);
          break;
      }

      // Confidence-based auto-approve: items with confidence >= 0.9 are approved automatically
      const AUTO_APPROVE_THRESHOLD = 0.9;
      batch.termPairs.forEach((t) => {
        if (t.status === 'pending' && t.confidence >= AUTO_APPROVE_THRESHOLD) {
          t.status = 'approved';
        }
      });
      batch.paragraphPairs.forEach((p) => {
        if (p.status === 'pending' && p.confidence >= AUTO_APPROVE_THRESHOLD) {
          p.status = 'approved';
        }
      });

      // Explicit full auto-approve if trust level is set (overrides any remaining pending)
      if (trustLevel === 'auto_approve') {
        batch.termPairs.forEach((t) => {
          if (t.status === 'pending') t.status = 'approved';
        });
        batch.paragraphPairs.forEach((p) => {
          if (p.status === 'pending') p.status = 'approved';
        });
      }

      // Mark existing glossary entries
      this.markExistingGlossaryEntries(batch);

      batch.processing = false;
      this.currentBatch.set({ ...batch });
    } catch (err: unknown) {
      batch.processing = false;
      batch.error = err instanceof Error ? err.message : 'Processing failed';
      this.currentBatch.set({ ...batch });
      this.toast.error(batch.error);
    } finally {
      this.processing.set(false);
      this.progress.set(100);
    }
  }

  // ---------------------------------------------------------------------------
  // Pipeline implementations
  // ---------------------------------------------------------------------------

  private async processSchemaFiles(batch: IngestionBatch, files: File[]): Promise<void> {
    for (let i = 0; i < files.length; i++) {
      this.progress.set(Math.round(((i + 1) / files.length) * 100));
      this.progressLabel.set(`Parsing ${files[i].name}...`);

      const content = await files[i].text();
      const result = parseDdl(content, files[i].name);

      if (result.errors.length > 0) {
        this.toast.error(result.errors.join('; '));
      }

      batch.termPairs.push(...result.termPairs);
    }
  }

  private async processStructuredFiles(
    batch: IngestionBatch,
    files: File[],
    pairType: PairType,
    sourceLang: string,
    targetLang: string,
  ): Promise<void> {
    const options: Partial<ParseOptions> = {
      defaultPairType: pairType,
      defaultSourceLang: sourceLang === 'auto' ? 'en' : sourceLang,
      defaultTargetLang: targetLang === 'auto' ? 'ar' : targetLang,
    };

    for (let i = 0; i < files.length; i++) {
      this.progress.set(Math.round(((i + 1) / files.length) * 100));
      this.progressLabel.set(`Parsing ${files[i].name}...`);

      const result = await parseStructuredFile(files[i], options);

      if (result.errors.length > 0) {
        this.toast.error(result.errors.join('; '));
      }

      batch.termPairs.push(...result.termPairs);
      batch.paragraphPairs.push(...result.paragraphPairs);
    }
  }

  private async processPdfFiles(
    batch: IngestionBatch,
    files: File[],
    pipeline: PipelineKind,
    sourceLang: string,
    targetLang: string,
  ): Promise<void> {
    const pdfFiles = files.filter((f) => f.name.toLowerCase().endsWith('.pdf'));

    if (pipeline === 'dual_document' && pdfFiles.length >= 2) {
      // Process both PDFs via OCR then align
      this.progressLabel.set(`OCR: ${pdfFiles[0].name}...`);
      this.progress.set(10);

      try {
        const [sourceOcr, targetOcr] = await Promise.all([
          this.ocrFile(pdfFiles[0]),
          this.ocrFile(pdfFiles[1]),
        ]);

        this.progressLabel.set('Aligning documents...');
        this.progress.set(60);

        const sLang = sourceLang === 'auto' ? this.detectDocLanguage(sourceOcr) : sourceLang;
        const tLang = targetLang === 'auto' ? this.detectDocLanguage(targetOcr) : targetLang;

        const alignResult = await this.alignDocuments(sourceOcr, targetOcr, sLang, tLang);
        this.applyAlignResult(batch, alignResult, sLang, tLang);
      } catch {
        batch.error = this.i18n.t('pairStudio.error.pdfAlignFailed');
        this.toast.error(batch.error);
      }
    } else if (pdfFiles.length === 1) {
      // Single bilingual PDF
      this.progressLabel.set(`OCR: ${pdfFiles[0].name}...`);
      this.progress.set(20);

      try {
        const ocrResult = await this.ocrFile(pdfFiles[0]);
        const lang = sourceLang === 'auto' ? this.detectDocLanguage(ocrResult) : sourceLang;

        // For single bilingual PDFs, we split paragraphs and detect language per-paragraph
        for (const page of ocrResult.pages) {
          const paragraphs = page.text.split(/\n\s*\n/).filter((p) => p.trim().length > 10);
          for (const para of paragraphs) {
            const detection = detectLanguage(para);
            batch.paragraphPairs.push({
              sourceText: para,
              targetText: '',
              sourceLang: detection.lang,
              targetLang: detection.lang === 'ar' ? 'en' : 'ar',
              confidence: detection.confidence,
              page: page.page_number,
              status: 'pending',
            });
          }
        }
      } catch {
        batch.error = this.i18n.t('pairStudio.error.ocrFailed');
        this.toast.error(batch.error);
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  private ocrFile(file: File): Promise<OcrResult> {
    return new Promise((resolve, reject) => {
      this.ocr.extractFinancialFieldsAll(file).subscribe({
        next: resolve,
        error: reject,
      });
    });
  }

  private alignDocuments(
    source: OcrResult,
    target: OcrResult,
    sourceLang: string,
    targetLang: string,
  ): Promise<AlignResponse> {
    const glossaryEntries = this.glossary.entries().map((e) => ({
      ar: e.ar,
      en: e.en,
      category: e.category,
    }));

    const body: AlignRequest = {
      source: {
        pages: source.pages.map((p) => ({
          page_number: p.page_number,
          text: p.text,
          text_regions: p.text_regions.map((r) => ({
            text: r.text,
            confidence: r.confidence,
            language: r.language,
          })),
        })),
        lang: sourceLang,
      },
      target: {
        pages: target.pages.map((p) => ({
          page_number: p.page_number,
          text: p.text,
          text_regions: p.text_regions.map((r) => ({
            text: r.text,
            confidence: r.confidence,
            language: r.language,
          })),
        })),
        lang: targetLang,
      },
      options: {
        granularity: 'paragraph',
        extractTerms: true,
        existingGlossary: glossaryEntries,
      },
    };

    return new Promise((resolve, reject) => {
      this.http
        .post<AlignResponse>('/api/rag/tm/align', body)
        .subscribe({ next: resolve, error: reject });
    });
  }

  private applyAlignResult(
    batch: IngestionBatch,
    result: AlignResponse,
    sourceLang: string,
    targetLang: string,
  ): void {
    for (const pp of result.paragraphPairs) {
      batch.paragraphPairs.push({
        sourceText: pp.sourceText,
        targetText: pp.targetText,
        sourceLang,
        targetLang,
        confidence: pp.confidence,
        page: pp.sourcePage,
        status: 'pending',
      });
    }

    for (const tp of result.termPairs) {
      batch.termPairs.push({
        sourceTerm: tp.sourceTerm,
        targetTerm: tp.targetTerm,
        sourceLang: tp.sourceLang,
        targetLang: tp.targetLang,
        pairType: 'translation',
        category: tp.category,
        confidence: tp.confidence,
        existsInGlossary: false,
        status: 'pending',
      });
    }
  }

  private detectDocLanguage(ocr: OcrResult): string {
    const sampleText = ocr.pages
      .slice(0, 3)
      .map((p) => p.text)
      .join(' ');
    return detectLanguage(sampleText).lang;
  }

  private markExistingGlossaryEntries(batch: IngestionBatch): void {
    const glossaryTerms = new Set<string>();
    this.glossary.entries().forEach((e) => {
      glossaryTerms.add(e.ar.toLowerCase());
      glossaryTerms.add(e.en.toLowerCase());
    });

    batch.termPairs.forEach((tp) => {
      if (
        glossaryTerms.has(tp.sourceTerm.toLowerCase()) ||
        glossaryTerms.has(tp.targetTerm.toLowerCase())
      ) {
        tp.existsInGlossary = true;
      }
    });
  }

  // ---------------------------------------------------------------------------
  // Batch actions
  // ---------------------------------------------------------------------------

  updateTermStatus(index: number, status: PairStatus): void {
    const batch = this.currentBatch();
    if (!batch) return;
    const updated = { ...batch, termPairs: [...batch.termPairs] };
    updated.termPairs[index] = { ...updated.termPairs[index], status };
    this.currentBatch.set(updated);
  }

  updateParagraphStatus(index: number, status: PairStatus): void {
    const batch = this.currentBatch();
    if (!batch) return;
    const updated = { ...batch, paragraphPairs: [...batch.paragraphPairs] };
    updated.paragraphPairs[index] = { ...updated.paragraphPairs[index], status };
    this.currentBatch.set(updated);
  }

  approveAllPending(): void {
    const batch = this.currentBatch();
    if (!batch) return;
    const updated = {
      ...batch,
      termPairs: batch.termPairs.map((t) => (t.status === 'pending' ? { ...t, status: 'approved' as PairStatus } : t)),
      paragraphPairs: batch.paragraphPairs.map((p) => (p.status === 'pending' ? { ...p, status: 'approved' as PairStatus } : p)),
    };
    this.currentBatch.set(updated);
  }

  approveSelected(indices: number[], type: 'term' | 'paragraph'): void {
    const batch = this.currentBatch();
    if (!batch) return;
    const updated = { ...batch };
    if (type === 'term') {
      updated.termPairs = batch.termPairs.map((t, i) =>
        indices.includes(i) ? { ...t, status: 'approved' as PairStatus } : t,
      );
    } else {
      updated.paragraphPairs = batch.paragraphPairs.map((p, i) =>
        indices.includes(i) ? { ...p, status: 'approved' as PairStatus } : p,
      );
    }
    this.currentBatch.set(updated);
  }

  rejectSelected(indices: number[], type: 'term' | 'paragraph'): void {
    const batch = this.currentBatch();
    if (!batch) return;
    const updated = { ...batch };
    if (type === 'term') {
      updated.termPairs = batch.termPairs.map((t, i) =>
        indices.includes(i) ? { ...t, status: 'rejected' as PairStatus } : t,
      );
    } else {
      updated.paragraphPairs = batch.paragraphPairs.map((p, i) =>
        indices.includes(i) ? { ...p, status: 'rejected' as PairStatus } : p,
      );
    }
    this.currentBatch.set(updated);
  }

  updateTermPair(index: number, updates: Partial<TermPair>): void {
    const batch = this.currentBatch();
    if (!batch) return;
    const updated = { ...batch, termPairs: [...batch.termPairs] };
    updated.termPairs[index] = { ...updated.termPairs[index], ...updates };
    this.currentBatch.set(updated);
  }

  // ---------------------------------------------------------------------------
  // Commit
  // ---------------------------------------------------------------------------

  commit(options: {
    toTm: boolean;
    toGlossary: boolean;
    toVectorStore: boolean;
  }): Observable<CommitResult> {
    const batch = this.currentBatch();
    if (!batch) {
      return of({
        termsSaved: 0,
        termsFailed: 0,
        paragraphsSaved: 0,
        paragraphsFailed: 0,
        newGlossaryEntries: 0,
        updatedEntries: 0,
        failedIds: [],
      });
    }

    const approvedTerms = batch.termPairs.filter((t) => t.status === 'approved');
    const approvedParas = batch.paragraphPairs.filter((p) => p.status === 'approved');

    const tmEntries: TMEntry[] = approvedTerms.map((t) => ({
      source_text: t.sourceTerm,
      target_text: t.targetTerm,
      source_lang: t.sourceLang,
      target_lang: t.targetLang,
      category: t.category,
      is_approved: true,
      pair_type: t.pairType,
      db_context: t.dbContext
        ? {
            table_name: t.dbContext.tableName,
            column_name: t.dbContext.columnName,
            data_type: t.dbContext.dataType,
          }
        : undefined,
    }));

    // Add paragraph pairs as TM entries too
    const paraTmEntries: TMEntry[] = approvedParas.map((p) => ({
      source_text: p.sourceText,
      target_text: p.targetText,
      source_lang: p.sourceLang,
      target_lang: p.targetLang,
      category: 'paragraph',
      is_approved: true,
      pair_type: 'translation' as const,
    }));

    // Always save to TM — backend auto-vectorizes approved entries into HANA
    const allEntries = [...tmEntries, ...paraTmEntries];

    return this.tm.saveBatch(allEntries).pipe(
      tap((result) => {
        const commitResult: CommitResult = {
          termsSaved: Math.min(result.saved, approvedTerms.length),
          termsFailed: result.failed,
          paragraphsSaved: Math.max(0, result.saved - approvedTerms.length),
          paragraphsFailed: 0,
          newGlossaryEntries: approvedTerms.filter((t) => !t.existsInGlossary).length,
          updatedEntries: approvedTerms.filter((t) => t.existsInGlossary).length,
          failedIds: result.failedIds,
        };
        this.lastCommitResult.set(commitResult);

        // Always refresh glossary — vectorization is handled server-side
        this.glossary.loadOverrides();
      }),
      map((result) => ({
        termsSaved: Math.min(result.saved, approvedTerms.length),
        termsFailed: result.failed,
        paragraphsSaved: Math.max(0, result.saved - approvedTerms.length),
        paragraphsFailed: 0,
        newGlossaryEntries: approvedTerms.filter((t) => !t.existsInGlossary).length,
        updatedEntries: approvedTerms.filter((t) => t.existsInGlossary).length,
        failedIds: result.failedIds,
      })),
    );
  }

  discardBatch(): void {
    this.currentBatch.set(null);
    this.lastCommitResult.set(null);
    this.progress.set(0);
    this.progressLabel.set('');
  }
}
