# Session Recovery Context - March 24, 2026

## Original Task
Deployment Order & Plan for SAP OSS AI Services - understanding the architecture and data flow.

## Files Created/Modified in Previous Session

### Deploy Configuration (Created)
- `deploy/README.md` - Deployment documentation
- `deploy/.env.example` - Environment variable template
- `deploy/docker-compose.tier0.yml` - Infrastructure tier (HANA, AI Core, ES)
- `deploy/docker-compose.tier1.yml` - MCP Servers tier
- `deploy/docker-compose.tier2.yml` - Intelligence layer tier
- `deploy/docker-compose.tier3.yml` - Training/ModelOpt tier
- `deploy/docker-compose.full.yml` - Full stack deployment
- `deploy/scripts/deploy.sh` - Deployment script
- `deploy/scripts/health-check.sh` - Health verification
- `deploy/scripts/rollback.sh` - Rollback procedures
- `deploy/scripts/aicore-deploy.sh` - SAP AI Core deployment
- `deploy/Makefile` - Build automation
- `deploy/.gitignore` - Git ignore rules

### HANA Cloud Documentation (Created)
- `docs/hana-cloud/HANA_CLOUD_TABLES.md` - Table schemas for PAL_STORE
- `docs/hana-cloud/deploy_all_hana_tables.sql` - SQL deployment script
- `docs/hana-cloud/SAP_CDS_VIEWS.md` - CDS view documentation
- `docs/hana-cloud/END_TO_END_FLOW.md` - Complete data flow
- `docs/hana-cloud/ORCHESTRATION_FLOW.md` - Service orchestration

---

## Key Discussion Points & Clarifications

### 1. PAL (Predictive Analysis Library) Clarification
- **PAL is NOT an orchestration service**
- PAL is specifically for running PAL queries on SAP HANA
- Used for machine learning algorithms natively in HANA (clustering, regression, etc.)

### 2. Neo4j Status
- Neo4j is **NOT part of this ecosystem** currently
- The system uses Elasticsearch for search and HANA for vector storage

### 3. Mesh Coordinator vs AI-Core-Streaming
- `mesh_coordinator.py` is in `src/data/ai-core-streaming/agent/`
- `ai-core-streaming` is a **registered service** in the mesh
- Mesh Coordinator **routes requests** to registered services
- They are **different** - coordinator orchestrates, ai-core-streaming is one of the services

### 4. Service Routing Configuration
- Routing is configured in `src/data/ai-core-streaming/mesh/registry.yaml`
- The mesh coordinator reads this registry to know available services

### 5. sap-ai-fabric-console & cap-llm-plugin
- **sap-ai-fabric-console**: Admin UI for managing AI deployments
- **cap-llm-plugin**: CAP (Cloud Application Programming) plugin for LLM integration in SAP apps

### 6. OData Vocabulary & Entity Extraction Flow
**Clarified Flow:**
1. User prompt comes in
2. System uses **embedded vocabulary files** (`vocabulary_index.json`) for similarity search
3. Finds matching entities/CDS views from embeddings
4. LLM generates SQL based on matched CDS schema
5. SQL executes on HANA against the CDS view
6. Results returned to user

**Key Files:**
- `src/data/odata-vocabularies-main/_embeddings/vocabulary_index.json` - Pre-computed embeddings
- Annotations stored in **files**, NOT in Elasticsearch
- Elasticsearch used for document search, not entity lookup

---

## Pending Question (Last Request Before Failure)

**User asked:** "if it is going to work on pre-trained info, can you check what is in the training folder and tell me what is being trained for LLM"

### Training Folder Contents to Examine
- `src/training/` - Main training directory
- `src/training/data/` - Training datasets
- `src/training/data/specialist_training/train_balance_sheet.json` - Financial training data

---

## Service Architecture Summary

```
TIER 0: Infrastructure
├── SAP HANA Cloud (External/BTP) - Port 443
├── SAP AI Core (External/BTP) - OAuth + Embeddings
└── Elasticsearch (Self-hosted) - Port 9200

TIER 1: MCP Servers
├── OData Vocabularies MCP - Port 9150 (No deps)
├── Elasticsearch MCP - Port 9120 (Needs ES + AI Core)
└── LangChain HANA MCP - Port 9160 (Needs HANA + AI Core)

TIER 2: Intelligence Layer
├── vLLM Inference - Port 8080 (GPU, AI Core)
├── AI-Core-PAL - Port 9881 (HANA, vLLM)
└── Gen AI Toolkit - Port 8084 (HANA, AI Core)

TIER 3: Training (Optional)
└── ModelOpt API + UI - Ports 8001, 8080
```

---

## Training Folder Analysis (Completed)

### What's Being Trained for LLM

The training system is designed for **Text-to-SQL generation** specifically for **banking/financial schemas on SAP HANA**. It is NOT training a foundation model from scratch, but rather:

1. **Fine-tuning** existing models (Qwen 3.5 series) for domain-specific Text-to-SQL
2. **Quantizing** models for efficient deployment on edge/T4 GPUs

### Training Data Structure

**5 Specialist Training Datasets:**

| File | Domain | Purpose | Target Tables |
|------|--------|---------|---------------|
| `train_balance_sheet.json` | Balance Sheet | Financial position queries | `GL.FAGLFLEXT`, `GL.SKA1` |
| `train_esg.json` | ESG/Sustainability | Environmental metrics | `ESG.SF_FLAT` |
| `train_performance.json` | P&L Performance | Revenue/profit queries | `BPC.ZFI_FIN_OVER_AFO_CP_FIN` |
| `train_treasury.json` | Treasury | Cash/liquidity queries | Treasury tables |
| `train_router.json` | Query Classification | Route queries to correct specialist | Labels: `esg`, `performance`, `balance_sheet` |

### Training Data Format (Question → SQL pairs)

```json
{
  "id": "bs_0",
  "domain": "balance_sheet",
  "question": "What is the Funded Assets movement at US level for Q4 2024?",
  "sql": "SELECT RBUKRS AS entity, SUM(CASE WHEN RYEAR = '2024'...) FROM GL.FAGLFLEXT ...",
  "type": "movement"
}
```

### Query Types Supported

- `simple_metric` - Single value queries
- `movement` - YoY/QoQ changes
- `yoy_qoq` - Year-over-year comparisons
- `group_by_entity` - Aggregation by region/segment
- `funding_gap` - Assets minus liabilities
- `vs_budget` - Actuals vs budget comparison
- `top_performer` - Ranking queries
- `ratio` - Financial ratio calculations (RoRWA%, CASA/TD, etc.)

### Pipeline Stages (7-Stage Process)

```
Excel Files (Banking Data)
    ↓
Stage 1: Pre-convert (Excel → CSV) [Python]
    ↓
Stage 2: Schema Extraction [Zig]
    ↓
Stage 3: Hierarchy Parsing [Zig]
    ↓
Stage 4: Template Parsing [Zig]
    ↓
Stage 5: Template Expansion + SQL Generation [Zig]
    ↓
Stage 6: Mangle Validation [Mangle rules]
    ↓
Stage 7: Spider/BIRD Format [Zig]
    ↓
Fine-tuning Dataset (Spider format)
```

### Model Optimization (nvidia-modelopt)

**Target Hardware:** NVIDIA T4 GPU (16GB VRAM)

**Supported Quantization:**
| Format | T4 Support | Use Case |
|--------|------------|----------|
| INT8 | ✅ | **Recommended** - Best quality/performance |
| INT4 (AWQ) | ✅ | Best compression (4x) |
| W4A16 | ✅ | Weight-only 4-bit |
| FP8 | ❌ | Requires Ada Lovelace+ |

**Recommended Models for T4:**
- Qwen3.5-1.8B → INT8 (1.8GB VRAM)
- Qwen3.5-4B → INT8 (4GB VRAM)
- Qwen3.5-9B → INT4 + Pruning

**Export Formats:**
- Hugging Face checkpoint
- TensorRT-LLM (production)
- vLLM (serving)

---

## Complete Architecture Summary

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         SAP OSS AI SERVICES FLOW                            │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  USER QUERY: "What is Q4 2024 Revenue for CIB?"                            │
│       │                                                                     │
│       ▼                                                                     │
│  ┌─────────────────┐                                                        │
│  │  Router Model   │ ← Classifies: "performance" domain                     │
│  │ (train_router)  │                                                        │
│  └────────┬────────┘                                                        │
│           │                                                                 │
│           ▼                                                                 │
│  ┌─────────────────┐                                                        │
│  │ Specialist LLM  │ ← Fine-tuned on train_performance.json                │
│  │ (Text-to-SQL)   │                                                        │
│  └────────┬────────┘                                                        │
│           │                                                                 │
│           ▼                                                                 │
│  ┌─────────────────┐                                                        │
│  │   Generated SQL │                                                        │
│  │ SELECT ... FROM │                                                        │
│  │ BPC.ZFI_FIN...  │                                                        │
│  └────────┬────────┘                                                        │
│           │                                                                 │
│           ▼                                                                 │
│  ┌─────────────────┐                                                        │
│  │  SAP HANA Cloud │ ← Execute SQL                                          │
│  │  (BPC Tables)   │                                                        │
│  └────────┬────────┘                                                        │
│           │                                                                 │
│           ▼                                                                 │
│  ┌─────────────────┐                                                        │
│  │  Results + NLG  │ → "Q4 2024 Revenue for CIB was $X.XX billion"         │
│  └─────────────────┘                                                        │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Session Status: COMPLETED

All questions from the previous session have been answered:

1. ✅ PAL clarification (ML algorithms, not orchestration)
2. ✅ Neo4j status (not in this ecosystem)
3. ✅ Mesh Coordinator vs AI-Core-Streaming (different roles)
4. ✅ Service routing configuration (registry.yaml)
5. ✅ OData vocabulary flow (embedded embeddings)
6. ✅ Training folder analysis (Text-to-SQL for banking)

### Next Steps (If Continuing)

1. **Run the training pipeline**: `cd src/training/pipeline && make all`
2. **Quantize a model**: `cd src/training/nvidia-modelopt && ./setup.sh`
3. **Deploy vLLM with quantized model**: Use `deploy/docker-compose.tier2.yml`
