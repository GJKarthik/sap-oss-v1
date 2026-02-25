# Elasticsearch RAG Pipeline Sample

This sample demonstrates a complete Retrieval-Augmented Generation (RAG) pipeline using Elasticsearch as the vector store.

## Features

- 📥 **Document Ingestion** - Chunk and index documents with embeddings
- 🔍 **Vector Search** - Semantic search using kNN
- 🔄 **Hybrid Search** - Combine vector and text search
- 🤖 **RAG Pipeline** - Ground queries with relevant context
- 📊 **Interactive Mode** - Real-time query interface

## Prerequisites

- Docker and Docker Compose
- Node.js 18+
- pnpm (recommended) or npm

## Quick Start

### 1. Install Dependencies

```bash
pnpm install
# or
npm install
```

### 2. Start Elasticsearch

```bash
npm run setup
```

This starts Elasticsearch and waits for it to be ready.

### 3. Ingest Sample Documents

```bash
npm run ingest
```

This loads 10 sample documents about RAG, vector search, and related topics.

### 4. Run Queries

```bash
npm run query
```

This runs several sample RAG queries and displays results.

## Available Scripts

| Script | Description |
|--------|-------------|
| `npm run setup` | Start Elasticsearch |
| `npm run ingest` | Ingest sample documents |
| `npm run query` | Run sample RAG queries |
| `npm run demo` | Run complete demo (setup → ingest → query) |
| `npm run hybrid` | Hybrid search demonstration |
| `npm run interactive` | Interactive query mode |
| `npm run pipeline` | Custom RAG pipeline example |
| `npm run stop` | Stop Elasticsearch |
| `npm run clean` | Stop and remove data |

## Project Structure

```
elasticsearch-rag/
├── docker-compose.yml     # Elasticsearch setup
├── package.json           # Project configuration
├── README.md              # This file
└── src/
    ├── ingest-documents.ts   # Document ingestion
    ├── query-rag.ts          # RAG query pipeline
    ├── hybrid-search-demo.ts # Search comparison
    └── custom-pipeline.ts    # Advanced pipeline
```

## Examples

### Document Ingestion

```typescript
import {
  createElasticsearchClient,
  createVectorStore,
  createChunker,
} from '@sap-ai-sdk/elasticsearch';

// Create client and vector store
const client = createElasticsearchClient({
  node: 'http://localhost:9200',
  indexName: 'knowledge-base',
  embeddingDims: 384,
});

const vectorStore = await createVectorStore(client, 'knowledge-base', {
  embeddingDimension: 384,
  similarity: 'cosine',
});

// Chunk document
const chunker = createChunker({ chunkSize: 500, chunkOverlap: 50 });
const chunks = chunker.chunk(longDocument);

// Index with embeddings
const documents = chunks.map((chunk, i) => ({
  id: `doc-${i}`,
  content: chunk.text,
  embedding: generateEmbedding(chunk.text),
  metadata: { source: 'demo' },
}));

await vectorStore.upsertDocuments(documents);
```

### RAG Query

```typescript
import {
  createGroundingModule,
  createContextBuilder,
  PromptTemplates,
} from '@sap-ai-sdk/elasticsearch';

// Create grounding module
const grounding = createGroundingModule(client, 'knowledge-base', {
  embedFn: async (text) => generateEmbedding(text),
  defaultOptions: { topK: 5, minScore: 0.5 },
});

// Ground the query
const result = await grounding.ground('What is RAG?');

// Build context
const contextBuilder = createContextBuilder({
  maxContextLength: 4000,
  referenceFormat: 'numbered',
});
const context = contextBuilder.build(result);

// Build prompt
const prompt = PromptTemplates.qaWithSources.build('What is RAG?', context);
console.log(prompt.system);
console.log(prompt.user);
```

### Hybrid Search

```typescript
import { createHybridSearch } from '@sap-ai-sdk/elasticsearch';

const search = createHybridSearch()
  .knn('embedding', queryEmbedding, 10, { numCandidates: 50 })
  .text('content', 'vector search')
  .filter({ term: { 'metadata.category': 'ai' } })
  .withRrf(60)
  .paginate(0, 10);

const query = search.build();
const results = await client.search({ index: 'knowledge-base', ...query });
```

## Sample Knowledge Base

The sample includes 10 documents covering:

| Topic | Description |
|-------|-------------|
| Introduction to RAG | Overview of retrieval-augmented generation |
| Vector Search | How semantic search works |
| Elasticsearch kNN | Using Elasticsearch for vector search |
| Hybrid Search | Combining vector and text search |
| Text Chunking | Document processing strategies |
| Embedding Models | Available embedding options |
| Context Windows | Managing LLM context limits |
| Query Expansion | Improving query quality |
| Reranking | Second-stage retrieval |
| Evaluation Metrics | Measuring RAG performance |

## Configuration

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `ES_URL` | `http://localhost:9200` | Elasticsearch URL |
| `INDEX_NAME` | `knowledge-base` | Index name |

### .env File

Create a `.env` file for custom configuration:

```bash
ES_URL=http://localhost:9200
INDEX_NAME=my-knowledge-base
```

## Docker Compose Services

### Elasticsearch

- Image: `elasticsearch:8.11.0`
- Port: `9200`
- Memory: 1GB
- Security: Disabled (for demo)

### Kibana (Optional)

To start with Kibana for visualization:

```bash
npm run start:kibana
```

Access Kibana at http://localhost:5601

## Troubleshooting

### Elasticsearch won't start

```bash
# Check Docker logs
docker logs es-rag-demo

# Increase Docker memory (minimum 2GB recommended)
# Check Docker Desktop settings
```

### Connection refused

```bash
# Wait for Elasticsearch to be ready
npm run wait:es

# Check if Elasticsearch is running
curl http://localhost:9200/_cluster/health
```

### No search results

```bash
# Ensure documents are indexed
npm run ingest

# Check document count
curl http://localhost:9200/knowledge-base/_count
```

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                      RAG Pipeline                            │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  ┌─────────┐    ┌─────────┐    ┌─────────┐    ┌─────────┐  │
│  │  Query  │───▶│ Embed   │───▶│ Search  │───▶│ Ground  │  │
│  └─────────┘    └─────────┘    └─────────┘    └─────────┘  │
│                                      │              │       │
│                                      │              ▼       │
│                               ┌──────┴──────┐  ┌─────────┐  │
│                               │Elasticsearch│  │ Context │  │
│                               │ Vector Store│  │ Builder │  │
│                               └─────────────┘  └────┬────┘  │
│                                                     │       │
│                                                     ▼       │
│                                               ┌─────────┐   │
│                                               │  LLM    │   │
│                                               │ Prompt  │   │
│                                               └─────────┘   │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

## Next Steps

1. **Use real embeddings** - Replace simulated embeddings with OpenAI, Sentence Transformers, or other models
2. **Add more documents** - Expand the knowledge base with your own content
3. **Integrate with LLM** - Connect to GPT-4, Claude, or local models for generation
4. **Deploy to production** - Use Elastic Cloud or self-hosted cluster
5. **Add authentication** - Enable Elasticsearch security features

## Related Samples

- [elasticsearch-cloud](../elasticsearch-cloud) - Elastic Cloud deployment
- [vllm-local](../vllm-local) - vLLM local development

## License

Apache-2.0