# Integration Review: langchain-integration-for-sap-hana-cloud ↔ ai-sdk-js

**Review Date:** 2026-02-25  
**Reviewer:** Architecture Review  
**Status:** Complete

---

## Executive Summary

| Metric | Rating |
|--------|--------|
| **Integration Potential** | ⭐⭐⭐⭐☆ (4/5) |
| **Current Integration** | ❌ None (but architecturally compatible) |
| **Quality Score** | 7/10 (as an integration pair) |
| **Recommended Priority** | **High** |
| **Effort to Integrate** | Medium (shared interfaces exist) |

**Verdict:** These projects are highly complementary and share the LangChain abstraction layer. Integration would create a powerful full-stack SAP AI solution combining HANA Vector Engine with SAP AI Core. Recommended for implementation.

---

## 1. Project Profiles

### 1.1 langchain-integration-for-sap-hana-cloud

| Attribute | Value |
|-----------|-------|
| **Language** | Python |
| **Primary Purpose** | LangChain components for SAP HANA Cloud Vector Engine |
| **Core Framework** | LangChain, hdbcli, numpy |
| **Key Components** | `HanaDB`, `HanaInternalEmbeddings`, `HanaRdfGraph`, `HanaSparqlQAChain` |
| **Vector Support** | `REAL_VECTOR`, `HALF_VECTOR` (QRC 2/2025+) |
| **AI Integration** | HANA internal embeddings via `VECTOR_EMBEDDING()` function |

**Architecture Highlights:**
- **VectorStore Implementation:** `HanaDB` extends `langchain_core.vectorstores.VectorStore`
- **Embedding Abstraction:** Supports both external embeddings and HANA's internal `VECTOR_EMBEDDING()`
- **Distance Strategies:** `COSINE_SIMILARITY`, `L2DISTANCE`
- **Advanced Features:** HNSW index creation, MMR search, metadata filtering, keyword search

```python
# From hana_db.py
class HanaDB(VectorStore):
    def __init__(
        self,
        connection: dbapi.Connection,
        embedding: Embeddings,  # LangChain Embeddings interface
        distance_strategy: DistanceStrategy = default_distance_strategy,
        table_name: str = default_table_name,
        ...
    )
```

### 1.2 ai-sdk-js

| Attribute | Value |
|-----------|-------|
| **Language** | TypeScript/JavaScript |
| **Primary Purpose** | SAP AI Core SDK with LangChain integration |
| **Core Framework** | LangChain.js, SAP Cloud SDK |
| **Key Packages** | `@sap-ai-sdk/langchain`, `@sap-ai-sdk/foundation-models`, `@sap-ai-sdk/orchestration` |
| **LangChain Components** | `AzureOpenAiChatClient`, `AzureOpenAiEmbeddingClient`, `OrchestrationClient` |
| **AI Integration** | SAP AI Core / Generative AI Hub |

**Architecture Highlights:**
- **LangChain Integration:** Chat and Embedding clients implement `@langchain/core` interfaces
- **Orchestration:** Full orchestration capabilities with content filtering, grounding
- **Model Support:** Azure OpenAI models via SAP AI Core deployments
- **Enterprise Ready:** BTP destination support, resource groups, model versioning

```typescript
// From embedding.ts
export class AzureOpenAiEmbeddingClient extends Embeddings {
  override async embedDocuments(documents: string[]): Promise<number[][]> {
    return (await this.createEmbeddings({ input: documents })).getEmbeddings();
  }

  override async embedQuery(input: string): Promise<number[]> {
    return (await this.createEmbeddings({ input })).getEmbedding() ?? [];
  }
}
```

---

## 2. Technical Compatibility Analysis

### 2.1 Shared Abstraction: LangChain Interfaces

| Interface | langchain-hana (Python) | ai-sdk-js (TypeScript) |
|-----------|------------------------|------------------------|
| `Embeddings` | ✅ `HanaInternalEmbeddings` accepts any `Embeddings` | ✅ `AzureOpenAiEmbeddingClient extends Embeddings` |
| `VectorStore` | ✅ `HanaDB extends VectorStore` | ❌ Not implemented (focus is on AI Core) |
| `BaseChatModel` | ❌ Uses external | ✅ `AzureOpenAiChatClient extends BaseChatModel` |
| `Document` | ✅ Returns `langchain_core.documents.Document` | ✅ Uses `@langchain/core` Document |

**Gap Assessment:** 🟢 **Strong** - Both implement LangChain core interfaces.

### 2.2 Interface Compatibility Matrix

```
┌─────────────────────────────────────────────────────────────────────┐
│                     LangChain Abstraction Layer                      │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  ┌─────────────────────┐         ┌─────────────────────┐           │
│  │  langchain-hana     │         │  ai-sdk-js          │           │
│  │  (Python)           │         │  (TypeScript)       │           │
│  ├─────────────────────┤         ├─────────────────────┤           │
│  │ • HanaDB            │ ◄─────► │ • AzureOpenAi       │           │
│  │   (VectorStore)     │   API   │   EmbeddingClient   │           │
│  │                     │         │   (Embeddings)      │           │
│  │ • HanaInternal      │         │                     │           │
│  │   Embeddings        │         │ • AzureOpenAi       │           │
│  │   (Embeddings)      │         │   ChatClient        │           │
│  │                     │         │   (BaseChatModel)   │           │
│  │ • HanaSparqlQA      │         │                     │           │
│  │   Chain             │         │ • Orchestration     │           │
│  │                     │         │   Client            │           │
│  └─────────────────────┘         └─────────────────────┘           │
│           │                               │                         │
│           ▼                               ▼                         │
│  ┌─────────────────────┐         ┌─────────────────────┐           │
│  │ SAP HANA Cloud      │         │ SAP AI Core         │           │
│  │ Vector Engine       │         │ Generative AI Hub   │           │
│  └─────────────────────┘         └─────────────────────┘           │
└─────────────────────────────────────────────────────────────────────┘
```

### 2.3 Data Flow Compatibility

| Operation | langchain-hana | ai-sdk-js | Compatible |
|-----------|---------------|-----------|------------|
| Generate Embedding | `embedding.embed_query(text)` → `List[float]` | `embedDocuments(docs)` → `number[][]` | ✅ Yes |
| Store Vector | `hanadb.add_texts(texts, embeddings=vectors)` | N/A | ✅ Can provide |
| Similarity Search | `hanadb.similarity_search(query, k)` → `List[Document]` | N/A | ✅ Returns Documents |
| Chat Completion | External | `chatClient.invoke(messages)` | ✅ Standard format |
| RAG Pipeline | Manual orchestration | Orchestration service | ✅ Complementary |

**Gap Assessment:** 🟢 **Excellent** - Data types align across language boundary.

---

## 3. Integration Opportunities

### 3.1 Opportunity: Cross-Language RAG Pipeline

**Concept:** Use ai-sdk-js for embeddings/chat, langchain-hana for vector storage.

**Architecture:**
```
┌─────────────────────────────────────────────────────────────────┐
│                    Full-Stack RAG Architecture                   │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  ┌──────────────┐     ┌──────────────┐     ┌──────────────┐    │
│  │   Frontend   │────►│   Backend    │────►│   Backend    │    │
│  │   (Any)      │     │   Node.js    │     │   Python     │    │
│  └──────────────┘     └──────────────┘     └──────────────┘    │
│                              │                    │             │
│                              ▼                    ▼             │
│                       ┌──────────────┐     ┌──────────────┐    │
│                       │  ai-sdk-js   │     │ langchain-   │    │
│                       │  langchain   │     │ hana         │    │
│                       ├──────────────┤     ├──────────────┤    │
│                       │ • Embedding  │     │ • HanaDB     │    │
│                       │ • Chat       │     │   VectorStore│    │
│                       │ • Orchestr.  │     │ • Similarity │    │
│                       └──────────────┘     │   Search     │    │
│                              │             └──────────────┘    │
│                              ▼                    │             │
│                       ┌──────────────┐           │             │
│                       │ SAP AI Core  │           │             │
│                       │ GPT-4/etc    │           │             │
│                       └──────────────┘           │             │
│                                                  ▼             │
│                                           ┌──────────────┐    │
│                                           │ SAP HANA     │    │
│                                           │ Cloud        │    │
│                                           └──────────────┘    │
└─────────────────────────────────────────────────────────────────┘
```

**Implementation Pattern:**

```typescript
// Node.js Backend - ai-sdk-js
import { AzureOpenAiEmbeddingClient } from '@sap-ai-sdk/langchain';

const embeddingClient = new AzureOpenAiEmbeddingClient({
  modelName: 'text-embedding-ada-002',
  resourceGroup: 'default'
});

// Generate embeddings
const vectors = await embeddingClient.embedDocuments(documents);

// Send to Python service for HANA storage
await fetch('http://python-service/store', {
  method: 'POST',
  body: JSON.stringify({ documents, vectors })
});
```

```python
# Python Backend - langchain-hana
from langchain_hana import HanaDB
from hdbcli import dbapi

connection = dbapi.connect(...)
vectorstore = HanaDB(
    connection=connection,
    embedding=DummyEmbedding(),  # Vectors provided externally
    table_name="DOCUMENT_EMBEDDINGS"
)

# Store pre-computed embeddings
vectorstore.add_texts(documents, embeddings=vectors)

# Later: similarity search
results = vectorstore.similarity_search_by_vector(query_vector, k=5)
```

**Value Assessment:**
- ✅ Best-of-breed: AI Core for LLMs, HANA for vectors
- ✅ Enterprise-grade security via BTP destinations
- ✅ Leverages existing SAP infrastructure
- ❌ Cross-service communication overhead
- ❌ Two runtimes to maintain

**Effort:** Medium (2-3 weeks)  
**Value:** High

### 3.2 Opportunity: Shared REST API Contract

**Concept:** Define a common REST API that both projects can implement/consume.

**OpenAPI Specification:**
```yaml
openapi: 3.0.0
info:
  title: SAP LangChain Integration API
  version: 1.0.0

paths:
  /embeddings:
    post:
      summary: Generate embeddings
      requestBody:
        content:
          application/json:
            schema:
              type: object
              properties:
                texts:
                  type: array
                  items:
                    type: string
                model:
                  type: string
      responses:
        '200':
          content:
            application/json:
              schema:
                type: object
                properties:
                  embeddings:
                    type: array
                    items:
                      type: array
                      items:
                        type: number

  /vectorstore/add:
    post:
      summary: Add documents to vector store
      requestBody:
        content:
          application/json:
            schema:
              type: object
              properties:
                texts:
                  type: array
                  items:
                    type: string
                embeddings:
                  type: array
                  items:
                    type: array
                    items:
                      type: number
                metadatas:
                  type: array
                  items:
                    type: object

  /vectorstore/search:
    post:
      summary: Similarity search
      requestBody:
        content:
          application/json:
            schema:
              type: object
              properties:
                query_embedding:
                  type: array
                  items:
                    type: number
                k:
                  type: integer
                filter:
                  type: object
      responses:
        '200':
          content:
            application/json:
              schema:
                type: object
                properties:
                  documents:
                    type: array
                    items:
                      type: object
                      properties:
                        page_content:
                          type: string
                        metadata:
                          type: object
                        score:
                          type: number
```

**Value Assessment:**
- ✅ Language-agnostic integration
- ✅ Can be implemented by either project
- ✅ Enables microservices architecture
- ❌ Additional API layer to maintain
- ❌ Serialization overhead for large vectors

**Effort:** Medium (2-3 weeks)  
**Value:** High

### 3.3 Opportunity: Unified TypeScript SDK

**Concept:** Create `@sap-ai-sdk/hana-vectorstore` package in ai-sdk-js.

**Implementation:**
```typescript
// New package: @sap-ai-sdk/hana-vectorstore
import { VectorStore } from '@langchain/core/vectorstores';
import { Embeddings } from '@langchain/core/embeddings';
import { Document } from '@langchain/core/documents';
import * as hana from '@sap/hana-client';

export class HanaVectorStore extends VectorStore {
  private connection: hana.Connection;
  
  constructor(
    embeddings: Embeddings,
    config: {
      connection: hana.Connection;
      tableName?: string;
      contentColumn?: string;
      vectorColumn?: string;
      metadataColumn?: string;
      distanceStrategy?: 'cosine' | 'l2';
    }
  ) {
    super(embeddings, config);
    this.connection = config.connection;
  }

  async addDocuments(documents: Document[]): Promise<void> {
    const texts = documents.map(d => d.pageContent);
    const metadatas = documents.map(d => d.metadata);
    const embeddings = await this.embeddings.embedDocuments(texts);
    
    // Insert into HANA
    const stmt = this.connection.prepare(`
      INSERT INTO "${this.tableName}" 
      ("${this.contentColumn}", "${this.metadataColumn}", "${this.vectorColumn}")
      VALUES (?, ?, TO_REAL_VECTOR(?))
    `);
    
    for (let i = 0; i < texts.length; i++) {
      stmt.exec([texts[i], JSON.stringify(metadatas[i]), `[${embeddings[i].join(',')}]`]);
    }
  }

  async similaritySearchVectorWithScore(
    query: number[],
    k: number,
    filter?: Record<string, any>
  ): Promise<[Document, number][]> {
    const sql = `
      SELECT TOP ${k}
        "${this.contentColumn}",
        "${this.metadataColumn}",
        COSINE_SIMILARITY("${this.vectorColumn}", TO_REAL_VECTOR(?)) AS score
      FROM "${this.tableName}"
      ORDER BY score DESC
    `;
    
    const results = this.connection.exec(sql, [`[${query.join(',')}]`]);
    return results.map(row => [
      new Document({
        pageContent: row[this.contentColumn],
        metadata: JSON.parse(row[this.metadataColumn])
      }),
      row.score
    ]);
  }
}
```

**Value Assessment:**
- ✅ Single language (TypeScript) for full stack
- ✅ Native integration with ai-sdk-js embedding clients
- ✅ Simpler deployment (one runtime)
- ❌ Duplicates langchain-hana functionality
- ❌ Requires HANA Node.js driver support
- ❌ May diverge from Python implementation

**Effort:** High (4-6 weeks)  
**Value:** Medium-High

### 3.4 Opportunity: Document Grounding Integration

**Concept:** Use ai-sdk-js's `@sap-ai-sdk/document-grounding` with HANA vectors.

**Current ai-sdk-js Architecture:**
```
packages/
├── document-grounding/    # SAP Document Grounding service
├── foundation-models/     # Azure OpenAI via AI Core
├── langchain/             # LangChain wrappers
└── orchestration/         # Orchestration service
```

**Integration Point:**
```typescript
// Extended grounding with HANA vector retrieval
import { DocumentGroundingClient } from '@sap-ai-sdk/document-grounding';
import { HanaVectorStore } from '@sap-ai-sdk/hana-vectorstore';

class HybridGroundingClient {
  private documentGrounding: DocumentGroundingClient;
  private hanaVectorStore: HanaVectorStore;

  async groundWithHana(query: string, options: {
    useDocumentGrounding?: boolean;
    useHanaVectors?: boolean;
    k?: number;
  }): Promise<Document[]> {
    const results: Document[] = [];
    
    if (options.useDocumentGrounding) {
      const dgResults = await this.documentGrounding.retrieve(query);
      results.push(...dgResults);
    }
    
    if (options.useHanaVectors) {
      const hanaResults = await this.hanaVectorStore.similaritySearch(query, options.k);
      results.push(...hanaResults);
    }
    
    return this.deduplicate(results);
  }
}
```

**Value Assessment:**
- ✅ Unified grounding from multiple sources
- ✅ Leverages both SAP services
- ❌ Complex orchestration logic
- ❌ Requires careful result merging

**Effort:** High (3-4 weeks)  
**Value:** Medium

---

## 4. Quality Assessment

### 4.1 Individual Project Scores

| Criterion | langchain-hana | ai-sdk-js |
|-----------|---------------|-----------|
| Code Quality | 8/10 | 9/10 |
| Documentation | 7/10 | 8/10 |
| Test Coverage | 6/10 | 8/10 |
| Type Safety | 7/10 (Python typing) | 9/10 (TypeScript) |
| API Design | 8/10 | 9/10 |
| Extensibility | 8/10 | 8/10 |
| LangChain Compliance | 9/10 | 9/10 |
| SAP Integration | 9/10 (HANA) | 9/10 (AI Core) |
| **Average** | **7.8/10** | **8.6/10** |

### 4.2 Integration Quality Score

| Criterion | Score | Notes |
|-----------|-------|-------|
| Architectural Fit | 8/10 | Both use LangChain abstractions |
| Semantic Overlap | 7/10 | Embeddings interface is identical |
| Technical Readiness | 6/10 | Need API bridge or shared package |
| Value Proposition | 9/10 | Creates complete SAP AI stack |
| Implementation Effort | 6/10 | Medium effort, clear path |
| **Integration Score** | **7/10** | **Recommended** |

---

## 5. Implementation Roadmap

### Phase 1: API Contract (Week 1-2)

| Day | Task | Deliverable |
|-----|------|-------------|
| 1-2 | Define OpenAPI spec for embedding/vectorstore operations | `api-spec.yaml` |
| 3-4 | Implement Python FastAPI service wrapping langchain-hana | `hana-vector-service/` |
| 5 | Implement TypeScript client in ai-sdk-js | `packages/hana-client/` |
| 6-7 | Integration tests: ai-sdk-js → Python service → HANA | `tests/integration/` |
| 8-10 | Documentation and examples | `docs/hana-integration.md` |

### Phase 2: Native TypeScript Package (Week 3-4) [Optional]

| Day | Task | Deliverable |
|-----|------|-------------|
| 11-13 | Port `HanaDB` core to TypeScript | `packages/hana-vectorstore/` |
| 14-16 | Implement HANA Node.js driver integration | Driver wrapper |
| 17-18 | Unit tests for TypeScript implementation | 80% coverage |
| 19-20 | Performance comparison: Python vs TypeScript | Benchmark report |

### Phase 3: Orchestration Integration (Week 5-6)

| Day | Task | Deliverable |
|-----|------|-------------|
| 21-23 | Create `HanaGroundingFilter` for orchestration | Grounding adapter |
| 24-26 | Integrate with `@sap-ai-sdk/orchestration` | Orchestration support |
| 27-28 | End-to-end RAG example with all components | Sample application |
| 29-30 | Final documentation and release prep | Release candidate |

---

## 6. Risk Assessment

| Risk | Probability | Impact | Mitigation |
|------|-------------|--------|------------|
| HANA Node.js driver limitations | Medium | High | Start with Python service, evaluate driver |
| Vector format incompatibility | Low | Medium | Use standard float arrays, test early |
| Performance overhead (cross-service) | Medium | Medium | Batch operations, connection pooling |
| Maintenance burden (two implementations) | High | Medium | Designate Python as reference impl |
| LangChain version drift | Medium | Medium | Pin versions, monitor releases |

---

## 7. Recommendations

### 7.1 Recommended: Pursue Integration

**Rationale:**
- High synergy between HANA Vector Engine and SAP AI Core
- LangChain provides stable abstraction layer
- Clear customer value: enterprise RAG with SAP infrastructure
- Moderate implementation effort with high return

### 7.2 Implementation Priority

1. **Immediate (Week 1-2):** REST API contract + Python service
2. **Short-term (Week 3-4):** Evaluate TypeScript native implementation
3. **Medium-term (Week 5-6):** Orchestration integration

### 7.3 Success Metrics

| Metric | Target |
|--------|--------|
| Integration test coverage | ≥80% |
| Latency overhead | <50ms per operation |
| Documentation completeness | All APIs documented |
| Sample applications | ≥2 working examples |
| User adoption | ≥3 teams using integration |

---

## 8. Appendix: Code Evidence

### 8.1 langchain-hana Embeddings Interface

From `langchain_hana/vectorstores/hana_db.py`:
```python
class HanaDB(VectorStore):
    def __init__(
        self,
        connection: dbapi.Connection,
        embedding: Embeddings,  # Accepts any LangChain Embeddings
        distance_strategy: DistanceStrategy = default_distance_strategy,
        ...
    ):
        # Configure the embedding (internal or external)
        self.embedding: Embeddings
        self.set_embedding(embedding)
```

### 8.2 ai-sdk-js Embeddings Implementation

From `ai-sdk-js/packages/langchain/src/openai/embedding.ts`:
```typescript
export class AzureOpenAiEmbeddingClient extends Embeddings {
  override async embedDocuments(documents: string[]): Promise<number[][]> {
    return (await this.createEmbeddings({ input: documents })).getEmbeddings();
  }

  override async embedQuery(input: string): Promise<number[]> {
    return (await this.createEmbeddings({ input })).getEmbedding() ?? [];
  }
}
```

### 8.3 Shared LangChain Types

Both projects use the same core types:

```python
# Python (langchain_core)
from langchain_core.documents import Document
from langchain_core.embeddings import Embeddings
from langchain_core.vectorstores import VectorStore
```

```typescript
// TypeScript (@langchain/core)
import { Document } from '@langchain/core/documents';
import { Embeddings } from '@langchain/core/embeddings';
import { VectorStore } from '@langchain/core/vectorstores';
```

---

## Review Sign-off

| Role | Name | Date | Approval |
|------|------|------|----------|
| Reviewer | Architecture Team | 2026-02-25 | ✅ |
| Technical Lead | - | - | ⬜ Pending |
| Product Owner | - | - | ⬜ Pending |
| ai-sdk-js Maintainer | - | - | ⬜ Pending |
| langchain-hana Maintainer | - | - | ⬜ Pending |