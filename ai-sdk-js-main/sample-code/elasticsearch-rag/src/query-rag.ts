/**
 * RAG Query Example
 * 
 * This script demonstrates how to:
 * - Create a grounding module for RAG
 * - Retrieve relevant documents
 * - Build context for LLM prompts
 * - Generate prompts with sources
 */

import {
  createElasticsearchClient,
  createGroundingModule,
  createContextBuilder,
  PromptTemplates,
  metadataFilter,
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
// Sample Queries
// ============================================================================

const SAMPLE_QUERIES = [
  'What is RAG and how does it work?',
  'How does hybrid search improve results?',
  'What embedding models are available?',
  'How do I evaluate a RAG system?',
  'What is the best chunking strategy?',
];

// ============================================================================
// RAG Query Pipeline
// ============================================================================

async function runRagQueries(): Promise<void> {
  console.log('='.repeat(60));
  console.log('RAG Query Pipeline');
  console.log('='.repeat(60));
  console.log();
  
  // 1. Create Elasticsearch client
  console.log('1. Connecting to Elasticsearch...');
  const client = createElasticsearchClient({
    node: ES_URL,
    indexName: INDEX_NAME,
    embeddingDims: EMBEDDING_DIM,
  });
  
  try {
    await client.ping();
    console.log('   Connected!');
  } catch (error) {
    console.error('   Failed to connect. Run: npm run setup && npm run ingest');
    process.exit(1);
  }
  
  // 2. Create grounding module
  console.log('\n2. Setting up grounding module...');
  const grounding = createGroundingModule(client, INDEX_NAME, {
    embedFn: async (text: string) => generateEmbedding(text, EMBEDDING_DIM),
    defaultOptions: {
      topK: 5,
      minScore: 0.1,
    },
  });
  console.log('   Grounding module ready');
  
  // 3. Create context builder
  console.log('\n3. Creating context builder...');
  const contextBuilder = createContextBuilder({
    maxContextLength: 4000,
    referenceFormat: 'numbered',
    includeSources: true,
  });
  console.log('   Context builder ready');
  
  // 4. Run queries
  console.log('\n4. Running RAG queries...');
  console.log();
  
  for (const query of SAMPLE_QUERIES) {
    console.log('-'.repeat(60));
    console.log(`Query: "${query}"`);
    console.log('-'.repeat(60));
    
    // Ground the query (retrieve relevant documents)
    const groundingResult = await grounding.ground(query, {
      topK: 3,
      useHybrid: false, // Use pure vector search
    });
    
    console.log(`\nRetrieved ${groundingResult.sources.length} sources (${groundingResult.took}ms):`);
    groundingResult.sources.forEach((source, i) => {
      const title = source.metadata?.title || 'Unknown';
      console.log(`  [${i + 1}] ${title} (score: ${source.score.toFixed(3)})`);
    });
    
    // Build context from sources
    const context = contextBuilder.build(groundingResult);
    
    console.log(`\nContext (${context.context.length} chars):`);
    console.log(`  "${context.context.slice(0, 200)}..."`);
    
    // Build the prompt
    const prompt = PromptTemplates.qaWithSources.build(query, context);
    
    console.log('\nGenerated Prompt:');
    console.log('  System:', prompt.system.slice(0, 100) + '...');
    console.log('  User:', prompt.user.slice(0, 200) + '...');
    console.log();
  }
  
  // 5. Example with metadata filter
  console.log('='.repeat(60));
  console.log('Filtered Query Example');
  console.log('='.repeat(60));
  
  const filterQuery = 'How does vector search work?';
  console.log(`\nQuery: "${filterQuery}"`);
  console.log('Filter: category = "search"');
  
  const filter = metadataFilter()
    .term('metadata.category', 'search')
    .build();
  
  const filteredResult = await grounding.ground(filterQuery, {
    topK: 3,
    filter,
  });
  
  console.log(`\nFiltered results (${filteredResult.sources.length} sources):`);
  filteredResult.sources.forEach((source, i) => {
    console.log(`  [${i + 1}] ${source.metadata?.title} (${source.metadata?.category})`);
  });
  
  console.log();
  console.log('='.repeat(60));
  console.log('Query pipeline complete!');
  console.log('='.repeat(60));
  
  await client.close();
}

// Run if executed directly
runRagQueries().catch(console.error);

export { runRagQueries };