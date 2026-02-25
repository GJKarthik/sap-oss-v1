#!/usr/bin/env npx ts-node
/**
 * HANA Vector Integration Tests
 * 
 * Run with: npx ts-node tests/integration/run-tests.ts
 * 
 * Prerequisites:
 * 1. Copy .env.example to .env and fill in credentials
 * 2. npm install dotenv
 */

import * as dotenv from 'dotenv';
import * as path from 'path';

// Load environment variables
dotenv.config({ path: path.join(__dirname, '.env') });

import {
  createHANAClient,
  createHANAVectorStore,
  createHANARdfGraph,
  HANAError,
  type HANAConfig,
  type VectorStoreConfig,
} from '../../src/index.js';

// ============================================================================
// Configuration
// ============================================================================

const config: HANAConfig = {
  host: process.env.HANA_HOST!,
  port: parseInt(process.env.HANA_PORT || '443', 10),
  user: process.env.HANA_USER!,
  password: process.env.HANA_PASSWORD!,
  schema: process.env.HANA_SCHEMA,
  encrypt: true,
  sslValidateCertificate: true,
};

const tablePrefix = process.env.TEST_TABLE_PREFIX || 'TEST_';

// ============================================================================
// Test Utilities
// ============================================================================

let passedTests = 0;
let failedTests = 0;

function log(message: string) {
  console.log(`[${new Date().toISOString()}] ${message}`);
}

function logSection(title: string) {
  console.log('\n' + '='.repeat(60));
  console.log(`  ${title}`);
  console.log('='.repeat(60) + '\n');
}

async function test(name: string, fn: () => Promise<void>) {
  try {
    log(`Running: ${name}...`);
    await fn();
    log(`✅ PASSED: ${name}`);
    passedTests++;
  } catch (error: any) {
    log(`❌ FAILED: ${name}`);
    log(`   Error: ${error.message}`);
    if (error.sqlCode) {
      log(`   SQL Code: ${error.sqlCode}`);
    }
    failedTests++;
  }
}

// Generate a random embedding for testing
function randomEmbedding(dims: number): number[] {
  const embedding: number[] = [];
  for (let i = 0; i < dims; i++) {
    embedding.push(Math.random() * 2 - 1); // Random between -1 and 1
  }
  // Normalize to unit vector
  const norm = Math.sqrt(embedding.reduce((sum, x) => sum + x * x, 0));
  return embedding.map(x => x / norm);
}

// ============================================================================
// Integration Tests
// ============================================================================

async function runTests() {
  logSection('HANA Vector Integration Tests');

  // Validate configuration
  if (!config.host || !config.user || !config.password) {
    console.error('❌ Missing required environment variables!');
    console.error('   Please copy .env.example to .env and fill in your credentials.');
    console.error('\n   Required variables:');
    console.error('   - HANA_HOST');
    console.error('   - HANA_USER');
    console.error('   - HANA_PASSWORD');
    process.exit(1);
  }

  log(`Connecting to: ${config.host}`);
  log(`User: ${config.user}`);
  log(`Schema: ${config.schema || '(default)'}`);

  // Create client
  const client = createHANAClient(config);

  // ---------------------------------------------
  // Connection Tests
  // ---------------------------------------------
  logSection('1. Connection Tests');

  await test('Initialize connection', async () => {
    await client.init();
  });

  await test('Execute simple query', async () => {
    const result = await client.query<{ VAL: number }>('SELECT 1 AS "VAL" FROM DUMMY');
    if (result[0]?.VAL !== 1) {
      throw new Error(`Expected 1, got ${result[0]?.VAL}`);
    }
  });

  await test('Check HANA version', async () => {
    const result = await client.query<{ VERSION: string }>('SELECT VERSION FROM SYS.M_DATABASE');
    log(`   HANA Version: ${result[0]?.VERSION}`);
  });

  // ---------------------------------------------
  // Vector Store Tests
  // ---------------------------------------------
  logSection('2. Vector Store Tests');

  const testTable = `${tablePrefix}DOCUMENTS_${Date.now()}`;
  const embeddingDims = 384; // Small embedding size for testing

  const vectorStore = createHANAVectorStore(client, {
    tableName: testTable,
    schemaName: config.schema,
    embeddingDimensions: embeddingDims,
  });

  await test('Create vector table', async () => {
    await vectorStore.createTable();
  });

  await test('Verify table exists', async () => {
    const exists = await vectorStore.tableExists();
    if (!exists) {
      throw new Error('Table was not created');
    }
  });

  await test('Add single document', async () => {
    await vectorStore.add({
      id: 'doc-1',
      content: 'SAP HANA Cloud is a cloud-native in-memory database.',
      embedding: randomEmbedding(embeddingDims),
      metadata: { source: 'test', category: 'database' },
    });
  });

  await test('Add multiple documents', async () => {
    await vectorStore.addMany([
      {
        id: 'doc-2',
        content: 'The Vector Engine enables similarity search on embeddings.',
        embedding: randomEmbedding(embeddingDims),
        metadata: { source: 'test', category: 'vector' },
      },
      {
        id: 'doc-3',
        content: 'COSINE_SIMILARITY calculates cosine distance between vectors.',
        embedding: randomEmbedding(embeddingDims),
        metadata: { source: 'test', category: 'vector' },
      },
      {
        id: 'doc-4',
        content: 'HNSW indexes speed up approximate nearest neighbor search.',
        embedding: randomEmbedding(embeddingDims),
        metadata: { source: 'test', category: 'index' },
      },
    ]);
  });

  await test('Get document count', async () => {
    const count = await vectorStore.count();
    if (count !== 4) {
      throw new Error(`Expected 4 documents, got ${count}`);
    }
  });

  await test('Get document by ID', async () => {
    const doc = await vectorStore.get('doc-1');
    if (!doc) {
      throw new Error('Document not found');
    }
    if (doc.id !== 'doc-1') {
      throw new Error(`Wrong document ID: ${doc.id}`);
    }
    log(`   Content: ${doc.content.slice(0, 50)}...`);
  });

  await test('Similarity search (COSINE)', async () => {
    const queryEmbedding = randomEmbedding(embeddingDims);
    const results = await vectorStore.similaritySearch(queryEmbedding, {
      k: 3,
      metric: 'COSINE',
    });
    if (results.length === 0) {
      throw new Error('No results returned');
    }
    log(`   Found ${results.length} results`);
    log(`   Top score: ${results[0].score.toFixed(4)}`);
  });

  await test('Similarity search with filter', async () => {
    const queryEmbedding = randomEmbedding(embeddingDims);
    const results = await vectorStore.similaritySearch(queryEmbedding, {
      k: 3,
      filter: { category: 'vector' },
    });
    log(`   Found ${results.length} results with category='vector'`);
  });

  await test('MMR search', async () => {
    const queryEmbedding = randomEmbedding(embeddingDims);
    const results = await vectorStore.maxMarginalRelevanceSearch(queryEmbedding, {
      k: 3,
      lambda: 0.5,
      fetchK: 10,
    });
    log(`   Found ${results.length} diverse results`);
  });

  await test('Upsert document', async () => {
    await vectorStore.upsert([{
      id: 'doc-1',
      content: 'SAP HANA Cloud is a powerful cloud-native in-memory database platform.',
      embedding: randomEmbedding(embeddingDims),
      metadata: { source: 'test', category: 'database', updated: true },
    }]);

    const doc = await vectorStore.get('doc-1');
    if (!doc?.metadata?.updated) {
      throw new Error('Document was not updated');
    }
  });

  await test('Delete document', async () => {
    await vectorStore.delete(['doc-4']);
    const count = await vectorStore.count();
    if (count !== 3) {
      throw new Error(`Expected 3 documents after delete, got ${count}`);
    }
  });

  // ---------------------------------------------
  // HNSW Index Tests
  // ---------------------------------------------
  logSection('3. HNSW Index Tests');

  await test('Create HNSW index', async () => {
    await vectorStore.createHnswIndex({
      m: 16,
      efConstruction: 100,
      efSearch: 50,
      metric: 'COSINE',
    });
    log('   HNSW index created successfully');
  });

  await test('Search with HNSW index', async () => {
    const queryEmbedding = randomEmbedding(embeddingDims);
    const results = await vectorStore.similaritySearch(queryEmbedding, {
      k: 3,
    });
    log(`   Found ${results.length} results using HNSW index`);
  });

  // ---------------------------------------------
  // Cleanup
  // ---------------------------------------------
  logSection('4. Cleanup');

  await test('Drop test table', async () => {
    await vectorStore.dropTable();
  });

  await test('Verify table dropped', async () => {
    const exists = await vectorStore.tableExists();
    if (exists) {
      throw new Error('Table was not dropped');
    }
  });

  await test('Close connection', async () => {
    await client.close();
  });

  // ---------------------------------------------
  // Summary
  // ---------------------------------------------
  logSection('Test Summary');

  console.log(`✅ Passed: ${passedTests}`);
  console.log(`❌ Failed: ${failedTests}`);
  console.log(`📊 Total:  ${passedTests + failedTests}`);
  console.log();

  if (failedTests > 0) {
    console.log('⚠️  Some tests failed. Please check the output above.');
    process.exit(1);
  } else {
    console.log('🎉 All tests passed!');
    process.exit(0);
  }
}

// Run tests
runTests().catch((error) => {
  console.error('Fatal error:', error);
  process.exit(1);
});