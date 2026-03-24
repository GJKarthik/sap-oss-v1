# End-to-End Query Flow: Natural Language to SAP Finance Data

## Complete Flow Diagram

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                          USER QUERY                                          │
│  "Show me the top 10 cost centers by spend in company code 1000             │
│   for fiscal year 2024"                                                      │
└─────────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│  STEP 1: SEMANTIC SEARCH (OData Vocab RAG)                                  │
│  ─────────────────────────────────────────                                  │
│  User query is embedded and searched against vocabulary embeddings           │
│                                                                              │
│  Process:                                                                    │
│  1. Embed query: "top 10 cost centers by spend..." → vector                 │
│  2. Search vocabulary_index.json for similar terms                          │
│  3. Return candidate SAP fields that match query concepts                   │
│                                                                              │
│  OData Vocab MCP Server Returns:                                             │
│  ┌───────────────────────────────────────────────────────────────────────┐  │
│  │  Matched Terms (from RAG search):                                      │  │
│  │  • "cost center" → CostCenter (KOSTL), @Analytics.dimension            │  │
│  │  • "spend/amount" → AmountInCompanyCodeCurrency (HSL), @Analytics.measure│
│  │  • "company code" → CompanyCode (BUKRS), @Analytics.dimension          │  │
│  │  • "fiscal year" → FiscalYear (GJAHR), @Analytics.dimension            │  │
│  │                                                                        │  │
│  │  Candidate Entity: I_JournalEntryItem (ACDOCA)                         │  │
│  │  Confidence: 0.92                                                      │  │
│  └───────────────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│  STEP 2: ENTITY EXTRACTION & DISAMBIGUATION (LLM + Vocab Context)           │
│  ─────────────────────────────────────────────────────────                  │
│  Query embeddings to find relevant SAP field metadata                        │
│                                                                              │
│  OData Vocab MCP Server:                                                     │
│  ┌───────────────────────────────────────────────────────────────────────┐  │
│  │  Input: "cost_center", "company_code", "amount", "fiscal_year"        │  │
│  │         ↓                                                              │  │
│  │  Embedding Search (vocabulary_index.json / PAL_STORE.EMBEDDINGS)       │  │
│  │         ↓                                                              │  │
│  │  Retrieved Context:                                                    │  │
│  │  {                                                                     │  │
│  │    "cost_center": {                                                    │  │
│  │      "entity": "I_JournalEntryItem",                                   │  │
│  │      "technical_name": "KOSTL",                                        │  │
│  │      "cds_field": "CostCenter",                                        │  │
│  │      "category": "dimension",                                          │  │
│  │      "annotations": "@Analytics.dimension, @Aggregation.groupable"     │  │
│  │    },                                                                  │  │
│  │    "company_code": {                                                   │  │
│  │      "entity": "I_JournalEntryItem",                                   │  │
│  │      "technical_name": "BUKRS",                                        │  │
│  │      "cds_field": "CompanyCode",                                       │  │
│  │      "category": "dimension"                                           │  │
│  │    },                                                                  │  │
│  │    "amount": {                                                         │  │
│  │      "entity": "I_JournalEntryItem",                                   │  │
│  │      "technical_name": "HSL",                                          │  │
│  │      "cds_field": "AmountInCompanyCodeCurrency",                       │  │
│  │      "category": "measure",                                            │  │
│  │      "annotations": "@Analytics.measure, @Aggregation.aggregatable",   │  │
│  │      "currency_ref": "CompanyCodeCurrency"                             │  │
│  │    },                                                                  │  │
│  │    "fiscal_year": {                                                    │  │
│  │      "entity": "I_JournalEntryItem",                                   │  │
│  │      "technical_name": "GJAHR",                                        │  │
│  │      "cds_field": "FiscalYear",                                        │  │
│  │      "category": "dimension"                                           │  │
│  │    }                                                                   │  │
│  │  }                                                                     │  │
│  └───────────────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│  STEP 3: SQL GENERATION (LLM with Context)                                  │
│  ──────────────────────────────────────────                                 │
│  LLM generates SQL using enriched context from vocabulary                    │
│                                                                              │
│  LLM Prompt:                                                                 │
│  ┌───────────────────────────────────────────────────────────────────────┐  │
│  │  System: You are a SAP HANA SQL expert. Use the provided field         │  │
│  │  metadata to generate accurate SQL queries against S/4HANA views.      │  │
│  │                                                                        │  │
│  │  Context (from OData Vocab):                                           │  │
│  │  - Entity: I_JournalEntryItem (ACDOCA Universal Journal)               │  │
│  │  - CostCenter is a groupable dimension (KOSTL → CostCenter)            │  │
│  │  - Amount is an aggregatable measure (HSL → AmountInCompanyCodeCurrency)│  │
│  │  - Currency reference: CompanyCodeCurrency                             │  │
│  │  - Filter by CompanyCode = '1000' and FiscalYear = '2024'              │  │
│  │                                                                        │  │
│  │  User Query: Show me the top 10 cost centers by spend in company       │  │
│  │  code 1000 for fiscal year 2024                                        │  │
│  └───────────────────────────────────────────────────────────────────────┘  │
│                                                                              │
│  Generated SQL:                                                              │
│  ┌───────────────────────────────────────────────────────────────────────┐  │
│  │  SELECT                                                                │  │
│  │      "CostCenter",                                                     │  │
│  │      SUM("AmountInCompanyCodeCurrency") AS "TotalSpend",               │  │
│  │      "CompanyCodeCurrency" AS "Currency"                               │  │
│  │  FROM "S4HANA_FINANCE"."I_JournalEntryItem"                            │  │
│  │  WHERE "CompanyCode" = '1000'                                          │  │
│  │    AND "FiscalYear" = '2024'                                           │  │
│  │    AND "CostCenter" IS NOT NULL                                        │  │
│  │  GROUP BY "CostCenter", "CompanyCodeCurrency"                          │  │
│  │  ORDER BY "TotalSpend" DESC                                            │  │
│  │  LIMIT 10                                                              │  │
│  └───────────────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│  STEP 4: SQL EXECUTION (HANA Cloud / S/4HANA)                               │
│  ────────────────────────────────────────────                               │
│  Execute generated SQL against the database                                  │
│                                                                              │
│  Execution Target Options:                                                   │
│  ┌───────────────────────────────────────────────────────────────────────┐  │
│  │  Option A: HANA Cloud (Replicated Data)                               │  │
│  │    → Query: S4HANA_FINANCE.I_JournalEntryItem (replicated table)      │  │
│  │                                                                        │  │
│  │  Option B: HANA Cloud (Virtual/Federated)                             │  │
│  │    → Query pushed down to S/4HANA via SDA                             │  │
│  │                                                                        │  │
│  │  Option C: Direct S/4HANA OData API                                   │  │
│  │    → Convert SQL to OData query parameters                            │  │
│  │    → GET /sap/opu/odata/sap/API_JOURNALENTRYITEM_SRV/...              │  │
│  └───────────────────────────────────────────────────────────────────────┘  │
│                                                                              │
│  Query Result:                                                               │
│  ┌───────────────────────────────────────────────────────────────────────┐  │
│  │  CostCenter  │  TotalSpend      │  Currency                           │  │
│  │  ────────────┼──────────────────┼─────────                            │  │
│  │  CC001       │  15,234,567.89   │  USD                                │  │
│  │  CC002       │  12,456,789.00   │  USD                                │  │
│  │  CC003       │  10,987,654.32   │  USD                                │  │
│  │  CC004       │   8,765,432.10   │  USD                                │  │
│  │  CC005       │   7,654,321.00   │  USD                                │  │
│  │  CC006       │   6,543,210.98   │  USD                                │  │
│  │  CC007       │   5,432,109.87   │  USD                                │  │
│  │  CC008       │   4,321,098.76   │  USD                                │  │
│  │  CC009       │   3,210,987.65   │  USD                                │  │
│  │  CC010       │   2,109,876.54   │  USD                                │  │
│  └───────────────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│  STEP 5: RESPONSE SYNTHESIS (LLM)                                           │
│  ─────────────────────────────────                                          │
│  LLM combines query results with original question to create response        │
│                                                                              │
│  LLM Prompt:                                                                 │
│  ┌───────────────────────────────────────────────────────────────────────┐  │
│  │  System: Synthesize the query results into a helpful response.         │  │
│  │  Include key insights and format numbers appropriately.                │  │
│  │                                                                        │  │
│  │  Original Question: Show me the top 10 cost centers by spend           │  │
│  │  in company code 1000 for fiscal year 2024                             │  │
│  │                                                                        │  │
│  │  Query Results: [table data above]                                     │  │
│  │                                                                        │  │
│  │  Additional Context:                                                   │  │
│  │  - Data source: Universal Journal (ACDOCA)                             │  │
│  │  - Measure: AmountInCompanyCodeCurrency (aggregated)                   │  │
│  │  - Currency: USD                                                       │  │
│  └───────────────────────────────────────────────────────────────────────┘  │
│                                                                              │
│  Generated Response:                                                         │
│  ┌───────────────────────────────────────────────────────────────────────┐  │
│  │  Here are the top 10 cost centers by spend for Company Code 1000       │  │
│  │  in Fiscal Year 2024:                                                  │  │
│  │                                                                        │  │
│  │  | Rank | Cost Center | Total Spend (USD) |                            │  │
│  │  |------|-------------|-------------------|                            │  │
│  │  | 1    | CC001       | $15,234,567.89    |                            │  │
│  │  | 2    | CC002       | $12,456,789.00    |                            │  │
│  │  | 3    | CC003       | $10,987,654.32    |                            │  │
│  │  | ... (continued)                                                     │  │
│  │                                                                        │  │
│  │  **Key Insights:**                                                     │  │
│  │  - Total spend across top 10: $76,716,047.11 USD                       │  │
│  │  - CC001 accounts for 20% of the top 10 spend                          │  │
│  │  - Data sourced from Universal Journal (ACDOCA)                        │  │
│  └───────────────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                          FINAL RESPONSE TO USER                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Component Interaction Sequence

```
┌──────────┐    ┌──────────┐    ┌──────────────┐    ┌──────────┐    ┌──────────┐
│  User    │    │  Agent   │    │  OData Vocab │    │   LLM    │    │  HANA    │
│  (Chat)  │    │ (Router) │    │  MCP Server  │    │ (vLLM/   │    │  Cloud/  │
│          │    │          │    │              │    │  AI Core)│    │  S/4HANA │
└────┬─────┘    └────┬─────┘    └──────┬───────┘    └────┬─────┘    └────┬─────┘
     │               │                 │                 │               │
     │  1. Query     │                 │                 │               │
     │──────────────>│                 │                 │               │
     │               │                 │                 │               │
     │               │  2. Extract     │                 │               │
     │               │  entities       │                 │               │
     │               │─────────────────────────────────>│               │
     │               │                 │                 │               │
     │               │                 │   3. Entities   │               │
     │               │                 │<────────────────│               │
     │               │                 │                 │               │
     │               │  4. Vocab       │                 │               │
     │               │  lookup         │                 │               │
     │               │────────────────>│                 │               │
     │               │                 │                 │               │
     │               │  5. Field       │                 │               │
     │               │  metadata       │                 │               │
     │               │<────────────────│                 │               │
     │               │                 │                 │               │
     │               │  6. Generate    │                 │               │
     │               │  SQL + context  │                 │               │
     │               │─────────────────────────────────>│               │
     │               │                 │                 │               │
     │               │                 │   7. SQL        │               │
     │               │<────────────────────────────────│               │
     │               │                 │                 │               │
     │               │  8. Execute SQL │                 │               │
     │               │──────────────────────────────────────────────────>│
     │               │                 │                 │               │
     │               │                 │                 │   9. Results  │
     │               │<──────────────────────────────────────────────────│
     │               │                 │                 │               │
     │               │  10. Synthesize │                 │               │
     │               │  response       │                 │               │
     │               │─────────────────────────────────>│               │
     │               │                 │                 │               │
     │               │                 │  11. Response   │               │
     │               │<────────────────────────────────│               │
     │               │                 │                 │               │
     │  12. Answer   │                 │                 │               │
     │<──────────────│                 │                 │               │
     │               │                 │                 │               │
```

---

## Detailed Component Responsibilities

### 1. User Interface / Chat Agent
```yaml
Responsibility: Accept natural language queries
Input: "Show me the top 10 cost centers by spend in company code 1000..."
Output: Route to processing pipeline
```

### 2. Entity Extraction (NLP/LLM)
```yaml
Responsibility: Identify business entities and intent
Input: Natural language query
Output:
  entities:
    - name: "cost_center"
      type: "dimension"
      role: "group_by"
    - name: "company_code" 
      type: "dimension"
      role: "filter"
      value: "1000"
    - name: "fiscal_year"
      type: "dimension"  
      role: "filter"
      value: "2024"
    - name: "amount"
      type: "measure"
      role: "aggregate"
      aggregation: "sum"
  intent: "top_n_query"
  limit: 10
  sort: "descending"
```

### 3. OData Vocabulary MCP Server
```yaml
Responsibility: Enrich entities with SAP field metadata
Input: Entity names ["cost_center", "company_code", "amount", "fiscal_year"]

Process:
  1. Embed query terms → vector
  2. Search vocabulary_index.json embeddings
  3. Retrieve matching ENTITY_FIELDS records
  4. Return enriched metadata

Output:
  - Technical field names (KOSTL, BUKRS, HSL, GJAHR)
  - CDS view names (I_JournalEntryItem)
  - OData annotations (@Analytics.dimension, @Analytics.measure)
  - Currency/unit references
  - Aggregation rules (groupable, aggregatable)
```

### 4. SQL Generation (LLM)
```yaml
Responsibility: Generate syntactically correct SQL
Input:
  - Extracted entities
  - Enriched vocabulary context
  - Target database schema

Output:
  SELECT "CostCenter", SUM("AmountInCompanyCodeCurrency") AS "TotalSpend"...

Guardrails:
  - Only SELECT statements allowed
  - Validate field names against vocabulary
  - Respect currency references
  - Apply appropriate aggregations
```

### 5. SQL Execution (HANA Cloud)
```yaml
Responsibility: Execute SQL and return results
Input: Generated SQL query
Target: 
  - HANA Cloud (replicated/virtual tables)
  - Or S/4HANA HANA database directly

Output:
  - Tabular result set
  - Row count
  - Execution metadata
```

### 6. Response Synthesis (LLM)
```yaml
Responsibility: Create human-readable response
Input:
  - Original user query
  - SQL query results
  - Field metadata (for formatting)

Output:
  - Formatted table/text response
  - Key insights
  - Data source attribution
  - Optional visualizations
```

---

## Service Deployment Mapping

| Step | Service | Port | Tier |
|------|---------|------|------|
| Entity Extraction | vLLM / AI Core | 8080 | Tier 2 |
| Vocab Lookup | OData Vocabularies MCP | 9150 | Tier 1 |
| SQL Generation | vLLM / AI Core | 8080 | Tier 2 |
| SQL Execution | HANA Cloud | 443 | Tier 0 |
| Response Synthesis | vLLM / AI Core | 8080 | Tier 2 |

---

## Example: Full Request/Response Cycle

### Input
```json
{
  "query": "Show me the top 10 cost centers by spend in company code 1000 for fiscal year 2024",
  "session_id": "abc123"
}
```

### Step 1 Output (Entity Extraction)
```json
{
  "entities": [
    {"name": "cost_center", "role": "group_by"},
    {"name": "company_code", "role": "filter", "value": "1000"},
    {"name": "fiscal_year", "role": "filter", "value": "2024"},
    {"name": "amount", "role": "measure", "aggregation": "sum"}
  ],
  "intent": "aggregation_query",
  "limit": 10,
  "order": "desc"
}
```

### Step 2 Output (Vocab Enrichment)
```json
{
  "entity": "I_JournalEntryItem",
  "schema": "S4HANA_FINANCE",
  "fields": {
    "cost_center": {
      "cds_name": "CostCenter",
      "technical": "KOSTL",
      "type": "CHAR(10)",
      "annotations": ["@Analytics.dimension", "@Aggregation.groupable"]
    },
    "amount": {
      "cds_name": "AmountInCompanyCodeCurrency",
      "technical": "HSL",
      "type": "CURR(23,2)",
      "currency_ref": "CompanyCodeCurrency",
      "annotations": ["@Analytics.measure", "@Aggregation.aggregatable"]
    }
  }
}
```

### Step 3 Output (Generated SQL)
```sql
SELECT 
    "CostCenter",
    SUM("AmountInCompanyCodeCurrency") AS "TotalSpend",
    "CompanyCodeCurrency"
FROM "S4HANA_FINANCE"."I_JournalEntryItem"
WHERE "CompanyCode" = '1000'
  AND "FiscalYear" = '2024'
  AND "CostCenter" IS NOT NULL
GROUP BY "CostCenter", "CompanyCodeCurrency"
ORDER BY "TotalSpend" DESC
LIMIT 10
```

### Step 4 Output (Query Results)
```json
{
  "columns": ["CostCenter", "TotalSpend", "CompanyCodeCurrency"],
  "rows": [
    ["CC001", 15234567.89, "USD"],
    ["CC002", 12456789.00, "USD"],
    ["CC003", 10987654.32, "USD"]
  ],
  "row_count": 10,
  "execution_time_ms": 234
}
```

### Step 5 Output (Final Response)
```markdown
## Top 10 Cost Centers by Spend - Company Code 1000, FY 2024

| Rank | Cost Center | Total Spend |
|------|-------------|-------------|
| 1 | CC001 | $15,234,567.89 |
| 2 | CC002 | $12,456,789.00 |
| 3 | CC003 | $10,987,654.32 |
| ... | ... | ... |

**Summary:**
- Total spend across top 10: $76.7M USD
- CC001 leads with 20% of total spend
- Data sourced from Universal Journal (ACDOCA)