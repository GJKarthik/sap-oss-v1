// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2024 SAP SE
/**
 * Document Ingestion Example
 * 
 * This script demonstrates how to:
 * - Create an Elasticsearch vector store
 * - Chunk documents for better retrieval
 * - Generate embeddings (simulated)
 * - Bulk index documents
 */

import {
  createElasticsearchClient,
  createVectorStore,
  createChunker,
  ChunkPresets,
} from '@sap-ai-sdk/elasticsearch';
import 'dotenv/config';

// ============================================================================
// Configuration
// ============================================================================

const ES_URL = process.env.ES_URL || 'http://localhost:9200';
const INDEX_NAME = process.env.INDEX_NAME || 'knowledge-base';
const EMBEDDING_DIM = 384; // Using small dimension for demo

// ============================================================================
// Sample Documents (Knowledge Base)
// ============================================================================

const SAMPLE_DOCUMENTS = [
  {
    title: 'Introduction to RAG',
    content: `Retrieval-Augmented Generation (RAG) is a technique that enhances large language models 
by retrieving relevant information from external knowledge sources. Instead of relying solely on 
the model's training data, RAG systems first search a knowledge base for relevant documents, 
then use these documents as context when generating responses. This approach helps reduce 
hallucinations, provides up-to-date information, and allows for domain-specific knowledge.`,
    source: 'documentation',
    category: 'ai',
  },
  {
    title: 'Vector Search Fundamentals',
    content: `Vector search, also known as semantic search, works by converting text into numerical 
vectors (embeddings) that capture semantic meaning. Similar concepts end up close together in 
vector space. When you search, your query is also converted to a vector, and the system finds 
documents with vectors close to your query vector. Common similarity metrics include cosine 
similarity, dot product, and Euclidean distance. Modern systems like Elasticsearch support 
approximate nearest neighbor (ANN) search for fast retrieval at scale.`,
    source: 'documentation',
    category: 'search',
  },
  {
    title: 'Elasticsearch kNN Search',
    content: `Elasticsearch provides native support for k-nearest neighbor (kNN) search using 
dense_vector fields. The kNN search finds the k most similar vectors to a query vector. 
Elasticsearch uses the HNSW algorithm for efficient approximate search. Key parameters include 
the number of candidates to consider and the similarity function (cosine, dot_product, or l2_norm). 
You can also combine kNN search with traditional BM25 text search for hybrid retrieval.`,
    source: 'elasticsearch-docs',
    category: 'search',
  },
  {
    title: 'Hybrid Search Strategy',
    content: `Hybrid search combines multiple retrieval methods to improve result quality. The most 
common approach combines vector search (for semantic understanding) with keyword search (for 
exact matches). Results from different methods can be merged using techniques like Reciprocal 
Rank Fusion (RRF), which computes a weighted score based on each result's rank in the individual 
result lists. Hybrid search often outperforms either method alone, especially for queries that 
contain both semantic concepts and specific keywords.`,
    source: 'documentation',
    category: 'search',
  },
  {
    title: 'Text Chunking Strategies',
    content: `When processing documents for RAG, it's important to split them into appropriately 
sized chunks. Common strategies include: fixed-size chunking (splitting at character boundaries), 
sentence-based chunking (splitting at sentence boundaries), paragraph-based chunking (splitting 
at paragraph breaks), and recursive chunking (trying multiple separators). Chunks should be small 
enough to be focused but large enough to contain meaningful context. Overlapping chunks can help 
ensure important information isn't split across boundaries.`,
    source: 'documentation',
    category: 'processing',
  },
  {
    title: 'Embedding Models',
    content: `Embedding models convert text into dense vectors that capture semantic meaning. 
Popular options include OpenAI's text-embedding-ada-002 (1536 dimensions), Sentence Transformers 
(various sizes from 384 to 768 dimensions), and Google's gecko (768 dimensions). When choosing 
an embedding model, consider: dimensionality (larger means more expressive but slower), 
training data (domain-specific models may perform better), and inference speed. All documents 
and queries must use the same embedding model for consistent similarity comparisons.`,
    source: 'documentation',
    category: 'ai',
  },
  {
    title: 'Context Window Management',
    content: `LLMs have limited context windows (e.g., 4K, 8K, 32K, or 128K tokens). When building 
RAG systems, you need to fit both the retrieved documents and the user query within this limit. 
Strategies include: selecting only the most relevant chunks, summarizing long documents, using 
hierarchical retrieval (retrieve, then rerank), and dynamic context pruning. The context should 
include enough information to answer the query without overwhelming the model with irrelevant data.`,
    source: 'documentation',
    category: 'ai',
  },
  {
    title: 'Query Expansion Techniques',
    content: `Query expansion improves retrieval by reformulating or augmenting the original query. 
Techniques include: using LLMs to generate hypothetical answers (HyDE), extracting keywords and 
synonyms, decomposing complex queries into sub-queries, and query rewriting for clarity. These 
techniques help bridge the vocabulary gap between user queries and document content, improving 
recall. However, they can also introduce noise, so it's important to evaluate their effectiveness 
for your specific use case.`,
    source: 'documentation',
    category: 'search',
  },
  {
    title: 'Reranking for Quality',
    content: `Reranking is a second-stage retrieval step that improves result quality. After initial 
retrieval (which prioritizes recall), a reranker scores each candidate for relevance. Common 
approaches include: cross-encoder models (which jointly encode query and document), LLM-based 
reranking (using the model to score relevance), and learned ranking functions. Reranking is 
particularly effective when initial retrieval returns many candidates, as it can significantly 
improve precision at the cost of additional computation.`,
    source: 'documentation',
    category: 'search',
  },
  {
    title: 'Evaluation Metrics for RAG',
    content: `Evaluating RAG systems requires measuring both retrieval and generation quality. 
Retrieval metrics include: recall@k (fraction of relevant documents in top k), precision@k 
(fraction of top k that are relevant), and MRR (reciprocal rank of first relevant result). 
Generation metrics include: faithfulness (is the answer supported by sources?), answer relevance 
(does it address the query?), and hallucination rate. End-to-end metrics like RAGAS combine 
multiple factors for holistic evaluation.`,
    source: 'documentation',
    category: 'evaluation',
  },
];

// ============================================================================
// Simple Embedding Function (Simulated)
// ============================================================================

/**
 * Generate a simple embedding vector.
 * In production, you would use a real embedding model (OpenAI, Sentence Transformers, etc.)
 */
function generateEmbedding(text: string, dimension: number = EMBEDDING_DIM): number[] {
  // Simple hash-based embedding for demo purposes
  // This creates consistent embeddings for the same text
  const embedding: number[] = [];
  const normalizedText = text.toLowerCase().trim();
  
  for (let i = 0; i < dimension; i++) {
    // Use character codes and position to generate pseudo-random but deterministic values
    let value = 0;
    for (let j = 0; j < normalizedText.length; j++) {
      value += normalizedText.charCodeAt(j) * Math.sin(i + j + 1);
    }
    embedding.push(Math.sin(value * (i + 1) * 0.01));
  }
  
  // Normalize to unit length
  const norm = Math.sqrt(embedding.reduce((sum, v) => sum + v * v, 0));
  return embedding.map(v => v / norm);
}

// ============================================================================
// Main Ingestion Function
// ============================================================================

async function ingestDocuments(): Promise<void> {
  console.log('='.repeat(60));
  console.log('Document Ingestion Pipeline');
  console.log('='.repeat(60));
  console.log();
  
  // 1. Create Elasticsearch client
  console.log('1. Connecting to Elasticsearch...');
  const client = createElasticsearchClient({
    node: ES_URL,
    indexName: INDEX_NAME,
    embeddingDims: EMBEDDING_DIM,
  });
  
  // Test connection
  try {
    const info = await client.info();
    console.log(`   Connected to: ${info.cluster_name} (v${info.version.number})`);
  } catch (error) {
    console.error('   Failed to connect. Is Elasticsearch running?');
    console.error('   Run: npm run setup');
    process.exit(1);
  }
  
  // 2. Create vector store
  console.log('\n2. Creating vector store...');
  const vectorStore = await createVectorStore(client, INDEX_NAME, {
    embeddingDimension: EMBEDDING_DIM,
    similarity: 'cosine',
  });
  console.log(`   Index: ${INDEX_NAME}`);
  console.log(`   Embedding dimension: ${EMBEDDING_DIM}`);
  
  // 3. Create chunker
  console.log('\n3. Setting up text chunker...');
  const chunker = createChunker({
    ...ChunkPresets.medium,
    chunkSize: 500,
    chunkOverlap: 50,
  });
  console.log('   Strategy: medium chunks (500 chars, 50 overlap)');
  
  // 4. Process documents
  console.log('\n4. Processing documents...');
  const documents: Array<{
    id: string;
    content: string;
    embedding: number[];
    metadata: Record<string, unknown>;
  }> = [];
  
  for (const doc of SAMPLE_DOCUMENTS) {
    // Chunk the document
    const chunks = chunker.chunk(doc.content);
    console.log(`   "${doc.title}" -> ${chunks.length} chunk(s)`);
    
    // Create document for each chunk
    for (let i = 0; i < chunks.length; i++) {
      const chunk = chunks[i];
      const docId = `${doc.title.toLowerCase().replace(/\s+/g, '-')}-chunk-${i}`;
      
      documents.push({
        id: docId,
        content: chunk.text,
        embedding: generateEmbedding(chunk.text),
        metadata: {
          title: doc.title,
          source: doc.source,
          category: doc.category,
          chunkIndex: i,
          totalChunks: chunks.length,
          charStart: chunk.start,
          charEnd: chunk.end,
          indexedAt: new Date().toISOString(),
        },
      });
    }
  }
  
  console.log(`   Total chunks: ${documents.length}`);
  
  // 5. Index documents
  console.log('\n5. Indexing documents...');
  const result = await vectorStore.upsertDocuments(documents, {
    batchSize: 50,
    onProgress: (progress) => {
      process.stdout.write(`\r   Progress: ${progress.processed}/${progress.total} (${progress.percent.toFixed(0)}%)`);
    },
  });
  
  console.log();
  console.log(`   Indexed: ${result.totalIndexed}`);
  console.log(`   Failed: ${result.totalFailed}`);
  
  // 6. Verify indexing
  console.log('\n6. Verifying index...');
  const count = await client.count({ index: INDEX_NAME });
  console.log(`   Document count: ${count.count}`);
  
  // Get index stats
  const stats = await client.indices.stats({ index: INDEX_NAME });
  const indexStats = stats.indices?.[INDEX_NAME]?.primaries;
  if (indexStats) {
    console.log(`   Index size: ${(indexStats.store?.size_in_bytes || 0) / 1024} KB`);
  }
  
  console.log();
  console.log('='.repeat(60));
  console.log('Ingestion complete!');
  console.log('='.repeat(60));
  console.log();
  console.log('Next steps:');
  console.log('  npm run query       - Run RAG queries');
  console.log('  npm run interactive - Interactive query mode');
  console.log('  npm run hybrid      - Hybrid search demo');
  
  await client.close();
}

// Run if executed directly
ingestDocuments().catch(console.error);

export { ingestDocuments, generateEmbedding, SAMPLE_DOCUMENTS };