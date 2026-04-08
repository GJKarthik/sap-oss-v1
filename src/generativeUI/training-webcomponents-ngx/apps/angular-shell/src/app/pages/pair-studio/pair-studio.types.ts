/**
 * Translation Pair Studio — Type definitions
 *
 * Covers term pairs, paragraph pairs, ingestion batches,
 * and the alignment request/response contract with the backend.
 */

// ---------------------------------------------------------------------------
// Core enums & small types
// ---------------------------------------------------------------------------

export type PairType = 'translation' | 'alias' | 'db_field_mapping';
export type PairStatus = 'pending' | 'approved' | 'rejected';
export type PipelineKind = 'structured' | 'schema_import' | 'single_bilingual_pdf' | 'dual_document';
export type TrustLevel = 'auto_approve' | 'review_first';

export interface DbContext {
  tableName?: string;
  columnName?: string;
  dataType?: string;
}

// ---------------------------------------------------------------------------
// Pair models
// ---------------------------------------------------------------------------

export interface TermPair {
  sourceTerm: string;
  targetTerm: string;
  sourceLang: string;
  targetLang: string;
  pairType: PairType;
  category: string;
  confidence: number;
  dbContext?: DbContext;
  existsInGlossary: boolean;
  status: PairStatus;
}

export interface ParagraphPair {
  sourceText: string;
  targetText: string;
  sourceLang: string;
  targetLang: string;
  confidence: number;
  page?: number;
  status: PairStatus;
}

// ---------------------------------------------------------------------------
// Ingestion batch
// ---------------------------------------------------------------------------

export interface IngestionBatch {
  id: string;
  files: IngestionFile[];
  pairType: PairType;
  sourceLang: string;
  targetLang: string;
  trustLevel: TrustLevel;
  pipeline: PipelineKind;
  termPairs: TermPair[];
  paragraphPairs: ParagraphPair[];
  processing: boolean;
  error?: string;
}

export interface IngestionFile {
  file: File;
  name: string;
  type: string;
  size: number;
}

// ---------------------------------------------------------------------------
// Commit result
// ---------------------------------------------------------------------------

export interface CommitResult {
  termsSaved: number;
  termsFailed: number;
  paragraphsSaved: number;
  paragraphsFailed: number;
  newGlossaryEntries: number;
  updatedEntries: number;
  failedIds: string[];
}

// ---------------------------------------------------------------------------
// Backend alignment contract (POST /api/rag/tm/align)
// ---------------------------------------------------------------------------

export interface AlignRequestSource {
  pages: AlignOcrPage[];
  lang: string;
}

export interface AlignOcrPage {
  page_number: number;
  text: string;
  text_regions: { text: string; confidence: number; language: string }[];
}

export interface AlignRequest {
  source: AlignRequestSource;
  target: AlignRequestSource;
  options: {
    granularity: 'paragraph' | 'sentence';
    extractTerms: boolean;
    existingGlossary?: { ar: string; en: string; category: string }[];
  };
}

export interface AlignedParagraph {
  sourceText: string;
  targetText: string;
  sourcePage: number;
  targetPage: number;
  confidence: number;
  alignmentMethod: 'structural' | 'number_anchor' | 'heading_match' | 'length_ratio';
}

export interface ExtractedTerm {
  sourceTerm: string;
  targetTerm: string;
  sourceLang: string;
  targetLang: string;
  category: string;
  confidence: number;
  extractionMethod: 'glossary_match' | 'llm_extraction' | 'number_cooccurrence';
}

export interface AlignResponse {
  paragraphPairs: AlignedParagraph[];
  termPairs: ExtractedTerm[];
  stats: {
    totalSourceParagraphs: number;
    totalTargetParagraphs: number;
    alignedCount: number;
    unalignedCount: number;
    termsExtracted: number;
    processingTimeMs: number;
  };
}
