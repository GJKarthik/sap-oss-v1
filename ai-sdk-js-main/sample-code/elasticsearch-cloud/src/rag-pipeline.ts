/**
 * Complete RAG Pipeline for Elastic Cloud
 * 
 * Demonstrates a production-ready RAG pipeline with:
 * - Document ingestion with embeddings
 * - Hybrid search (vector + text)
 * - Context building and prompt generation
 * - LLM-ready output
 */

import { Client } from '@elastic/elasticsearch';
import { requireValidConfig, CloudConfig } from './config.js';

// ============================================================================
// Sample Documents
// ============================================================================

const SAMPLE_DOCUMENTS = [
  {
    title: 'SAP Business Technology Platform Overview',
    content: `SAP Business Technology Platform (BTP) is an integrated offering that combines 
database, analytics, integration, and extension capabilities into a single, unified platform. 
It enables businesses to develop, extend, and run applications while connecting to both SAP 
and third-party systems. BTP supports multi-cloud deployment on AWS, Azure, and GCP.`,
    source: 'sap-documentation',
    category: 'platform',
  },
  {
    title: 'HANA Cloud Vector Engine',
    content: `SAP HANA Cloud includes a built-in vector engine that enables AI-powered applications. 
The vector engine supports high-dimensional vector storage and similarity search using cosine 
similarity, dot product, and Euclidean distance metrics. It integrates seamlessly with 
SAP AI Core and SAP Generative AI Hub for enterprise AI solutions.`,
    source: 'sap-documentation',
    category: 'database',
  },
  {
    title: 'Generative AI Hub',
    content: `SAP Generative AI Hub provides centralized access to various large language models 
including GPT-4, Claude, and open-source models. It handles authentication, rate limiting, 
and provides a unified API for all AI capabilities. The hub integrates with SAP AI Core 
for model deployment and management.`,
    source: 'sap-documentation',
    category: 'ai',
  },
  {
    title: 'CAP LLM Plugin',
    content: `The CAP LLM Plugin extends SAP Cloud Application Programming Model with AI 
capabilities. It provides easy integration with SAP Generative AI Hub, automatic prompt 
management, RAG support with HANA vector store, and seamless integration with CAP services. 
The plugin supports both synchronous and streaming responses.`,
    source: 'sap-documentation',
    category: 'development',
  },
  {
    title: 'SAP AI Core',
    content: `SAP AI Core is a platform for developing, deploying, and operating AI models 
in production. It supports MLOps workflows, model versioning, A/B testing, and provides 
infrastructure for training and inference. AI Core integrates with popular ML frameworks 
like TensorFlow, PyTorch, and provides GPU support for deep learning workloads.`,
    source: 'sap-documentation',
    category: 'ai',
  },
];

// ============================================================================
// Embedding Generation (Simulated)
// ============================================================================

function generateEmbedding(text: string, dimension: number): number[] {
  const embedding: number[] = [];
  const normalizedText = text.toLowerCase().trim();
  
  for (let i = 0; i < dimension; i++) {
    let value = 0;
    for (let j = 0; j < normalizedText.length; j++) {
      value += normalizedText.charCodeAt(j) * Math.sin(i + j + 1);
    }
    embedding.push(Math.sin(value * (i + 1) * 0.01));
  }
  
  const norm = Math.sqrt(embedding.reduce((sum, v) => sum + v * v, 0));
  return embedding.map(v => v / norm);
}

// ============================================================================
// RAG Pipeline Functions
// ============================================================================

async function ingestDocuments(client: Client, config: CloudConfig): Promise<void> {
  console.log('\n--- Document Ingestion ---\n');
  
  const operations: any[] = [];
  
  for (const doc of SAMPLE_DOCUMENTS) {
    const embedding = generateEmbedding(doc.content, config.embeddingDimension);
    
    operations.push(
      { index: { _index: config.indexName } },
      {
        content: doc.content,
        embedding,
        metadata: {
          title: doc.title,
          source: doc.source,
          category: doc.category,
        },
        indexedAt: new Date().toISOString(),
      }
    );
    
    console.log(`  Prepared: ${doc.title}`);
  }
  
  const result = await client.bulk({ operations, refresh: true });
  
  if (result.errors) {
    console.error('Some documents failed to index');
  } else {
    console.log(`\n✅ Indexed ${SAMPLE_DOCUMENTS.length} documents`);
  }
}

async function hybridSearch(
  client: Client,
  config: CloudConfig,
  query: string,
  topK: number = 3
): Promise<any[]> {
  const queryEmbedding = generateEmbedding(query, config.embeddingDimension);
  
  // Hybrid search: kNN + BM25
  const result = await client.search({
    index: config.indexName,
    size: topK,
    query: {
      bool: {
        should: [
          {
            match: {
              content: {
                query,
                boost: 0.3,
              },
            },
          },
        ],
      },
    },
    knn: {
      field: 'embedding',
      query_vector: queryEmbedding,
      k: topK,
      num_candidates: topK * 4,
    },
  });
  
  return result.hits.hits;
}

function buildContext(documents: any[], maxLength: number = 3000): string {
  let context = '';
  let currentLength = 0;
  
  for (let i = 0; i < documents.length; i++) {
    const doc = documents[i];
    const title = doc._source.metadata?.title || 'Unknown';
    const content = doc._source.content;
    const score = doc._score?.toFixed(3) || '0';
    
    const chunk = `[${i + 1}] ${title} (relevance: ${score})\n${content}\n\n`;
    
    if (currentLength + chunk.length > maxLength) {
      break;
    }
    
    context += chunk;
    currentLength += chunk.length;
  }
  
  return context.trim();
}

function buildPrompt(query: string, context: string): { system: string; user: string } {
  return {
    system: `You are an SAP expert assistant. Answer questions based on the provided context.
Only use information from the context. If the answer isn't in the context, say so.
Cite sources using [1], [2], etc. when referencing specific information.`,
    
    user: `Context:
${context}

Question: ${query}

Please provide a comprehensive answer based on the context above.`,
  };
}

// ============================================================================
// Main Pipeline
// ============================================================================

async function runRagPipeline(): Promise<void> {
  const config = requireValidConfig();
  
  console.log('='.repeat(60));
  console.log('RAG Pipeline - Elastic Cloud');
  console.log('='.repeat(60));
  
  // Create client
  const client = new Client({
    cloud: { id: config.cloudId },
    auth: config.auth.apiKey
      ? { apiKey: config.auth.apiKey }
      : {
          username: config.auth.username!,
          password: config.auth.password!,
        },
  });
  
  try {
    // Step 1: Check index
    const indexExists = await client.indices.exists({ index: config.indexName });
    
    if (!indexExists) {
      console.log('Index does not exist. Run "npm run setup" first.');
      process.exit(1);
    }
    
    // Step 2: Check document count
    const count = await client.count({ index: config.indexName });
    
    if (count.count === 0) {
      console.log('Index is empty. Ingesting sample documents...');
      await ingestDocuments(client, config);
    } else {
      console.log(`\nIndex has ${count.count} documents`);
    }
    
    // Step 3: Run RAG queries
    const queries = [
      'What is SAP BTP and what are its key capabilities?',
      'How does HANA Cloud support vector search?',
      'What is the CAP LLM Plugin used for?',
    ];
    
    console.log('\n--- RAG Queries ---\n');
    
    for (const query of queries) {
      console.log('='.repeat(60));
      console.log(`Query: "${query}"`);
      console.log('='.repeat(60));
      
      // Retrieve relevant documents
      const documents = await hybridSearch(client, config, query);
      
      console.log(`\nRetrieved ${documents.length} documents:`);
      documents.forEach((doc: any, i: number) => {
        const title = doc._source.metadata?.title || 'Unknown';
        console.log(`  [${i + 1}] ${title} (score: ${doc._score?.toFixed(3)})`);
      });
      
      // Build context
      const context = buildContext(documents);
      console.log(`\nContext length: ${context.length} characters`);
      
      // Build prompt
      const prompt = buildPrompt(query, context);
      
      console.log('\n--- Generated Prompt ---');
      console.log('\nSystem Message:');
      console.log(`"${prompt.system.slice(0, 150)}..."`);
      console.log('\nUser Message:');
      console.log(`"${prompt.user.slice(0, 300)}..."`);
      
      console.log('\n');
    }
    
    console.log('='.repeat(60));
    console.log('RAG Pipeline Complete');
    console.log('='.repeat(60));
    console.log('\nThe generated prompts can be sent to any LLM for completion.');
    console.log('Integrate with SAP Generative AI Hub or any LLM provider.');
    
  } finally {
    await client.close();
  }
}

// Run
runRagPipeline().catch(console.error);