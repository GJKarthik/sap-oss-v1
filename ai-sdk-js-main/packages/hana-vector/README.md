# @sap-ai-sdk/hana-vector

SAP HANA Cloud Vector Engine client for RAG and AI applications.

## Features

- 🔗 **Connection Pooling** - Efficient connection management
- 🎯 **Vector Storage** - Store embeddings with REAL_VECTOR type
- 🔍 **Similarity Search** - COSINE_SIMILARITY, EUCLIDEAN, DOT_PRODUCT
- 📊 **Hybrid Search** - Combine vector and keyword search
- 🎲 **MMR Search** - Maximum Marginal Relevance for diversity
- 📦 **Batch Operations** - Efficient bulk insert/upsert
- 🔐 **Transaction Support** - ACID-compliant operations
- ⚡ **TypeScript** - Full type safety
- 🚀 **HNSW Index** - Fast approximate nearest neighbor search
- 🧠 **Internal Embeddings** - Use HANA's VECTOR_EMBEDDING function
- 🌐 **Knowledge Graph** - RDF/SPARQL support via HANARdfGraph

## Related Projects

This package is part of the SAP AI SDK ecosystem:

| Project | Language | Description |
|---------|----------|-------------|
| [@sap-ai-sdk/hana-vector](https://github.com/SAP/ai-sdk-js) | TypeScript | This package |
| [langchain-hana](https://github.com/SAP/langchain-integration-for-sap-hana-cloud) | Python | LangChain integration |
| [cap-llm-plugin](https://github.com/SAP/cap-llm-plugin) | JavaScript | CAP CDS plugin |

For shared SQL patterns, see [HANA Vector SQL Patterns](../../docs/HANA-VECTOR-SQL-PATTERNS.md).

## Installation

```bash
npm install @sap-ai-sdk/hana-vector @sap/hana-client
```

## Quick Start

```typescript
import { createHANAClient, createHANAVectorStore } from '@sap-ai-sdk/hana-vector';

// Create HANA client
const client = createHANAClient({
  host: 'd93a8739-44a8-4845-bef3-8ec724dea2ce.hana.prod-us10.hanacloud.ondemand.com',
  port: 443,
  user: 'DBADMIN',
  password: process.env.HANA_PASSWORD!,
  encrypt: true,
});

// Initialize client
await client.init();

// Create vector store
const vectorStore = createHANAVectorStore(client, {
  tableName: 'DOCUMENTS',
  embeddingDimensions: 1536, // OpenAI ada-002
});

// Ensure table exists
await vectorStore.ensureTable();

// Add documents
await vectorStore.addMany([
  {
    id: 'doc1',
    content: 'SAP HANA Cloud is a cloud-native database...',
    embedding: [0.1, 0.2, ...], // 1536 dimensions
    metadata: { source: 'docs', category: 'database' },
  },
]);

// Similarity search
const results = await vectorStore.similaritySearch(queryEmbedding, {
  k: 5,
  minScore: 0.7,
});
```

## Configuration

### From Environment Variables

```typescript
import { createHANAClientFromEnv } from '@sap-ai-sdk/hana-vector';

// Uses HANA_HOST, HANA_PORT, HANA_USER, HANA_PASSWORD, etc.
const client = createHANAClientFromEnv();
```

### From VCAP_SERVICES (BTP)

```typescript
import { getConfigFromVcap, createHANAClient } from '@sap-ai-sdk/hana-vector';

const config = getConfigFromVcap();
if (config) {
  const client = createHANAClient(config);
}
```

### Manual Configuration

```typescript
const client = createHANAClient({
  host: 'your-instance.hana.cloud.sap',
  port: 443,
  user: 'DBADMIN',
  password: 'your-password',
  schema: 'YOUR_SCHEMA',
  encrypt: true,
  sslValidateCertificate: true,
  connectTimeout: 30000,
  commandTimeout: 60000,
});
```

### Connection Pool Configuration

```typescript
const client = createHANAClient(config, {
  min: 2,        // Minimum connections
  max: 10,       // Maximum connections
  acquireTimeout: 30000,  // Wait timeout for connection
  idleTimeout: 60000,     // Idle connection timeout
});
```

## Vector Store Configuration

```typescript
const vectorStore = createHANAVectorStore(client, {
  tableName: 'DOCUMENTS',
  schemaName: 'AI_SCHEMA',       // Optional
  embeddingDimensions: 1536,     // Required
  idColumn: 'ID',                // Default: "ID"
  contentColumn: 'CONTENT',      // Default: "CONTENT"
  embeddingColumn: 'EMBEDDING',  // Default: "EMBEDDING"
  metadataColumn: 'METADATA',    // Default: "METADATA"
});
```

## Document Operations

### Add Documents

```typescript
// Single document
await vectorStore.add({
  id: 'doc1',
  content: 'Document content...',
  embedding: queryEmbedding,
  metadata: { source: 'web' },
});

// Multiple documents with progress
await vectorStore.addMany(documents, {
  batchSize: 500,
  onProgress: (completed, total) => {
    console.log(`${completed}/${total} documents added`);
  },
});
```

### Upsert Documents

```typescript
// Insert or update existing
await vectorStore.upsert(documents);
```

### Get Documents

```typescript
// Single document
const doc = await vectorStore.get('doc1');

// Multiple documents
const docs = await vectorStore.getMany(['doc1', 'doc2', 'doc3']);
```

### Delete Documents

```typescript
// Delete by IDs
await vectorStore.delete(['doc1', 'doc2']);

// Delete all
await vectorStore.clear();
```

## Similarity Search

### Basic Search

```typescript
const results = await vectorStore.similaritySearch(queryEmbedding, {
  k: 10,           // Number of results
  minScore: 0.5,   // Minimum similarity score
});

for (const doc of results) {
  console.log(`${doc.id}: ${doc.score.toFixed(3)} - ${doc.content.slice(0, 50)}...`);
}
```

### Search with Metadata Filter

```typescript
const results = await vectorStore.similaritySearch(queryEmbedding, {
  k: 10,
  filter: {
    source: 'documentation',
    category: 'api',
  },
});
```

### Different Distance Metrics

```typescript
// Cosine similarity (default)
const cosineResults = await vectorStore.similaritySearch(embedding, {
  metric: 'COSINE',
});

// Euclidean distance (converted to similarity)
const euclideanResults = await vectorStore.similaritySearch(embedding, {
  metric: 'EUCLIDEAN',
});

// Dot product
const dotResults = await vectorStore.similaritySearch(embedding, {
  metric: 'DOT_PRODUCT',
});
```

### Include Embeddings in Results

```typescript
const results = await vectorStore.similaritySearch(queryEmbedding, {
  k: 10,
  includeEmbeddings: true,
});

// Access embeddings
results[0].embedding; // number[]
```

## Advanced Search

### Maximum Marginal Relevance (MMR)

Balances relevance with diversity to avoid redundant results:

```typescript
const results = await vectorStore.maxMarginalRelevanceSearch(queryEmbedding, {
  k: 10,
  lambda: 0.5,    // 0 = max diversity, 1 = max relevance
  fetchK: 40,     // Initial candidates to fetch
});
```

### Hybrid Search

Combines vector similarity with keyword matching:

```typescript
const results = await vectorStore.hybridSearch(
  queryEmbedding,
  ['SAP', 'HANA', 'cloud'],
  {
    k: 10,
    vectorWeight: 0.7,    // Weight for vector similarity
    keywordWeight: 0.3,   // Weight for keyword matches
  }
);
```

## HANA Client Operations

### Direct Queries

```typescript
// SELECT query
const rows = await client.query<{ ID: string; NAME: string }>(
  'SELECT ID, NAME FROM USERS WHERE ACTIVE = ?',
  [true]
);

// INSERT/UPDATE/DELETE
const affected = await client.execute(
  'INSERT INTO LOGS (MESSAGE) VALUES (?)',
  ['User logged in']
);
```

### Batch Operations

```typescript
const affected = await client.executeBatch(
  'INSERT INTO ITEMS (ID, NAME) VALUES (?, ?)',
  [
    ['1', 'Item 1'],
    ['2', 'Item 2'],
    ['3', 'Item 3'],
  ]
);
```

### Transactions

```typescript
const result = await client.transaction(async (tx) => {
  await tx.execute('UPDATE ACCOUNTS SET BALANCE = BALANCE - ? WHERE ID = ?', [100, 'A']);
  await tx.execute('UPDATE ACCOUNTS SET BALANCE = BALANCE + ? WHERE ID = ?', [100, 'B']);
  
  const balances = await tx.query('SELECT ID, BALANCE FROM ACCOUNTS WHERE ID IN (?, ?)', ['A', 'B']);
  return balances;
});
```

### Schema Operations

```typescript
// Create table
await client.createTable({
  name: 'MY_TABLE',
  schema: 'MY_SCHEMA',
  columns: [
    { name: 'ID', type: 'NVARCHAR(255)', primaryKey: true },
    { name: 'VALUE', type: 'DECIMAL(10,2)', nullable: true },
  ],
  primaryKey: ['ID'],
});

// Check table exists
const exists = await client.tableExists('MY_TABLE', 'MY_SCHEMA');

// Get columns
const columns = await client.getTableColumns('MY_TABLE', 'MY_SCHEMA');

// Drop table
await client.dropTable('MY_TABLE', 'MY_SCHEMA');
```

## Error Handling

```typescript
import { HANAError, HANAErrorCode } from '@sap-ai-sdk/hana-vector';

try {
  await vectorStore.similaritySearch(embedding);
} catch (error) {
  if (error instanceof HANAError) {
    switch (error.code) {
      case HANAErrorCode.CONNECTION_FAILED:
        console.log('Connection failed:', error.message);
        break;
      case HANAErrorCode.TABLE_NOT_FOUND:
        console.log('Table not found, creating...');
        await vectorStore.createTable();
        break;
      case HANAErrorCode.AUTH_FAILED:
        console.log('Authentication failed');
        break;
      case HANAErrorCode.TIMEOUT:
        console.log('Query timeout');
        break;
      default:
        console.log(`Error ${error.sqlCode}: ${error.message}`);
    }
  }
}
```

## Utility Functions

```typescript
import {
  validateEmbedding,
  embeddingToVectorString,
  vectorStringToEmbedding,
  escapeIdentifier,
} from '@sap-ai-sdk/hana-vector';

// Validate embedding dimensions
validateEmbedding(embedding, 1536);

// Convert to HANA vector format
const vectorStr = embeddingToVectorString([0.1, 0.2, 0.3]);
// "[0.1,0.2,0.3]"

// Parse vector string
const embedding = vectorStringToEmbedding('[0.1,0.2,0.3]');
// [0.1, 0.2, 0.3]

// Escape identifier for SQL
const escaped = escapeIdentifier('MY_TABLE');
// "MY_TABLE"
```

## Use with RAG

```typescript
import { createHANAClient, createHANAVectorStore } from '@sap-ai-sdk/hana-vector';

async function rag(question: string) {
  // 1. Generate query embedding (using your embedding provider)
  const queryEmbedding = await generateEmbedding(question);
  
  // 2. Search for relevant documents
  const docs = await vectorStore.similaritySearch(queryEmbedding, {
    k: 5,
    minScore: 0.7,
  });
  
  // 3. Build context from retrieved documents
  const context = docs
    .map(d => d.content)
    .join('\n\n');
  
  // 4. Generate response with context
  const response = await llm.chat({
    messages: [
      { role: 'system', content: 'Answer based on the provided context.' },
      { role: 'user', content: `Context:\n${context}\n\nQuestion: ${question}` },
    ],
  });
  
  return {
    answer: response.content,
    sources: docs,
  };
}
```

## HNSW Index

Create an HNSW (Hierarchical Navigable Small World) index for fast approximate nearest neighbor search:

```typescript
// Create index with default settings
await vectorStore.createHnswIndex();

// Create index with custom configuration
await vectorStore.createHnswIndex({
  indexName: 'my_vector_index',
  m: 16,              // Max neighbors per node (4-1000)
  efConstruction: 200, // Build-time candidates (1-100000)
  efSearch: 100,       // Search-time candidates (1-100000)
  metric: 'COSINE',    // or 'EUCLIDEAN'
});

// Drop index
await vectorStore.dropHnswIndex('my_vector_index');
```

## Internal Embeddings (VECTOR_EMBEDDING)

Use HANA's built-in `VECTOR_EMBEDDING` function to generate embeddings directly in the database:

```typescript
// Validate internal embedding is available
const available = await vectorStore.validateInternalEmbedding({
  modelId: 'text-embedding-ada-002',
});

// Generate embedding for a single text
const embedding = await vectorStore.generateEmbedding(
  'Hello world',
  'QUERY',
  { modelId: 'text-embedding-ada-002' }
);

// Add texts with internal embeddings (no external embedding API needed)
await vectorStore.addTextsWithInternalEmbedding(
  [
    { id: 'doc1', content: 'First document...', metadata: { source: 'web' } },
    { id: 'doc2', content: 'Second document...' },
  ],
  { modelId: 'text-embedding-ada-002' },
  { batchSize: 100 }
);

// Search using internal embeddings (text → embedding → search, all in HANA)
const results = await vectorStore.similaritySearchWithInternalEmbedding(
  'What is SAP HANA?',
  { modelId: 'text-embedding-ada-002' },
  { k: 5, minScore: 0.7 }
);
```

## Knowledge Graph (RDF/SPARQL)

Query RDF graphs using SPARQL via HANA's Knowledge Graph Engine:

```typescript
import { createHANAClient, createHANARdfGraph } from '@sap-ai-sdk/hana-vector';

const client = createHANAClient(config);
await client.init();

// Create RDF graph instance
const graph = createHANARdfGraph(client, {
  graphUri: 'http://example.com/mygraph',
  autoExtractOntology: true,
});

// Execute SPARQL SELECT query
const { variables, results } = await graph.select(`
  SELECT ?subject ?predicate ?object
  WHERE { ?subject ?predicate ?object }
  LIMIT 10
`);

console.log('Variables:', variables);
for (const row of results) {
  console.log(row.subject, row.predicate, row.object);
}

// Execute SPARQL CONSTRUCT query
const triples = await graph.construct(`
  CONSTRUCT { ?s ?p ?o }
  FROM <http://example.com/ontology>
  WHERE { ?s ?p ?o }
`);

// Get ontology schema (classes and properties)
const schema = await graph.getSchema();
console.log('Classes:', schema.classes);
console.log('Properties:', schema.properties);
```

### RDF Graph Configuration

```typescript
const graph = createHANARdfGraph(client, {
  // Target graph URI (use '' or 'DEFAULT' for default graph)
  graphUri: 'http://example.com/graph',
  
  // Option 1: Custom SPARQL CONSTRUCT query for schema
  ontologyQuery: 'CONSTRUCT {...} WHERE {...}',
  
  // Option 2: Load schema from ontology graph URI
  ontologyUri: 'http://example.com/ontology',
  
  // Option 3: Auto-extract schema from instance data
  autoExtractOntology: true,
});
```

## HANA Vector Engine SQL Reference

The vector store uses these HANA Vector Engine SQL functions:

```sql
-- Create vector column
CREATE TABLE docs (
  ID NVARCHAR(255) PRIMARY KEY,
  CONTENT NCLOB,
  EMBEDDING REAL_VECTOR(1536),
  METADATA NCLOB
);

-- Insert with vector
INSERT INTO docs (ID, CONTENT, EMBEDDING) 
VALUES ('doc1', 'content', TO_REAL_VECTOR('[0.1,0.2,...]'));

-- Cosine similarity search
SELECT ID, CONTENT, COSINE_SIMILARITY(EMBEDDING, TO_REAL_VECTOR(?)) AS SCORE
FROM docs
WHERE COSINE_SIMILARITY(EMBEDDING, TO_REAL_VECTOR(?)) > 0.5
ORDER BY SCORE DESC
LIMIT 10;

-- Euclidean distance
SELECT ID, L2DISTANCE(EMBEDDING, TO_REAL_VECTOR(?)) AS DISTANCE
FROM docs
ORDER BY DISTANCE ASC
LIMIT 10;
```

## License

Apache-2.0