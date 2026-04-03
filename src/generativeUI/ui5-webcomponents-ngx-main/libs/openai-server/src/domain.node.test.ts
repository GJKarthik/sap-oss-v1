import assert from 'node:assert/strict';
import test from 'node:test';
import {
  ARABIC_PRIMARY_CHAT_MODEL,
  buildFallbackOcrExtractionResult,
  containsArabicScript,
  normalizeOcrExtractionResult,
  resolveChatModelAlias,
} from './domain';

test('containsArabicScript detects Arabic Unicode range', () => {
  assert.equal(containsArabicScript('مرحبا'), true);
  assert.equal(containsArabicScript('hello'), false);
});

test('resolveChatModelAlias prioritizes explicit model', () => {
  const model = resolveChatModelAlias({
    requestedModel: 'custom-model',
    uiLanguage: 'ar',
    messages: [{ content: 'فاتورة' }],
  });
  assert.equal(model, 'custom-model');
});

test('resolveChatModelAlias returns Arabic primary model for Arabic input', () => {
  const fromLanguage = resolveChatModelAlias({ uiLanguage: 'ar' });
  assert.equal(fromLanguage, ARABIC_PRIMARY_CHAT_MODEL);
  const fromMessage = resolveChatModelAlias({ messages: [{ content: 'مرحبا' }] });
  assert.equal(fromMessage, ARABIC_PRIMARY_CHAT_MODEL);
});

test('normalizeOcrExtractionResult fills missing fields with fallback', () => {
  const normalized = normalizeOcrExtractionResult(
    {
      translated_en: 'Invoice total 100',
      financial_fields: [{ key: 'grand_total', value: '100', confidence: 0.9 }],
    },
    { language: 'ar', text: 'إجمالي ١٠٠', documentType: 'invoice' },
  );
  assert.equal(normalized.document_type, 'invoice');
  assert.ok(normalized.original_ar.length > 0);
  assert.ok(normalized.financial_fields.length > 0);
  assert.ok(normalized.line_items.length > 0);
});

test('buildFallbackOcrExtractionResult includes placeholder hint for file uploads', () => {
  const fallback = buildFallbackOcrExtractionResult({
    fileName: 'invoice.pdf',
    fileContentBase64: 'ZmFrZQ==',
    language: 'ar',
    text: '',
  });
  assert.ok(fallback.translated_en.includes('[OCR placeholder text]'));
  assert.ok(fallback.translated_en.includes('invoice.pdf'));
});
