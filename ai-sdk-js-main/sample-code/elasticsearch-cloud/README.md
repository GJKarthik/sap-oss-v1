# Elastic Cloud Deployment Sample

This sample demonstrates deploying a production-ready vector search and RAG application using [Elastic Cloud](https://cloud.elastic.co/).

## Features

- ☁️ **Cloud-Native** - Fully managed Elasticsearch on AWS, Azure, or GCP
- 🔐 **Secure** - API key and TLS encryption by default
- 🔍 **Vector Search** - Dense vector storage with kNN search
- 🔄 **Hybrid Search** - Combine vector and text search
- 📊 **Scalable** - Auto-scaling with Elastic Cloud
- 🤖 **RAG Pipeline** - Complete retrieval-augmented generation

## Prerequisites

1. **Elastic Cloud Account** - [Sign up for free trial](https://cloud.elastic.co/registration)
2. **Node.js 18+**
3. **npm or pnpm**

## Quick Start

### 1. Create Elastic Cloud Deployment

1. Go to [Elastic Cloud Console](https://cloud.elastic.co/)
2. Click "Create Deployment"
3. Choose your cloud provider (AWS/Azure/GCP)
4. Select a region close to your users
5. Choose a deployment size (start with "Memory Optimized" for vector search)
6. Note the **Cloud ID** shown after creation

### 2. Create API Key

1. Open Kibana (click "Launch" in the console)
2. Go to **Stack Management** → **API Keys**
3. Click "Create API Key"
4. Name it (e.g., "rag-pipeline")
5. Set permissions (use "Superuser" for testing)
6. Copy the generated API key

### 3. Configure Environment

```bash
# Copy example env file
cp .env.example .env

# Edit with your credentials
nano .env
```

Set these required values:
```
ELASTIC_CLOUD_ID=your-deployment:base64...
ELASTIC_API_KEY=your-api-key
```

### 4. Install Dependencies

```bash
npm install
# or
pnpm install
```

### 5. Test Connection

```bash
npm run test:connection
```

### 6. Setup Index

```bash
npm run setup
```

### 7. Run RAG Pipeline

```bash
npm run rag
```

## Available Scripts

| Script | Description |
|--------|-------------|
| `npm run test:connection` | Test connection to Elastic Cloud |
| `npm run verify:config` | Verify configuration without connecting |
| `npm run setup` | Create vector index |
| `npm run ingest` | Ingest sample documents |
| `npm run query` | Run queries against the index |
| `npm run rag` | Run complete RAG pipeline |
| `npm run demo` | Run complete demo (setup → ingest → query) |
| `npm run create:api-key` | Helper to create API keys |

## Project Structure

```
elasticsearch-cloud/
├── .env.example           # Environment template
├── .env                   # Your configuration (not in git)
├── package.json           # Project configuration
├── README.md              # This file
└── src/
    ├── config.ts          # Configuration loading
    ├── test-connection.ts # Connection testing
    ├── setup-index.ts     # Index creation
    └── rag-pipeline.ts    # Complete RAG demo
```

## Configuration Reference

### Required

| Variable | Description |
|----------|-------------|
| `ELASTIC_CLOUD_ID` | Cloud ID from Elastic Cloud console |
| `ELASTIC_API_KEY` | API key for authentication |

### Alternative Authentication

| Variable | Description |
|----------|-------------|
| `ELASTIC_USERNAME` | Username (usually 'elastic') |
| `ELASTIC_PASSWORD` | Password from deployment |

### Optional

| Variable | Default | Description |
|----------|---------|-------------|
| `INDEX_NAME` | `knowledge-base` | Index name for vectors |
| `EMBEDDING_DIMENSION` | `1536` | Embedding dimension |
| `SIMILARITY` | `cosine` | Similarity metric |
| `REQUEST_TIMEOUT` | `30000` | Request timeout (ms) |
| `MAX_RETRIES` | `3` | Max retry attempts |
| `DEBUG` | `false` | Enable debug logging |

## Elastic Cloud Setup Guide

### Choosing Deployment Size

| Use Case | Recommended Size | Notes |
|----------|------------------|-------|
| Development | 2GB Memory | Good for testing |
| Small Production | 8GB Memory | Up to 1M vectors |
| Medium Production | 32GB Memory | Up to 10M vectors |
| Large Production | 64GB+ Memory | 10M+ vectors |

### Recommended Settings

For vector search workloads:

1. **Hardware Profile**: Memory Optimized
2. **Version**: 8.x (latest)
3. **Auto-scale**: Enable for production
4. **Backups**: Enable for production

### Deployment Regions

Choose a region close to your users:

**AWS:**
- us-east-1 (N. Virginia)
- us-west-2 (Oregon)
- eu-west-1 (Ireland)
- ap-southeast-1 (Singapore)

**Azure:**
- eastus
- westeurope
- southeastasia

**GCP:**
- us-central1
- europe-west1
- asia-southeast1

## Security Best Practices

### API Key Permissions

For production, create API keys with minimal permissions:

```json
{
  "names": ["knowledge-base-*"],
  "privileges": ["read", "write", "create_index", "manage"]
}
```

### Environment Variables

Never commit `.env` files to git:
```gitignore
.env
.env.local
.env.production
```

### TLS/SSL

Elastic Cloud uses TLS by default. No additional configuration needed.

## Integration with SAP

### Using with SAP AI SDK

```typescript
import { createElasticsearchClient } from '@sap-ai-sdk/elasticsearch';

const client = createElasticsearchClient({
  cloud: { id: process.env.ELASTIC_CLOUD_ID },
  auth: { apiKey: process.env.ELASTIC_API_KEY },
  indexName: 'knowledge-base',
  embeddingDims: 1536,
});
```

### Using with SAP Generative AI Hub

```typescript
import { AzureOpenAI } from '@sap-ai-sdk/ai-api';

// Use AI Hub embeddings
const embedding = await aiHub.embed({
  input: 'Your text here',
  model: 'text-embedding-ada-002',
});

// Index in Elasticsearch
await vectorStore.upsertDocuments([{
  id: 'doc-1',
  content: 'Your text here',
  embedding: embedding.data[0].embedding,
}]);
```

## Monitoring

### Kibana Stack Monitoring

1. Open Kibana
2. Go to **Stack Monitoring**
3. View cluster health, indices, and search metrics

### Key Metrics

- **Search Latency**: Should be < 100ms for vector search
- **Indexing Rate**: Bulk indexing throughput
- **Memory Usage**: Watch for memory pressure
- **Shard Count**: Keep reasonable (< 20 per GB heap)

## Cost Optimization

### Tips for Reducing Costs

1. **Use appropriate sizing** - Start small, scale up
2. **Delete unused indices** - Old test data
3. **Snapshot to cold storage** - Historical data
4. **Reserved pricing** - For stable workloads

### Estimated Costs

| Size | Approximate Cost |
|------|------------------|
| 2GB Dev | ~$50/month |
| 8GB Small | ~$200/month |
| 32GB Medium | ~$800/month |

*Costs vary by region and cloud provider*

## Troubleshooting

### Connection Issues

```bash
# Check configuration
npm run verify:config

# Test connection with verbose output
DEBUG=true npm run test:connection
```

### Authentication Errors

1. Verify API key is valid and not expired
2. Check API key has required permissions
3. Ensure Cloud ID is correct

### Performance Issues

1. Check cluster health in Kibana
2. Review shard count (should be 1 per index for small deployments)
3. Verify embedding dimension matches index mapping

### Common Errors

| Error | Solution |
|-------|----------|
| `ConnectionError` | Check Cloud ID and network |
| `AuthenticationException` | Verify API key |
| `index_not_found_exception` | Run `npm run setup` |
| `400 mapper_parsing_exception` | Check embedding dimension |

## Resources

- [Elastic Cloud Documentation](https://www.elastic.co/guide/en/cloud/current/index.html)
- [Elasticsearch Vector Search](https://www.elastic.co/guide/en/elasticsearch/reference/current/dense-vector.html)
- [SAP AI SDK Documentation](https://github.com/SAP/ai-sdk-js)

## License

Apache-2.0