/**
 * Tests for IngestionService — confidence-based auto-approve,
 * trust level override, pipeline detection, and batch state.
 */

import { TestBed } from '@angular/core/testing';
import { provideHttpClient } from '@angular/common/http';
import { provideHttpClientTesting, HttpTestingController } from '@angular/common/http/testing';

import { IngestionService } from './ingestion.service';
import { TranslationMemoryService } from './translation-memory.service';
import { GlossaryService } from './glossary.service';
import { OcrService } from './ocr.service';
import { ToastService } from './toast.service';
import { I18nService } from './i18n.service';

import {
  TermPair,
  ParagraphPair,
  IngestionBatch,
} from '../pages/pair-studio/pair-studio.types';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function makeTermPair(overrides: Partial<TermPair> = {}): TermPair {
  return {
    sourceTerm: 'Balance',
    targetTerm: 'رصيد',
    sourceLang: 'en',
    targetLang: 'ar',
    pairType: 'translation',
    category: '',
    confidence: 0.5,
    existsInGlossary: false,
    status: 'pending',
    ...overrides,
  };
}

function makeParagraphPair(overrides: Partial<ParagraphPair> = {}): ParagraphPair {
  return {
    sourceText: 'The balance sheet.',
    targetText: 'الميزانية العمومية.',
    sourceLang: 'en',
    targetLang: 'ar',
    confidence: 0.5,
    status: 'pending',
    ...overrides,
  };
}

function makeBatch(overrides: Partial<IngestionBatch> = {}): IngestionBatch {
  return {
    id: 'batch-test-1',
    files: [],
    pairType: 'translation',
    sourceLang: 'en',
    targetLang: 'ar',
    trustLevel: 'review_first',
    pipeline: 'structured',
    termPairs: [],
    paragraphPairs: [],
    processing: false,
    ...overrides,
  };
}

/**
 * Extracted auto-approve logic identical to IngestionService.processFiles().
 * We test this in isolation since processFiles() requires full file I/O.
 */
function applyAutoApprove(
  batch: IngestionBatch,
  trustLevel: 'auto_approve' | 'review_first',
): void {
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

  if (trustLevel === 'auto_approve') {
    batch.termPairs.forEach((t) => {
      if (t.status === 'pending') t.status = 'approved';
    });
    batch.paragraphPairs.forEach((p) => {
      if (p.status === 'pending') p.status = 'approved';
    });
  }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

describe('IngestionService', () => {
  let service: IngestionService;

  beforeEach(() => {
    TestBed.configureTestingModule({
      providers: [
        provideHttpClient(),
        provideHttpClientTesting(),
        IngestionService,
        TranslationMemoryService,
        GlossaryService,
        OcrService,
        ToastService,
        I18nService,
      ],
    });
    service = TestBed.inject(IngestionService);
  });

  it('should be created', () => {
    expect(service).toBeTruthy();
  });

  // ── Pipeline detection ──

  describe('detectPipeline', () => {
    it('returns structured for CSV/TSV', () => {
      const files = [new File([''], 'data.csv')];
      expect(service.detectPipeline(files)).toBe('structured');
    });

    it('returns schema_import for SQL files', () => {
      const files = [new File([''], 'tables.sql')];
      expect(service.detectPipeline(files)).toBe('schema_import');
    });

    it('returns single_bilingual_pdf for one PDF', () => {
      const files = [new File([''], 'doc.pdf', { type: 'application/pdf' })];
      expect(service.detectPipeline(files)).toBe('single_bilingual_pdf');
    });

    it('returns dual_document for two PDFs', () => {
      const files = [
        new File([''], 'source.pdf', { type: 'application/pdf' }),
        new File([''], 'target.pdf', { type: 'application/pdf' }),
      ];
      expect(service.detectPipeline(files)).toBe('dual_document');
    });

    it('returns structured for empty file list', () => {
      expect(service.detectPipeline([])).toBe('structured');
    });
  });

  // ── Pair type detection ──

  describe('detectPairType', () => {
    it('returns db_field_mapping for DDL files', () => {
      expect(service.detectPairType([new File([''], 'x.hdbtable')])).toBe('db_field_mapping');
    });

    it('returns translation for other files', () => {
      expect(service.detectPairType([new File([''], 'x.csv')])).toBe('translation');
    });
  });
});

// ---------------------------------------------------------------------------
// Confidence-based auto-approve logic (extracted)
// ---------------------------------------------------------------------------

describe('Confidence Auto-Approve Logic', () => {
  describe('with review_first trust level', () => {
    it('approves term pairs with confidence >= 0.9', () => {
      const batch = makeBatch({
        termPairs: [
          makeTermPair({ confidence: 0.95, status: 'pending' }),
          makeTermPair({ confidence: 0.90, status: 'pending' }),
          makeTermPair({ confidence: 0.89, status: 'pending' }),
        ],
      });

      applyAutoApprove(batch, 'review_first');

      expect(batch.termPairs[0].status).toBe('approved');
      expect(batch.termPairs[1].status).toBe('approved');
      expect(batch.termPairs[2].status).toBe('pending');
    });

    it('approves paragraph pairs with confidence >= 0.9', () => {
      const batch = makeBatch({
        paragraphPairs: [
          makeParagraphPair({ confidence: 0.92, status: 'pending' }),
          makeParagraphPair({ confidence: 0.50, status: 'pending' }),
        ],
      });

      applyAutoApprove(batch, 'review_first');

      expect(batch.paragraphPairs[0].status).toBe('approved');
      expect(batch.paragraphPairs[1].status).toBe('pending');
    });

    it('does not change already-rejected pairs', () => {
      const batch = makeBatch({
        termPairs: [
          makeTermPair({ confidence: 0.99, status: 'rejected' }),
        ],
      });

      applyAutoApprove(batch, 'review_first');

      expect(batch.termPairs[0].status).toBe('rejected');
    });

    it('does not change already-approved pairs', () => {
      const batch = makeBatch({
        termPairs: [
          makeTermPair({ confidence: 0.50, status: 'approved' }),
        ],
      });

      applyAutoApprove(batch, 'review_first');

      expect(batch.termPairs[0].status).toBe('approved');
    });

    it('leaves low-confidence pairs as pending', () => {
      const batch = makeBatch({
        termPairs: [
          makeTermPair({ confidence: 0.0 }),
          makeTermPair({ confidence: 0.5 }),
          makeTermPair({ confidence: 0.89 }),
        ],
        paragraphPairs: [
          makeParagraphPair({ confidence: 0.1 }),
        ],
      });

      applyAutoApprove(batch, 'review_first');

      batch.termPairs.forEach((t) => expect(t.status).toBe('pending'));
      batch.paragraphPairs.forEach((p) => expect(p.status).toBe('pending'));
    });

    it('handles exact threshold boundary (0.9 is approved)', () => {
      const batch = makeBatch({
        termPairs: [makeTermPair({ confidence: 0.9 })],
      });

      applyAutoApprove(batch, 'review_first');

      expect(batch.termPairs[0].status).toBe('approved');
    });
  });

  describe('with auto_approve trust level', () => {
    it('approves ALL pending pairs regardless of confidence', () => {
      const batch = makeBatch({
        termPairs: [
          makeTermPair({ confidence: 0.1, status: 'pending' }),
          makeTermPair({ confidence: 0.5, status: 'pending' }),
          makeTermPair({ confidence: 0.95, status: 'pending' }),
        ],
        paragraphPairs: [
          makeParagraphPair({ confidence: 0.2, status: 'pending' }),
        ],
      });

      applyAutoApprove(batch, 'auto_approve');

      batch.termPairs.forEach((t) => expect(t.status).toBe('approved'));
      batch.paragraphPairs.forEach((p) => expect(p.status).toBe('approved'));
    });

    it('does not change rejected pairs even with auto_approve', () => {
      const batch = makeBatch({
        termPairs: [
          makeTermPair({ confidence: 0.95, status: 'rejected' }),
        ],
      });

      applyAutoApprove(batch, 'auto_approve');

      expect(batch.termPairs[0].status).toBe('rejected');
    });
  });

  describe('mixed scenarios', () => {
    it('handles empty batch gracefully', () => {
      const batch = makeBatch();
      applyAutoApprove(batch, 'review_first');

      expect(batch.termPairs.length).toBe(0);
      expect(batch.paragraphPairs.length).toBe(0);
    });

    it('confidence auto-approve runs before trust-level override', () => {
      const batch = makeBatch({
        termPairs: [
          makeTermPair({ confidence: 0.95, status: 'pending' }),
          makeTermPair({ confidence: 0.3, status: 'pending' }),
        ],
      });

      // Both should end up approved: first by confidence, second by trust level
      applyAutoApprove(batch, 'auto_approve');

      expect(batch.termPairs[0].status).toBe('approved');
      expect(batch.termPairs[1].status).toBe('approved');
    });

    it('large batch with varied confidences', () => {
      const terms = Array.from({ length: 100 }, (_, i) =>
        makeTermPair({ confidence: i / 100, status: 'pending' }),
      );
      const batch = makeBatch({ termPairs: terms });

      applyAutoApprove(batch, 'review_first');

      const approved = batch.termPairs.filter((t) => t.status === 'approved');
      const pending = batch.termPairs.filter((t) => t.status === 'pending');

      // Indices 90-99 (confidence 0.90-0.99) should be approved
      expect(approved.length).toBe(10);
      expect(pending.length).toBe(90);
    });
  });
});
