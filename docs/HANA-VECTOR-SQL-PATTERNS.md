# HANA Vector SQL Patterns

> **Shared documentation for SAP HANA Cloud Vector Engine SQL patterns**  
> Used by: `langchain-integration-for-sap-hana-cloud`, `ai-sdk-js`, `cap-llm-plugin`

This document defines the canonical SQL patterns for interacting with SAP HANA Cloud Vector Engine to ensure consistency across all SAP AI SDK implementations.

---

## Table of Contents

1. [Table Schema](#table-schema)
2. [Vector Storage](#vector-storage)
3. [Similarity Search](#similarity-search)
4. [Distance Metrics](#distance-metrics)
5. [MMR Search](#mmr-search)
6. [Hybrid Search](#hybrid-search)
7. [HNSW Index](#hnsw-index)
8. [Metadata Filtering](#metadata-filtering)
9. [Internal Embeddings](#internal-embeddings)

---

## Table Schema

### Standard Vector Table

```sql
CREATE TABLE "VECTOR_STORE" (
    "ID"         NVARCHAR(255) PRIMARY KEY,
    "CONTENT"    NCLOB,
    "EMBEDDING"  REAL_VECTOR(1536),        -- or HALF_VECTOR(1536) for reduced precision
    "METADATA"   NCLOB,                    -- JSON string
    "CREATED_AT" TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    "UPDATED_AT" TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
```

### Column Types

| Column | Type | Description |
|--------|------|-------------|
| ID | `NVARCHAR(255)` | Unique document identifier |
| CONTENT | `NCLOB` | Document text content |
| EMBEDDING | `REAL_VECTOR(n)` | 32-bit float vector with n dimensions |
| EMBEDDING | `HALF_VECTOR(n)` | 16-bit float vector (reduced memory) |
| METADATA | `NCLOB` | JSON metadata string |

### Check Table Exists

```sql
SELECT COUNT(*) 
FROM SYS.TABLES 
WHERE SCHEMA_NAME = CURRENT_SCHEMA
  AND TABLE_NAME = ?;
```

### Check Column Exists

```sql
SELECT DATA_TYPE_NAME, LENGTH 
FROM SYS.TABLE_COLUMNS 
WHERE SCHEMA_NAME = CURRENT_SCHEMA 
  AND TABLE_NAME = ? 
  AND COLUMN_NAME = ?;
```

---

## Vector Storage

### Insert with External Embedding

```sql
INSERT INTO "VECTOR_STORE" ("ID", "CONTENT", "EMBEDDING", "METADATA")
VALUES (?, ?, TO_REAL_VECTOR(?), ?);
```

**Parameters:**
1. `id` (string) - Document ID
2. `content` (string) - Document text
3. `embedding` (string) - Vector as JSON array: `"[0.1, 0.2, ...]"`
4. `metadata` (string) - JSON metadata: `'{"source": "web"}'`

### Insert with Internal Embedding (VECTOR_EMBEDDING)

```sql
INSERT INTO "VECTOR_STORE" ("ID", "CONTENT", "EMBEDDING", "METADATA")
VALUES (?, ?, VECTOR_EMBEDDING(?, 'DOCUMENT', ?), ?);
```

**Parameters:**
1. `id` (string)
2. `content` (string)
3. `text` (string) - Text to embed
4. `model_id` (string) - Embedding model ID
5. `metadata` (string)

### Upsert (Insert or Update)

```sql
UPSERT "VECTOR_STORE" ("ID", "CONTENT", "EMBEDDING", "METADATA", "UPDATED_AT")
VALUES (?, ?, TO_REAL_VECTOR(?), ?, CURRENT_TIMESTAMP)
WITH PRIMARY KEY;
```

### Batch Insert (Parameterized)

```sql
-- Prepare statement once, execute many
PREPARE stmt FROM 
  'INSERT INTO "VECTOR_STORE" ("ID", "CONTENT", "EMBEDDING", "METADATA") 
   VALUES (?, ?, TO_REAL_VECTOR(?), ?)';
EXECUTE stmt USING :id, :content, :embedding, :metadata;
```

---

## Similarity Search

### Cosine Similarity Search

```sql
SELECT 
    "ID",
    "CONTENT",
    "METADATA",
    COSINE_SIMILARITY("EMBEDDING", TO_REAL_VECTOR(?)) AS "SCORE"
FROM "VECTOR_STORE"
WHERE COSINE_SIMILARITY("EMBEDDING", TO_REAL_VECTOR(?)) >= ?
ORDER BY "SCORE" DESC
LIMIT ?;
```

**Parameters:**
1. `query_embedding` (string) - Query vector as JSON array
2. `query_embedding` (string) - Same vector (for WHERE clause)
3. `min_score` (float) - Minimum similarity threshold (0.0 - 1.0)
4. `k` (int) - Number of results

**Note:** The query embedding is passed twice because HANA doesn't support column aliases in WHERE clauses.

### Alternative: Using CTE to Avoid Duplicate Parameter

```sql
WITH query_vec AS (
    SELECT TO_REAL_VECTOR(?) AS vec FROM DUMMY
)
SELECT 
    v."ID",
    v."CONTENT",
    v."METADATA",
    COSINE_SIMILARITY(v."EMBEDDING", q.vec) AS "SCORE"
FROM "VECTOR_STORE" v, query_vec q
WHERE COSINE_SIMILARITY(v."EMBEDDING", q.vec) >= ?
ORDER BY "SCORE" DESC
LIMIT ?;
```

### Cosine Similarity with Internal Embedding

```sql
SELECT 
    "ID",
    "CONTENT",
    "METADATA",
    COSINE_SIMILARITY("EMBEDDING", VECTOR_EMBEDDING(?, 'QUERY', ?)) AS "SCORE"
FROM "VECTOR_STORE"
ORDER BY "SCORE" DESC
LIMIT ?;
```

**Parameters:**
1. `query_text` (string) - Text to embed and search
2. `model_id` (string) - Embedding model ID
3. `k` (int) - Number of results

---

## Distance Metrics

### Supported Metrics

| Metric | Function | Sort Order | Score Range |
|--------|----------|------------|-------------|
| Cosine Similarity | `COSINE_SIMILARITY(a, b)` | DESC | 0.0 - 1.0 |
| Euclidean Distance | `L2DISTANCE(a, b)` | ASC | 0.0 - ∞ |
| Dot Product | `DOT_PRODUCT(a, b)` | DESC | -∞ - ∞ |

### Euclidean Distance Search

```sql
SELECT 
    "ID",
    "CONTENT",
    "METADATA",
    L2DISTANCE("EMBEDDING", TO_REAL_VECTOR(?)) AS "DISTANCE"
FROM "VECTOR_STORE"
ORDER BY "DISTANCE" ASC
LIMIT ?;
```

### Converting Distance to Similarity

```sql
-- Euclidean distance to similarity: 1 / (1 + distance)
SELECT 
    "ID",
    "CONTENT",
    (1.0 / (1.0 + L2DISTANCE("EMBEDDING", TO_REAL_VECTOR(?)))) AS "SCORE"
FROM "VECTOR_STORE"
ORDER BY "SCORE" DESC
LIMIT ?;
```

---

## MMR Search

Maximum Marginal Relevance balances relevance with diversity.

### Algorithm

```
MMR(doc) = λ * sim(doc, query) - (1 - λ) * max(sim(doc, selected_docs))
```

Where:
- `λ` (lambda) = 0.5 by default
- `λ = 1.0` → pure relevance
- `λ = 0.0` → pure diversity

### Implementation Pattern

**Step 1: Fetch candidates (fetch_k > k)**
```sql
SELECT 
    "ID",
    "CONTENT",
    "METADATA",
    "EMBEDDING",
    COSINE_SIMILARITY("EMBEDDING", TO_REAL_VECTOR(?)) AS "SCORE"
FROM "VECTOR_STORE"
ORDER BY "SCORE" DESC
LIMIT ?;  -- fetch_k (e.g., 40 for k=10)
```

**Step 2: Apply MMR in application code**

```python
# Python (langchain-hana)
from langchain_core.vectorstores.utils import maximal_marginal_relevance
import numpy as np

mmr_indices = maximal_marginal_relevance(
    np.array(query_embedding),
    [doc.embedding for doc in candidates],
    lambda_mult=0.5,
    k=10
)
results = [candidates[i] for i in mmr_indices]
```

```typescript
// TypeScript (ai-sdk-js)
function mmrSearch(queryEmbedding: number[], candidates: ScoredDocument[], k: number, lambda: number) {
  const selected: ScoredDocument[] = [];
  const remaining = [...candidates];

  while (selected.length < k && remaining.length > 0) {
    let bestScore = -Infinity;
    let bestIdx = 0;

    for (let i = 0; i < remaining.length; i++) {
      const relevance = remaining[i].score;
      let maxSimilarity = 0;
      
      for (const s of selected) {
        const sim = cosineSimilarity(remaining[i].embedding, s.embedding);
        maxSimilarity = Math.max(maxSimilarity, sim);
      }
      
      const mmrScore = lambda * relevance - (1 - lambda) * maxSimilarity;
      if (mmrScore > bestScore) {
        bestScore = mmrScore;
        bestIdx = i;
      }
    }
    
    selected.push(remaining.splice(bestIdx, 1)[0]);
  }
  
  return selected;
}
```

---

## Hybrid Search

Combines vector similarity with keyword search.

### Using CONTAINS for Keyword Matching

```sql
SELECT 
    "ID",
    "CONTENT",
    "METADATA",
    (
        0.7 * COSINE_SIMILARITY("EMBEDDING", TO_REAL_VECTOR(?)) +
        0.3 * CASE WHEN CONTAINS("CONTENT", ?) THEN 1.0 ELSE 0.0 END
    ) AS "SCORE"
FROM "VECTOR_STORE"
WHERE COSINE_SIMILARITY("EMBEDDING", TO_REAL_VECTOR(?)) >= ?
   OR CONTAINS("CONTENT", ?)
ORDER BY "SCORE" DESC
LIMIT ?;
```

**Parameters:**
1. `embedding` - Query vector
2. `keywords` - Search keywords
3. `embedding` - Query vector (repeated for WHERE)
4. `min_score` - Minimum similarity
5. `keywords` - Keywords (repeated for WHERE)
6. `k` - Limit

### Fuzzy Text Search

```sql
SELECT * FROM "VECTOR_STORE"
WHERE CONTAINS("CONTENT", ?, FUZZY(0.8));
```

---

## HNSW Index

Hierarchical Navigable Small World index for fast approximate nearest neighbor search.

### Create HNSW Index

```sql
CREATE HNSW VECTOR INDEX idx_vectors 
ON "VECTOR_STORE" ("EMBEDDING")
SIMILARITY FUNCTION COSINE_SIMILARITY
BUILD CONFIGURATION '{"M": 16, "efConstruction": 200}'
SEARCH CONFIGURATION '{"efSearch": 100}'
ONLINE;
```

### Parameters

| Parameter | Description | Default | Valid Range |
|-----------|-------------|---------|-------------|
| `M` | Max neighbors per node | 16 | 4 - 1000 |
| `efConstruction` | Build-time candidates | 200 | 1 - 100000 |
| `efSearch` | Search-time candidates | 100 | 1 - 100000 |

### Create Index with L2 Distance

```sql
CREATE HNSW VECTOR INDEX idx_vectors_l2 
ON "VECTOR_STORE" ("EMBEDDING")
SIMILARITY FUNCTION L2DISTANCE
ONLINE;
```

### Drop Index

```sql
DROP INDEX idx_vectors;
```

---

## Metadata Filtering

### JSON_VALUE for Scalar Extraction

```sql
SELECT * FROM "VECTOR_STORE"
WHERE JSON_VALUE("METADATA", '$.source') = ?
  AND JSON_VALUE("METADATA", '$.category') = ?;
```

### Complex Filter Patterns

```sql
-- Numeric comparison
WHERE CAST(JSON_VALUE("METADATA", '$.year') AS INT) > 2020

-- Array contains (approximate)
WHERE JSON_VALUE("METADATA", '$.tags') LIKE '%"python"%'

-- Nested object
WHERE JSON_VALUE("METADATA", '$.author.name') = 'John'
```

### Filter DSL → SQL Mapping

| Filter DSL | SQL |
|------------|-----|
| `{"field": "value"}` | `JSON_VALUE(META, '$.field') = 'value'` |
| `{"field": {"$eq": "value"}}` | `JSON_VALUE(META, '$.field') = 'value'` |
| `{"field": {"$ne": "value"}}` | `JSON_VALUE(META, '$.field') != 'value'` |
| `{"field": {"$gt": 10}}` | `CAST(JSON_VALUE(META, '$.field') AS INT) > 10` |
| `{"field": {"$contains": "text"}}` | `JSON_VALUE(META, '$.field') LIKE '%text%'` |
| `{"$and": [...]}` | `(...) AND (...)` |
| `{"$or": [...]}` | `(...) OR (...)` |

### Projected Metadata Columns

For frequently filtered fields, project them as columns:

```sql
WITH intermediate AS (
    SELECT *,
        JSON_VALUE("METADATA", '$.source') AS "source",
        JSON_VALUE("METADATA", '$.category') AS "category"
    FROM "VECTOR_STORE"
)
SELECT * FROM intermediate
WHERE "source" = ? AND "category" = ?;
```

---

## Internal Embeddings

Using HANA's built-in `VECTOR_EMBEDDING` function.

### Validate Embedding Function

```sql
SELECT COUNT(TO_NVARCHAR(
    VECTOR_EMBEDDING('test', 'QUERY', ?)
)) AS "CNT" 
FROM SYS.DUMMY;
```

### Generate Query Embedding

```sql
SELECT VECTOR_EMBEDDING(?, 'QUERY', ?) AS embedding
FROM SYS.DUMMY;
```

### Generate Document Embedding

```sql
SELECT VECTOR_EMBEDDING(?, 'DOCUMENT', ?) AS embedding
FROM SYS.DUMMY;
```

### With Remote Source

```sql
SELECT VECTOR_EMBEDDING(?, 'QUERY', ?, "remote_source_name") AS embedding
FROM SYS.DUMMY;
```

---

## Implementation Reference

### Python (langchain-hana)

```python
# Location: langchain_hana/vectorstores/hana_db.py
from langchain_hana import HanaDB

db = HanaDB(
    connection=conn,
    embedding=embeddings,
    distance_strategy=DistanceStrategy.COSINE,
    table_name="DOCUMENTS",
    content_column="VEC_TEXT",
    metadata_column="VEC_META",
    vector_column="VEC_VECTOR",
    vector_column_type="REAL_VECTOR"
)
```

### TypeScript (ai-sdk-js)

```typescript
// Location: packages/hana-vector/src/vector-store.ts
import { createHANAVectorStore } from '@sap-ai-sdk/hana-vector';

const vectorStore = createHANAVectorStore(client, {
    tableName: 'DOCUMENTS',
    embeddingDimensions: 1536,
    contentColumn: 'CONTENT',
    metadataColumn: 'METADATA',
    embeddingColumn: 'EMBEDDING'
});
```

### CAP CDS (cap-llm-plugin)

```javascript
// Location: srv/cap-llm-plugin.js
const results = await cds.run(`
    SELECT TOP ${topK}
        "${contentColumn}",
        "${metadataColumn}",
        ${distanceFunc}("${embeddingColumn}", TO_REAL_VECTOR(?)) AS similarity
    FROM "${tableName}"
    ORDER BY similarity ${sortOrder}
`, [JSON.stringify(embedding)]);
```

---

## Version Compatibility

| Feature | HANA Cloud Version | Notes |
|---------|-------------------|-------|
| REAL_VECTOR | 2024.2 (QRC 1/2024) | 32-bit float vectors |
| HALF_VECTOR | 2025.15 (QRC 2/2025) | 16-bit float vectors |
| VECTOR_EMBEDDING | 2024.4 (QRC 3/2024) | Internal embedding function |
| HNSW Index | 2024.2 (QRC 1/2024) | Approximate NN search |
| COSINE_SIMILARITY | 2024.2 (QRC 1/2024) | Core similarity function |
| L2DISTANCE | 2024.2 (QRC 1/2024) | Euclidean distance |

---

## Related Projects

- [langchain-integration-for-sap-hana-cloud](https://github.com/SAP/langchain-integration-for-sap-hana-cloud) - Python LangChain integration
- [ai-sdk-js](https://github.com/SAP/ai-sdk-js) - TypeScript AI SDK with HANA Vector support
- [cap-llm-plugin](https://github.com/SAP/cap-llm-plugin) - CAP CDS plugin for LLM operations

---

*Last updated: February 26, 2026*