/**
 * Hybrid Search Demo
 * 
 * This script demonstrates:
 * - Pure vector search (semantic)
 * - Pure text search (BM25)
 * - Hybrid search (vector + text combined)
 * - Result fusion with RRF
 */

import {
  createElasticsearchClient,
  createHybridSearch,
  createVectorStore,
} from '@sap-ai-sdk/elasticsearch';
import { generateEmbedding } from './ingest-documents.js';
import 'dotenv/config';

// ============================================================================
// Configuration
// ============================================================================

const ES_URL = process.env.ES_URL || 'http://localhost:9200';
const INDEX_NAME = process.env.INDEX_NAME || 'knowledge-base';
const EMBEDDING_DIM = 384;

// ============================================================================
// Main Demo
// ============================================================================

async function runHybridSearchDemo(): Promise<void> {
  console.log('='.repeat(60));
  console.log('Hybrid Search Demonstration');
  console.log('='.repeat(60));
  console.log();
  
  // Connect to Elasticsearch
  const client = createElasticsearchClient({
    node: ES_URL,
    indexName: INDEX_NAME,
    embeddingDims: EMBEDDING_DIM,
  });
  
  try {
    await client.ping();
    console.log('Connected to Elasticsearch\n');
  } catch (error) {
    console.error('Failed to connect. Run: npm run setup && npm run ingest');
    process.exit(1);
  }
  
  const query = 'How does semantic search compare documents?';
  console.log(`Query: "${query}"\n`);
  
  // 1. Vector Search Only
  console.log('-'.repeat(60));
  console.log('1. VECTOR SEARCH (Semantic)');
  console.log('-'.repeat(60));
  
  const queryEmbedding = generateEmbedding(query, EMBEDDING_DIM);
  
  const vectorResults = await client.search({
    index: INDEX_NAME,
    knn: {
      field: 'embedding',
      query_vector: queryEmbedding,
      k: 5,
      num_candidates: 20,
    },
  });
  
  console.log('\nResults:');
  vectorResults.hits.hits.forEach((hit: any, i: number) => {
    console.log(`  ${i + 1}. [${hit._score?.toFixed(3)}] ${hit._source.metadata?.title}`);
    console.log(`     "${hit._source.content.slice(0, 80)}..."`);
  });
  
  // 2. Text Search Only
  console.log('\n' + '-'.repeat(60));
  console.log('2. TEXT SEARCH (BM25)');
  console.log('-'.repeat(60));
  
  const textResults = await client.search({
    index: INDEX_NAME,
    query: {
      match: {
        content: query,
      },
    },
    size: 5,
  });
  
  console.log('\nResults:');
  textResults.hits.hits.forEach((hit: any, i: number) => {
    console.log(`  ${i + 1}. [${hit._score?.toFixed(3)}] ${hit._source.metadata?.title}`);
    console.log(`     "${hit._source.content.slice(0, 80)}..."`);
  });
  
  // 3. Hybrid Search with Builder
  console.log('\n' + '-'.repeat(60));
  console.log('3. HYBRID SEARCH (Vector + Text)');
  console.log('-'.repeat(60));
  
  const hybridBuilder = createHybridSearch()
    .knn('embedding', queryEmbedding, 5, { numCandidates: 20 })
    .text('content', query, { boost: 0.3 })
    .paginate(0, 5);
  
  const hybridQuery = hybridBuilder.build();
  const hybridResults = await client.search({
    index: INDEX_NAME,
    ...hybridQuery,
  });
  
  console.log('\nResults (combined scoring):');
  hybridResults.hits.hits.forEach((hit: any, i: number) => {
    console.log(`  ${i + 1}. [${hit._score?.toFixed(3)}] ${hit._source.metadata?.title}`);
    console.log(`     "${hit._source.content.slice(0, 80)}..."`);
  });
  
  // 4. Hybrid Search with RRF
  console.log('\n' + '-'.repeat(60));
  console.log('4. HYBRID SEARCH WITH RRF');
  console.log('-'.repeat(60));
  
  const rrfBuilder = createHybridSearch()
    .knn('embedding', queryEmbedding, 10, { numCandidates: 50 })
    .text('content', query)
    .withRrf(60) // RRF with k=60
    .paginate(0, 5);
  
  console.log('\nRRF Query Structure:');
  const rrfQuery = rrfBuilder.build();
  console.log('  - Uses rank fusion to combine results');
  console.log('  - Each result gets RRF score = sum(1/(k + rank))');
  console.log('  - k=60 provides balanced fusion');
  
  // Note: Native RRF requires Elasticsearch Enterprise
  // For demo, we show the query structure
  console.log('\nQuery built successfully (RRF requires Enterprise license for native support)');
  
  // 5. Filtered Hybrid Search
  console.log('\n' + '-'.repeat(60));
  console.log('5. FILTERED HYBRID SEARCH');
  console.log('-'.repeat(60));
  
  const filteredBuilder = createHybridSearch()
    .knn('embedding', queryEmbedding, 5, {
      numCandidates: 20,
      filter: { term: { 'metadata.category': 'search' } },
    })
    .text('content', query)
    .filter({ term: { 'metadata.source': 'documentation' } })
    .paginate(0, 5);
  
  const filteredQuery = filteredBuilder.build();
  const filteredResults = await client.search({
    index: INDEX_NAME,
    ...filteredQuery,
  });
  
  console.log('\nFiltered results (category=search, source=documentation):');
  filteredResults.hits.hits.forEach((hit: any, i: number) => {
    console.log(`  ${i + 1}. [${hit._score?.toFixed(3)}] ${hit._source.metadata?.title}`);
    console.log(`     Category: ${hit._source.metadata?.category}, Source: ${hit._source.metadata?.source}`);
  });
  
  // Summary
  console.log('\n' + '='.repeat(60));
  console.log('Search Comparison Summary');
  console.log('='.repeat(60));
  console.log();
  console.log('| Method       | Best For                          |');
  console.log('|--------------|-----------------------------------|');
  console.log('| Vector       | Semantic similarity, concepts     |');
  console.log('| Text (BM25)  | Exact keywords, specific terms    |');
  console.log('| Hybrid       | Balanced retrieval                |');
  console.log('| Hybrid + RRF | Best overall quality              |');
  console.log();
  
  await client.close();
}

// Run if executed directly
runHybridSearchDemo().catch(console.error);

export { runHybridSearchDemo };