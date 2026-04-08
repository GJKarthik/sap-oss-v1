# Orchestration Flow: Service Mesh Coordinator

## The Orchestrator: AI-Core-Streaming / MeshCoordinator

**The MeshCoordinator** (in `ai-core-streaming`) is the central orchestrator. Users submit queries to this service, and it coordinates all downstream services.

**AI-Core-PAL is NOT the orchestrator** - it's specifically for PAL (Predictive Analysis Library) queries on HANA.

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              USER / AI AGENT                                 │
│                                                                             │
│  "Show me top 10 cost centers by spend for company 1000 in 2024"           │
│                                     │                                       │
│              POST /v1/chat/completions (OpenAI-compatible)                  │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
                                      │
                                      ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                                                                             │
│               AI-CORE-STREAMING / MESH COORDINATOR (Port 8084)              │
│               ═══════════════════════════════════════════════               │
│                           THE ORCHESTRATOR                                  │
│                                                                             │
│  Path: src/data/ai-core-streaming/agent/mesh_coordinator.py                 │
│                                                                             │
│  ┌───────────────────────────────────────────────────────────────────────┐ │
│  │                    1. SERVICE REGISTRY                                │ │
│  │                                                                        │ │
│  │  • Loads registry.yaml with all 12 SAP OSS services                   │ │
│  │  • Service discovery by capability or type                            │ │
│  │  • Routing policy based on security classification                    │ │
│  └───────────────────────────────────────────────────────────────────────┘ │
│                                      │                                      │
│                                      ▼                                      │
│  ┌───────────────────────────────────────────────────────────────────────┐ │
│  │                    2. MESH ROUTER (Governance)                        │ │
│  │                                                                        │ │
│  │  • Determines backend based on model, security class, service         │ │
│  │  • Routes: vLLM (confidential) vs AI Core (standard)                  │ │
│  │  • Audit logging for every request                                    │ │
│  └───────────────────────────────────────────────────────────────────────┘ │
│                                      │                                      │
│                                      ▼                                      │
│  ┌───────────────────────────────────────────────────────────────────────┐ │
│  │                    3. WORKFLOW ORCHESTRATOR                           │ │
│  │                                                                        │ │
│  │  async def orchestrate(workflow: List[Dict]):                         │ │
│  │      # Execute multi-service workflow                                 │ │
│  │      for step in workflow:                                            │ │
│  │          service = step["service"]                                    │ │
│  │          action = step["action"]                                      │ │
│  │          result = await _execute_step(service, action, params)        │ │
│  │                                                                        │ │
│  │  Dispatches to:                                                       │ │
│  │  • OData Vocab (9150)    → semantic field lookup                      │ │
│  │  • LangChain HANA (9160) → RAG + HANA vector store                   │ │
│  │  • AI-Core-PAL (9881)    → PAL ML algorithms only                     │ │
│  │  • vLLM (8080)           → LLM inference                              │ │
│  │  • HANA lineage context   → relationship and lineage queries          │ │
│  └───────────────────────────────────────────────────────────────────────┘ │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Correct Service Roles

| Service | Port | Actual Role |
|---------|------|-------------|
| **AI-Core-Streaming / MeshCoordinator** | 8084 | **ORCHESTRATOR** - routes requests, orchestrates workflows |
| OData Vocab MCP | 9150 | Semantic field lookup (RAG for SAP vocabulary) |
| LangChain HANA MCP | 9160 | HANA vector store, RAG chains, similarity search |
| **AI-Core-PAL** | 9881 | **PAL algorithms ONLY** - classification, clustering, forecasting |
| vLLM | 8080 | LLM inference (entity extraction, SQL gen, synthesis) |
| HANA lineage context | Embedded in HANA services | Relationship and lineage context |
| HANA Cloud | 443 | Database - SQL execution, vector store |

---

## AI-Core-PAL: PAL Algorithms Only

**AI-Core-PAL is NOT an orchestrator.** It exposes HANA PAL (Predictive Analysis Library) algorithms:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         AI-CORE-PAL (Port 9881)                             │
│                         ═══════════════════════                             │
│                         PAL ALGORITHMS ONLY                                 │
│                                                                             │
│  Exposes SAP HANA PAL stored procedures as MCP tools:                       │
│                                                                             │
│  ┌───────────────────────────────────────────────────────────────────────┐ │
│  │  Tool: pal-catalog     → List/search 162 PAL algorithms               │ │
│  │  Tool: pal-execute     → Generate CALL _SYS_AFL.* SQL                 │ │
│  │  Tool: pal-spec        → Get ODPS YAML spec for algorithm             │ │
│  │  Tool: pal-sql         → Get SQL template for algorithm               │ │
│  └───────────────────────────────────────────────────────────────────────┘ │
│                                                                             │
│  Algorithms (162 total, 13 categories):                                     │
│  • Classification:        _SYS_AFL.PAL_HGBT                                │
│  • Regression:            _SYS_AFL.PAL_LINEAR_REGRESSION                   │
│  • Clustering:            _SYS_AFL.PAL_KMEANS                              │
│  • Time Series:           _SYS_AFL.PAL_ARIMA                               │
│  • Anomaly Detection:     _SYS_AFL.PAL_ISOLATION_FOREST                    │
│  • Profiling:             _SYS_AFL.PAL_UNIVARIATE_ANALYSIS                 │
│  • Fraud Detection:       _SYS_AFL.PAL_BENFORD                             │
│                                                                             │
│  When to call AI-Core-PAL:                                                  │
│  • "Forecast next 12 months" → PAL_ARIMA                                   │
│  • "Cluster customers" → PAL_KMEANS                                        │
│  • "Detect anomalies" → PAL_ISOLATION_FOREST                               │
│  • "Profile data distribution" → PAL_UNIVARIATE_ANALYSIS                   │
│                                                                             │
│  NOT for general orchestration or SQL queries!                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## End-to-End Query Flow (Corrected)

```
USER QUERY: "Show me top 10 cost centers by spend for company 1000 in 2024"
                │
                ▼
┌───────────────────────────────────────────────────────────────────────────┐
│  MESH COORDINATOR (Port 8084) - THE ORCHESTRATOR                          │
│                                                                           │
│  1. Receives OpenAI-compatible request                                    │
│  2. Determines this is an ANALYTICS query (not PAL)                       │
│  3. Creates workflow:                                                     │
│     [                                                                     │
│       {"service": "odata-vocabularies", "action": "search_vocabulary"},   │
│       {"service": "chat", "action": "generate_sql"},                      │
│       {"service": "langchain-hana", "action": "execute_query"},           │
│       {"service": "chat", "action": "synthesize_response"}                │
│     ]                                                                     │
└───────────────────────────────────────────────────────────────────────────┘
                │
                │ Step 1: Vocabulary Lookup
                ▼
┌───────────────────────────────────────────────────────────────────────────┐
│  ODATA VOCABULARIES MCP (Port 9150)                                       │
│  → Returns: CostCenter (KOSTL), AmountInCompanyCodeCurrency (HSL)         │
│  → Entity: I_JournalEntryItem                                             │
└───────────────────────────────────────────────────────────────────────────┘
                │
                │ Step 2: SQL Generation
                ▼
┌───────────────────────────────────────────────────────────────────────────┐
│  vLLM (Port 8080) - via MeshRouter                                        │
│  → Input: User query + vocabulary context                                 │
│  → Output: SELECT "CostCenter", SUM("AmountInCompanyCodeCurrency")...     │
└───────────────────────────────────────────────────────────────────────────┘
                │
                │ Step 3: SQL Execution
                ▼
┌───────────────────────────────────────────────────────────────────────────┐
│  LANGCHAIN HANA MCP (Port 9160)                                           │
│  → Executes SQL via HANA Cloud connection                                 │
│  → Returns: [{CC001, 15234567.89}, {CC002, 12456789.00}, ...]            │
└───────────────────────────────────────────────────────────────────────────┘
                │
                │ Step 4: Response Synthesis
                ▼
┌───────────────────────────────────────────────────────────────────────────┐
│  vLLM (Port 8080) - via MeshRouter                                        │
│  → Input: SQL results + original query                                    │
│  → Output: "Top 10 Cost Centers by Spend for FY 2024:\n1. CC001..."      │
└───────────────────────────────────────────────────────────────────────────┘
                │
                ▼
┌───────────────────────────────────────────────────────────────────────────┐
│  RESPONSE TO USER                                                         │
└───────────────────────────────────────────────────────────────────────────┘
```

---

## PAL Query Flow (Different Path)

For PAL queries, the MeshCoordinator routes to AI-Core-PAL:

```
USER QUERY: "Forecast next 12 months of sales data"
                │
                ▼
┌───────────────────────────────────────────────────────────────────────────┐
│  MESH COORDINATOR (Port 8084)                                             │
│                                                                           │
│  Detects: "forecast" → PAL query                                          │
│  Creates workflow:                                                        │
│  [                                                                        │
│    {"service": "ai-core-pal", "action": "pal-execute",                    │
│     "params": {"algorithm": "PAL_ARIMA", "table": "SALES_DATA"}}          │
│  ]                                                                        │
└───────────────────────────────────────────────────────────────────────────┘
                │
                ▼
┌───────────────────────────────────────────────────────────────────────────┐
│  AI-CORE-PAL (Port 9881) - PAL SPECIALIST                                 │
│                                                                           │
│  1. Generates: CALL _SYS_AFL.PAL_ARIMA(SALES_DATA, #PARAMS, ?)           │
│  2. Executes on HANA Cloud                                                │
│  3. Returns forecast results                                              │
│  4. Annotates output with OData vocabulary                                │
└───────────────────────────────────────────────────────────────────────────┘
                │
                ▼
┌───────────────────────────────────────────────────────────────────────────┐
│  RESPONSE TO USER                                                         │
│  → 12-month sales forecast with confidence intervals                      │
└───────────────────────────────────────────────────────────────────────────┘
```

---

## Service Architecture (Corrected)

```
                              ┌─────────────────────────────┐
                              │        USER / AGENT         │
                              │                             │
                              │   POST /v1/chat/completions │
                              └─────────────────────────────┘
                                            │
                                            ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                    AI-CORE-STREAMING / MESH COORDINATOR                     │
│                              (Port 8084)                                    │
│                         ═══════════════════════                             │
│                            THE ORCHESTRATOR                                 │
│                                                                             │
│   Responsibilities:                                                         │
│   • Service discovery (registry.yaml)                                       │
│   • Request routing (governance-based)                                      │
│   • Multi-service workflow orchestration                                    │
│   • Audit logging                                                           │
│   • OpenAI-compatible API                                                   │
└─────────────────────────────────────────────────────────────────────────────┘
         │              │              │              │              │
         │              │              │              │              │
         ▼              ▼              ▼              ▼              ▼
┌─────────────┐ ┌─────────────┐ ┌─────────────┐ ┌─────────────┐
│ OData Vocab │ │ LangChain   │ │AI-Core-PAL  │ │    vLLM     │
│    MCP      │ │  HANA MCP   │ │             │ │             │
│  (9150)     │ │  (9160)     │ │  (9881)     │ │  (8080)     │
│             │ │             │ │             │ │             │
│ Vocabulary  │ │ HANA Vector │ │ PAL ONLY:   │ │ LLM Tasks:  │
│ Semantic    │ │ Store, RAG  │ │ Clustering  │ │ Entity Ext  │
│ Lookup      │ │ SQL Exec    │ │ Forecast    │ │ SQL Gen     │
│             │ │ Similarity  │ │ Anomaly     │ │ Synthesis   │
│             │ │ Search      │ │ Regression  │ │             │
└─────────────┘ └─────────────┘ └─────────────┘ └─────────────┘
                       │               │
                       │               │
                       ▼               ▼
              ┌─────────────────────────────────┐
              │        SAP HANA CLOUD           │
              │           (Port 443)            │
              │                                 │
              │   • SQL execution               │
              │   • Vector store                │
              │   • PAL stored procedures       │
              │     (_SYS_AFL.*)                │
              └─────────────────────────────────┘
```

---

## Summary: Who Does What (Corrected)

| Service | Port | Role | Called By |
|---------|------|------|-----------|
| **MeshCoordinator** | 8084 | **ORCHESTRATOR** - routes requests, orchestrates workflows | User/Agent |
| OData Vocab MCP | 9150 | Semantic field lookup (vocabulary RAG) | MeshCoordinator |
| LangChain HANA MCP | 9160 | HANA vector store, RAG chains, SQL execution | MeshCoordinator |
| **AI-Core-PAL** | 9881 | **PAL algorithms ONLY** (clustering, forecast, etc.) | MeshCoordinator |
| vLLM | 8080 | LLM inference | MeshCoordinator |
| HANA lineage context | Embedded in HANA services | Relationship context for each MCP server |
| HANA Cloud | 443 | Database + PAL procedures | LangChain HANA, AI-Core-PAL |

**Key Correction:**
- **MeshCoordinator (8084)** = The orchestrator
- **AI-Core-PAL (9881)** = PAL algorithms specialist (NOT orchestrator)
