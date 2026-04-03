export const ARABIC_PRIMARY_CHAT_MODEL = 'google/gemma-4-E4B-it';

interface ChatMessageLike {
  content?: unknown;
}

interface ChatRoutingInput {
  requestedModel?: string;
  uiLanguage?: string;
  messages?: ChatMessageLike[];
}

interface OcrDocumentInput {
  fileName?: string;
  mimeType?: string;
  fileContentBase64?: string;
  text?: string;
  language?: string;
  documentType?: string;
}

interface InvoiceField {
  key: string;
  value: string;
  confidence: number;
}

interface InvoiceLineItem {
  description_ar: string;
  description_en: string;
  quantity: number;
  unit_price: number;
  total: number;
}

export interface OcrExtractionResult {
  document_type: string;
  original_ar: string;
  translated_en: string;
  financial_fields: InvoiceField[];
  line_items: InvoiceLineItem[];
}

export function containsArabicScript(text: string): boolean {
  return /[\u0600-\u06FF]/.test(text);
}

function flattenMessageContent(content: unknown): string {
  if (typeof content === 'string') {
    return content;
  }
  if (!Array.isArray(content)) {
    return '';
  }
  return content
    .map((item) => {
      if (typeof item === 'string') return item;
      if (item && typeof item === 'object' && 'text' in item) {
        const candidate = (item as { text?: unknown }).text;
        return typeof candidate === 'string' ? candidate : '';
      }
      return '';
    })
    .join(' ');
}

export function resolveChatModelAlias(input: ChatRoutingInput): string | undefined {
  const requestedModel = input.requestedModel?.trim();
  if (requestedModel) {
    return requestedModel;
  }

  const language = input.uiLanguage?.trim().toLowerCase();
  if (language === 'ar' || language === 'arabic') {
    return ARABIC_PRIMARY_CHAT_MODEL;
  }

  const joinedMessages = (input.messages ?? [])
    .map((message) => flattenMessageContent(message.content))
    .join(' ');

  if (containsArabicScript(joinedMessages)) {
    return ARABIC_PRIMARY_CHAT_MODEL;
  }

  return undefined;
}

export function buildOcrExtractionResult(input: OcrDocumentInput): OcrExtractionResult {
  const originalText = input.text?.trim() || '';
  const isArabic = input.language === 'ar' || containsArabicScript(originalText);
  const fileHint = input.fileName ? ` [source file: ${input.fileName}]` : '';
  const hasUploadedFile = Boolean(input.fileContentBase64);
  const translatedText = isArabic
    ? `Translated to English: ${originalText || (hasUploadedFile ? '[OCR placeholder text]' : '[no text extracted]')}${fileHint}`
    : (originalText || (hasUploadedFile ? '[OCR placeholder text]' : '[no text extracted]')) + fileHint;

  return {
    document_type: input.documentType || 'invoice',
    original_ar: isArabic ? originalText : '',
    translated_en: translatedText,
    financial_fields: [
      { key: 'invoice_number', value: 'INV-PLACEHOLDER', confidence: 0.4 },
      { key: 'invoice_date', value: '1970-01-01', confidence: 0.3 },
      { key: 'currency', value: 'SAR', confidence: 0.5 },
      { key: 'vat_total', value: '0.00', confidence: 0.2 },
      { key: 'grand_total', value: '0.00', confidence: 0.2 },
    ],
    line_items: [
      {
        description_ar: isArabic ? 'عنصر تجريبي' : '',
        description_en: 'Sample line item',
        quantity: 1,
        unit_price: 0,
        total: 0,
      },
    ],
  };
}
