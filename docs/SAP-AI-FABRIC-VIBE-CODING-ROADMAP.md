# SAP AI Fabric: Intent-Based Programming Roadmap

## Vibe Coding Approach — Close the Gap to Microsoft Fabric

This roadmap is designed for **intent-based programming** where you describe what you want and let AI (Cline, Claude, etc.) generate the code. 

### Deployment Target: SAP BTP AI Core with KServe
- All services deploy to **SAP AI Core** on BTP
- All inference endpoints are **OpenAI-compatible** 
- Uses **KServe** InferenceService for model serving
- Each component is self-contained within its own `src/data/` directory

---

## 📊 Progress Dashboard

| Phase | Sessions | Status | Score Impact |
|-------|----------|--------|--------------|
| Phase 1: Quick Wins | 15 sessions | ⬜ | 68→72/80 |
| Phase 2: Platform Extension | 20 sessions | ⬜ | 72→76.5/80 |
| Phase 3: Parity Plus | 21 sessions | ⬜ | 76.5→79/80 |

**Total: ~56 vibe coding sessions**

---

# 🚀 PHASE 1: QUICK WINS

## Session 1: ai-core-streaming KServe InferenceService
**Intent:** "Create KServe InferenceService for ai-core-streaming on SAP AI Core"

### Vibe Prompt:
```
In src/data/ai-core-streaming/, create deploy/aicore/ for SAP BTP AI Core deployment:

1. Create deploy/aicore/serving-template.yaml:
   - KServe InferenceService spec
   - OpenAI-compatible /v1/chat/completions endpoint
   - OpenAI-compatible /v1/completions endpoint
   - Health check at /health
   - Resource requests/limits for AI Core

2. Create deploy/aicore/Dockerfile:
   - Build the Zig broker
   - Expose OpenAI-compatible HTTP API on port 8080
   - Include all Mangle rules from mangle/

3. Create deploy/aicore/ai-core-config.json:
   - AI Core serving configuration
   - Model artifact reference
   - Scaling configuration

4. Create deploy/aicore/README.md:
   - How to deploy to AI Core via ai-core-sdk
   - Environment variables needed
   - How to test the OpenAI-compatible endpoint

The service must expose OpenAI-compatible API format.
```

### Expected Output:
- [ ] `src/data/ai-core-streaming/deploy/aicore/serving-template.yaml`
- [ ] `src/data/ai-core-streaming/deploy/aicore/Dockerfile`
- [ ] `src/data/ai-core-streaming/deploy/aicore/ai-core-config.json`
- [ ] `src/data/ai-core-streaming/deploy/aicore/README.md`

### Completion Check:
```bash
cd src/data/ai-core-streaming
# Validate KServe spec
kubectl apply -f deploy/aicore/serving-template.yaml --dry-run=client
# Test OpenAI format
curl http://localhost:8080/v1/chat/completions -d '{"model":"default","messages":[{"role":"user","content":"hi"}]}'
```

---

## Session 2: ai-sdk-js KServe InferenceService
**Intent:** "Create KServe InferenceService for ai-sdk-js OpenAI-compatible proxy"

### Vibe Prompt:
```
In src/data/ai-sdk-js-main/, create deploy/aicore/ for SAP BTP AI Core deployment:

1. Create deploy/aicore/serving-template.yaml:
   - KServe InferenceService spec for the OpenAI proxy
   - Routes to /v1/chat/completions, /v1/embeddings, /v1/completions
   - Configurable upstream AI Core deployments
   - Health check at /health

2. Create deploy/aicore/Dockerfile:
   - Node.js 20 base
   - Build the @sap-ai-sdk/openai-server package
   - Expose port 8080 with OpenAI-compatible API

3. Create deploy/aicore/ai-core-config.json:
   - Scenario and executable IDs
   - Model mapping configuration
   - Resource group settings

4. Create deploy/aicore/README.md:
   - Deploy to AI Core with ai-core-sdk CLI
   - Configure model routing
   - Test OpenAI-compatible endpoints

All endpoints must be fully OpenAI API compatible.
```

### Expected Output:
- [ ] `src/data/ai-sdk-js-main/deploy/aicore/serving-template.yaml`
- [ ] `src/data/ai-sdk-js-main/deploy/aicore/Dockerfile`
- [ ] `src/data/ai-sdk-js-main/deploy/aicore/ai-core-config.json`
- [ ] `src/data/ai-sdk-js-main/deploy/aicore/README.md`

### Completion Check:
```bash
# Test OpenAI compatibility
curl http://localhost:8080/v1/models
curl http://localhost:8080/v1/chat/completions -d '{"model":"gpt-4","messages":[{"role":"user","content":"hi"}]}'
```

---

## Session 3: cap-llm-plugin KServe InferenceService
**Intent:** "Create KServe InferenceService for cap-llm-plugin RAG service"

### Vibe Prompt:
```
In src/data/cap-llm-plugin-main/, create deploy/aicore/ for SAP BTP AI Core deployment:

1. Create deploy/aicore/serving-template.yaml:
   - KServe InferenceService spec for RAG service
   - OpenAI-compatible /v1/chat/completions with RAG context injection
   - /v1/embeddings endpoint for vector generation
   - Health check at /health

2. Create deploy/aicore/Dockerfile:
   - Node.js 20 or Python base
   - Include cap-llm-plugin and all dependencies
   - Embed Mangle governance rules from mangle/
   - Expose port 8080 with OpenAI-compatible API

3. Create deploy/aicore/ai-core-config.json:
   - RAG pipeline configuration
   - HANA Vector connection settings
   - Model routing rules

4. Create deploy/aicore/README.md:
   - Deploy to AI Core
   - Configure HANA Vector for RAG
   - Test with OpenAI-compatible client

The service must accept standard OpenAI API format and inject RAG context.
```

### Expected Output:
- [ ] `src/data/cap-llm-plugin-main/deploy/aicore/serving-template.yaml`
- [ ] `src/data/cap-llm-plugin-main/deploy/aicore/Dockerfile`
- [ ] `src/data/cap-llm-plugin-main/deploy/aicore/ai-core-config.json`
- [ ] `src/data/cap-llm-plugin-main/deploy/aicore/README.md`

### Completion Check:
```bash
# Test RAG-enhanced completion
curl http://localhost:8080/v1/chat/completions \
  -d '{"model":"rag-gpt4","messages":[{"role":"user","content":"What is SAP HANA?"}]}'
```

---

## Session 4: langchain-hana KServe InferenceService
**Intent:** "Create KServe InferenceService for langchain-hana vector service"

### Vibe Prompt:
```
In src/data/langchain-integration-for-sap-hana-cloud-main/, create deploy/aicore/:

1. Create deploy/aicore/serving-template.yaml:
   - KServe InferenceService for vector operations
   - OpenAI-compatible /v1/embeddings endpoint
   - Additional /v1/search endpoint for similarity search
   - Health check at /health

2. Create deploy/aicore/Dockerfile:
   - Python 3.11 base
   - FastAPI server wrapping langchain-hana
   - Expose port 8080

3. Create deploy/aicore/server.py:
   - FastAPI app with OpenAI-compatible endpoints
   - POST /v1/embeddings - generate embeddings (OpenAI format)
   - POST /v1/search - similarity search with HANA Vector
   - GET /health - health check

4. Create deploy/aicore/ai-core-config.json:
   - HANA Cloud connection settings
   - Embedding model configuration
   - Vector table settings

All endpoints must follow OpenAI API conventions.
```

### Expected Output:
- [ ] `src/data/langchain-integration-for-sap-hana-cloud-main/deploy/aicore/serving-template.yaml`
- [ ] `src/data/langchain-integration-for-sap-hana-cloud-main/deploy/aicore/Dockerfile`
- [ ] `src/data/langchain-integration-for-sap-hana-cloud-main/deploy/aicore/server.py`
- [ ] `src/data/langchain-integration-for-sap-hana-cloud-main/deploy/aicore/ai-core-config.json`

### Completion Check:
```bash
# Test OpenAI-compatible embeddings
curl http://localhost:8080/v1/embeddings \
  -d '{"model":"text-embedding-ada-002","input":"Hello world"}'
```

---

## Session 5: odata-vocabularies KServe InferenceService
**Intent:** "Create KServe InferenceService for OData vocabulary service"

### Vibe Prompt:
```
In src/data/odata-vocabularies-main/, create deploy/aicore/:

1. Create deploy/aicore/serving-template.yaml:
   - KServe InferenceService for vocabulary lookup
   - OpenAI-compatible /v1/chat/completions for vocabulary Q&A
   - Health check at /health

2. Create deploy/aicore/Dockerfile:
   - Python base with FastAPI
   - Include all vocabularies from vocabularies/
   - Expose port 8080

3. Create deploy/aicore/server.py:
   - OpenAI-compatible chat endpoint that answers vocabulary questions
   - Uses RAG over vocabulary definitions
   - Tools: search_vocabulary, get_term, suggest_annotations

4. Create deploy/aicore/ai-core-config.json:
   - Model configuration
   - Vocabulary index settings

The service helps developers find correct OData annotations via chat.
```

### Expected Output:
- [ ] `src/data/odata-vocabularies-main/deploy/aicore/serving-template.yaml`
- [ ] `src/data/odata-vocabularies-main/deploy/aicore/Dockerfile`
- [ ] `src/data/odata-vocabularies-main/deploy/aicore/server.py`
- [ ] `src/data/odata-vocabularies-main/deploy/aicore/ai-core-config.json`

### Completion Check:
```bash
# Ask about OData annotations
curl http://localhost:8080/v1/chat/completions \
  -d '{"model":"vocab-assistant","messages":[{"role":"user","content":"What annotation should I use for a currency field?"}]}'
```

---

## Session 6: Tutorial 1 - Hello LLM with AI Core
**Intent:** "Create a 5-minute getting started tutorial"

### Vibe Prompt:
```
Create tutorials/01-hello-llm/README.md that teaches:

1. Prerequisites (Docker, AI Core credentials)
2. Clone and run with docker-compose
3. Make first MCP call using curl:
   - List available tools
   - Call ai_core_chat with "Hello!"
4. Make first streaming call
5. View response in terminal

Include:
- Code blocks that can be copy-pasted
- Expected output examples
- Troubleshooting section
- Next steps link to Tutorial 2

Also create a test.sh script that validates the tutorial works.
```

### Expected Output:
- [ ] `tutorials/01-hello-llm/README.md`
- [ ] `tutorials/01-hello-llm/test.sh`
- [ ] `tutorials/01-hello-llm/examples/`

---

## Session 6: Tutorial 2 - RAG Pipeline
**Intent:** "Create a RAG pipeline tutorial with HANA Vector"

### Vibe Prompt:
```
Create tutorials/02-rag-pipeline/README.md that teaches:

1. Connect to HANA Cloud (or use local mock)
2. Create a vector table with sample documents
3. Generate embeddings using ai_core_embed MCP tool
4. Store embeddings in HANA
5. Query with semantic search
6. Combine search results with LLM completion

Include:
- Python script using langchain-hana
- TypeScript example using @sap-ai-sdk/orchestration
- Sample documents (3-5 short texts about SAP products)
- Expected output at each step

Create a docker-compose.rag.yml that adds a mock HANA for testing.
```

### Expected Output:
- [ ] `tutorials/02-rag-pipeline/README.md`
- [ ] `tutorials/02-rag-pipeline/rag_example.py`
- [ ] `tutorials/02-rag-pipeline/rag_example.ts`
- [ ] `tutorials/02-rag-pipeline/sample_documents.json`
- [ ] `tutorials/02-rag-pipeline/docker-compose.rag.yml`

---

## Session 7: Tutorial 3 - Streaming Chat
**Intent:** "Create a streaming chat tutorial with SSE"

### Vibe Prompt:
```
Create tutorials/03-streaming-chat/README.md that teaches:

1. Understand SSE (Server-Sent Events) basics
2. Connect to ai-core-streaming MCP server
3. Start a streaming chat session
4. Handle streaming deltas in JavaScript
5. Display streaming response in browser
6. Handle abort/cancel properly

Include:
- Simple HTML page with vanilla JS (no framework)
- Node.js backend proxy example
- Python client using sseclient
- Handling connection drops and reconnection

Create index.html that can be opened directly in browser after docker-compose up.
```

### Expected Output:
- [ ] `tutorials/03-streaming-chat/README.md`
- [ ] `tutorials/03-streaming-chat/index.html`
- [ ] `tutorials/03-streaming-chat/server.js`
- [ ] `tutorials/03-streaming-chat/client.py`

---

## Session 8: Tutorial 4 - Governance Rules
**Intent:** "Create a governance and routing rules tutorial"

### Vibe Prompt:
```
Create tutorials/04-governance-rules/README.md that teaches:

1. Understanding Mangle Datalog syntax
2. Reading existing routing rules in mesh/routing_rules.mg
3. Adding a custom security classification rule
4. Testing routing with different prompts:
   - Public prompt → routes to AI Core
   - Prompt with "confidential" → routes to vLLM
   - Prompt with "restricted" → blocked
5. Querying the Mangle engine via MCP

Include:
- Step-by-step Mangle rule writing
- Test cases for each routing outcome
- How to reload rules without restart
- Debugging tips using mangle_query tool

Create a test_routing.py script that validates all routing scenarios.
```

### Expected Output:
- [ ] `tutorials/04-governance-rules/README.md`
- [ ] `tutorials/04-governance-rules/custom_rules.mg`
- [ ] `tutorials/04-governance-rules/test_routing.py`

---

## Session 9: Tutorial 5 - CAP Integration
**Intent:** "Create a CAP application integration tutorial"

### Vibe Prompt:
```
Create tutorials/05-cap-integration/README.md that teaches:

1. Create a new CAP project with cds init
2. Add cap-llm-plugin as a dependency
3. Configure the plugin in package.json
4. Add @anonymize annotations to a sample entity
5. Call the LLM service from a CAP action handler
6. Use the RAG helper with HANA vector
7. Deploy to BTP trial (optional section)

Include:
- Complete CAP project in tutorials/05-cap-integration/bookshop/
- db/schema.cds with annotated entities
- srv/llm-service.js with LLM calls
- Step-by-step screenshots or ASCII diagrams

Use the bookshop sample as the base application.
```

### Expected Output:
- [ ] `tutorials/05-cap-integration/README.md`
- [ ] `tutorials/05-cap-integration/bookshop/` (full CAP project)

---

## Session 10: Sandbox Infrastructure
**Intent:** "Create sandbox environment for free trials"

### Vibe Prompt:
```
Create sandbox/ directory with infrastructure for a free trial environment:

1. Terraform module for Kubernetes cluster (KinD for local, or cloud)
2. Automatic provisioning script that:
   - Creates a namespace per user
   - Deploys the Helm chart
   - Sets resource quotas (1 CPU, 2GB RAM limit)
   - Creates a 7-day TTL for auto-cleanup
3. Landing page at sandbox/web/ with:
   - Email signup form
   - "Launch Sandbox" button
   - Status page showing active sandboxes
4. API backend at sandbox/api/ for:
   - POST /signup - create sandbox
   - GET /status/:id - check sandbox status
   - DELETE /sandbox/:id - cleanup

Keep it simple - use SQLite for state, no complex auth.
```

### Expected Output:
- [ ] `sandbox/terraform/main.tf`
- [ ] `sandbox/scripts/provision.sh`
- [ ] `sandbox/scripts/cleanup.sh`
- [ ] `sandbox/web/index.html`
- [ ] `sandbox/api/server.py`

---

## Session 11: SAC Integration - Schema Generator
**Intent:** "Extend SAC integration for BI report generation"

### Vibe Prompt:
```
Extend src/data/cap-llm-plugin-main/srv/ag-ui/sac-schema-generator.ts to:

1. Add chart type templates:
   - Bar chart, Line chart, Pie chart, Table
   - Each with configurable dimensions and measures
2. Add dashboard composition:
   - Layout grid (2x2, 3x1, etc.)
   - Widget placement
3. Add data binding:
   - Connect to HANA tables
   - Apply filters from natural language
4. Generate SAC widget JSON schema

Also add MCP tools in the MCP server:
- sac_create_chart - create a chart widget
- sac_create_dashboard - compose multiple widgets
- sac_list_templates - list available templates

Test with: "Create a bar chart showing sales by region"
```

### Expected Output:
- [ ] Updated `sac-schema-generator.ts`
- [ ] New MCP tools in `mcp_server/server.py`
- [ ] Test file `test_sac_integration.py`

---

## Session 12: Phase 1 Completion & Verification
**Intent:** "Finalize Phase 1 and verify score improvement"

### Vibe Prompt:
```
Create a Phase 1 verification script that:

1. Deploys full stack using helm install
2. Runs all 5 tutorial test scripts
3. Measures deployment time (target: <10 minutes)
4. Checks all health endpoints
5. Tests MCP tool discovery across all servers
6. Generates a score card comparing to Microsoft Fabric

Create docs/PHASE1-COMPLETION.md with:
- All deliverables checklist
- Performance metrics
- Known issues and workarounds
- Score verification: Ease of Adoption 4→7, Breadth 6→7

Run and capture results.
```

### Expected Output:
- [ ] `scripts/verify-phase1.sh`
- [ ] `docs/PHASE1-COMPLETION.md`
- [ ] All tests passing

---

# 🔧 PHASE 2: PLATFORM EXTENSION

## Session 13: Portal Shell with Authentication
**Intent:** "Create the unified portal shell with XSUAA auth"

### Vibe Prompt:
```
Create sap-ai-fabric-console/ as a Turborepo monorepo with:

1. apps/shell/ - main portal shell with:
   - XSUAA/OAuth2 authentication flow
   - Navigation sidebar with app list
   - Top bar with user menu
   - Content area for micro-frontends
   
2. packages/ui-components/ - shared UI5/React components:
   - Button, Input, Card, Table
   - Loading spinner, Error boundary
   - Theme support (light/dark)

3. packages/mcp-client/ - unified MCP client:
   - Connect to any MCP server
   - Tool discovery and invocation
   - Streaming support

Use Vite for builds, React 18 + TypeScript.
Start with just the shell that shows "Hello, {username}".
```

### Expected Output:
- [ ] `sap-ai-fabric-console/turbo.json`
- [ ] `sap-ai-fabric-console/apps/shell/`
- [ ] `sap-ai-fabric-console/packages/ui-components/`
- [ ] `sap-ai-fabric-console/packages/mcp-client/`

---

## Session 14: Dashboard App
**Intent:** "Create the main dashboard with health metrics"

### Vibe Prompt:
```
Create apps/dashboard/ in the portal that shows:

1. System health overview:
   - Status cards for each service (green/yellow/red)
   - Last health check timestamp
   - Quick action buttons (restart, logs)

2. Metrics widgets:
   - Request rate (last hour chart)
   - Token usage (pie chart by model)
   - Active streaming sessions
   - Error rate trend

3. Quick links:
   - Recent deployments
   - Active RAG pipelines
   - Governance rule status

Fetch data from Prometheus metrics endpoint.
Use Recharts for visualizations.
```

### Expected Output:
- [ ] `apps/dashboard/` with React components
- [ ] Health check integration
- [ ] Prometheus metrics fetching

---

## Session 15: Streaming Management App
**Intent:** "Create streaming broker management UI"

### Vibe Prompt:
```
Create apps/streaming/ in the portal for ai-core-streaming management:

1. Topics view:
   - List all topics with message counts
   - Create/delete topic buttons
   - Topic details panel (partitions, retention)

2. Producers view:
   - Active producers list
   - Message rate per producer
   - Producer details

3. Consumers view:
   - Active consumers and subscriptions
   - Backlog per consumer
   - Consumer lag chart

4. Messages view:
   - Browse recent messages
   - Message search by key/content
   - Message detail with properties

Connect to ai-core-streaming admin API on port 8080.
```

### Expected Output:
- [ ] `apps/streaming/` with all views
- [ ] Admin API client

---

## Session 16: Deployments Management App
**Intent:** "Create AI Core deployment management UI"

### Vibe Prompt:
```
Create apps/deployments/ in the portal for AI Core management:

1. Deployment list:
   - All deployments with status
   - Model name, version, resource group
   - Scale info (replicas, GPU)

2. Deployment creation wizard:
   - Step 1: Select model (dropdown of available)
   - Step 2: Configure resources
   - Step 3: Set scaling rules
   - Step 4: Review and deploy

3. Deployment details:
   - Metrics (requests, latency, errors)
   - Logs viewer
   - Configuration editor
   - Delete with confirmation

Use @sap-ai-sdk/ai-api for API calls.
```

### Expected Output:
- [ ] `apps/deployments/` with wizard flow
- [ ] AI Core API integration

---

## Session 17: RAG Studio Visual Builder
**Intent:** "Create visual RAG pipeline builder"

### Vibe Prompt:
```
Create apps/rag-studio/ in the portal for visual RAG pipeline building:

1. Canvas component:
   - Drag-drop nodes onto canvas
   - Connect nodes with edges
   - Zoom/pan controls
   - Grid snap

2. Node types:
   - Source: Document upload, HANA table, URL
   - Process: Chunker, Embedder, Filter
   - Store: HANA Vector, In-memory
   - Query: Similarity search, Hybrid search
   - Output: LLM completion, Stream

3. Properties panel:
   - Select node to edit properties
   - Form fields per node type
   - Preview/test button

4. Execute button:
   - Convert graph to pipeline config
   - Run via MCP tools
   - Show results

Use React Flow for the canvas.
```

### Expected Output:
- [ ] `apps/rag-studio/` with visual builder
- [ ] Pipeline execution integration

---

## Session 18: Governance Rule Editor
**Intent:** "Create visual Mangle rule editor"

### Vibe Prompt:
```
Create apps/governance/ in the portal for Mangle rule management:

1. Rule browser:
   - Tree view of rule files
   - File content viewer with syntax highlighting
   - Search across rules

2. Visual rule builder:
   - Condition blocks (drag-drop)
   - Predicate selector
   - Variable binding
   - Generate Mangle syntax

3. Rule tester:
   - Input: sample request JSON
   - Output: routing decision, matched rules
   - Explain mode showing rule trace

4. Deploy button:
   - Save rules to ConfigMap
   - Trigger hot-reload on services

Use Monaco editor for syntax highlighting.
```

### Expected Output:
- [ ] `apps/governance/` with rule editor
- [ ] Mangle syntax highlighting

---

## Session 19: Data Explorer App
**Intent:** "Create HANA data exploration UI"

### Vibe Prompt:
```
Create apps/data-explorer/ in the portal for HANA data exploration:

1. Schema browser:
   - Tree view of schemas > tables > columns
   - Table metadata (row count, size)
   - Column types and descriptions

2. Query editor:
   - SQL editor with autocomplete
   - Run button with results table
   - Export to CSV/JSON
   - Query history

3. Vector search:
   - Embedding input (text or vector)
   - Table/column selector
   - Top-K slider
   - Algorithm selector (cosine, L2)
   - Results with similarity scores

4. Data preview:
   - First 100 rows of any table
   - Filter/sort controls
   - Inline editing (admin only)

Use @sap/hana-client via MCP.
```

### Expected Output:
- [ ] `apps/data-explorer/` with all features
- [ ] HANA MCP integration

---

## Session 20: Prompt Playground App
**Intent:** "Create LLM testing playground"

### Vibe Prompt:
```
Create apps/prompt-playground/ in the portal for LLM testing:

1. Model selector:
   - Dropdown of all available models
   - Model info (provider, context length)
   - Custom deployment URL option

2. Chat interface:
   - Message history
   - User input with send button
   - Streaming response display
   - Token count per message

3. System prompt editor:
   - Textarea with template support
   - Variable substitution preview
   - Save as template

4. Settings panel:
   - Temperature slider
   - Max tokens
   - Top-p, frequency penalty
   - Stream toggle

5. Export:
   - Copy conversation as JSON
   - Copy as curl command
   - Copy as Python code

Connect to all MCP servers for model options.
```

### Expected Output:
- [ ] `apps/prompt-playground/` with chat UI
- [ ] Multi-model support

---

## Session 21: Data Lake - Delta Lake Support
**Intent:** "Create data lake abstraction with Delta Lake"

### Vibe Prompt:
```
Create sap-data-lake-fabric/ with Delta Lake support:

1. Core abstraction in src/lakehouse/:
   - TableFormat interface (read, write, schema, history)
   - DeltaTable class implementing TableFormat
   - Transaction support (begin, commit, rollback)
   - Time travel (readVersion, readTimestamp)

2. Storage federation in src/federation/:
   - StorageBackend interface
   - S3Backend, AzureBlobBackend, GCSBackend, HANABackend
   - Unified file operations (read, write, list, delete)

3. Catalog in src/catalog/:
   - MetastoreClient interface
   - HiveMetastoreClient implementation
   - Table registration and discovery

4. MCP server in mcp_server/:
   - list_tables, get_table_schema
   - read_table, write_table
   - query_table (SQL support)

Start with Python, use delta-rs library.
```

### Expected Output:
- [ ] `sap-data-lake-fabric/` structure
- [ ] Delta Lake operations working
- [ ] S3 and local filesystem backends

---

## Session 22: Data Lake - Iceberg & Hudi
**Intent:** "Add Iceberg and Hudi table format support"

### Vibe Prompt:
```
Extend sap-data-lake-fabric/ with Iceberg and Hudi:

1. IcebergTable in src/lakehouse/:
   - Implement TableFormat interface
   - Schema evolution support
   - Partition pruning
   - Time travel

2. HudiTable in src/lakehouse/:
   - Implement TableFormat interface
   - Copy-on-write and merge-on-read modes
   - Incremental queries

3. Format detection:
   - Auto-detect table format from metadata
   - Format conversion utilities

4. Unified query layer:
   - SQL interface that works across formats
   - Pushdown predicates
   - Column pruning

Use pyiceberg and hudi-python libraries.
Add tests for each format.
```

### Expected Output:
- [ ] Iceberg support added
- [ ] Hudi support added
- [ ] Format interoperability tests

---

## Session 23: Notebooks - Jupyter Kernels
**Intent:** "Create custom Jupyter kernels for SAP stack"

### Vibe Prompt:
```
Create sap-notebooks/ with custom Jupyter kernels:

1. HANA SQL kernel in kernels/hana/:
   - Execute SQL queries
   - Display results as tables
   - Magic commands: %connect, %tables, %describe
   - Syntax highlighting for HANA SQL

2. AI Core kernel in kernels/aicore/:
   - Execute inference calls
   - Display streaming responses
   - Magic commands: %model, %deploy, %chat
   - Token usage tracking

3. Mangle kernel in kernels/mangle/:
   - Execute Mangle queries
   - Display fact/rule stores
   - Magic commands: %load, %query, %explain

4. CAP CDS kernel in kernels/cap/:
   - Compile CDS definitions
   - Display entity diagrams
   - Magic commands: %compile, %serve

Use jupyter_client for kernel implementation.
```

### Expected Output:
- [ ] `sap-notebooks/kernels/` with 4 kernels
- [ ] Installation scripts
- [ ] Example notebooks

---

## Session 24: Notebooks - JupyterHub Setup
**Intent:** "Configure JupyterHub for multi-user deployment"

### Vibe Prompt:
```
Configure JupyterHub in sap-notebooks/ for BTP deployment:

1. jupyterhub_config.py:
   - XSUAA authenticator
   - Kubernetes spawner
   - Resource limits per user
   - Custom Docker image with all kernels

2. Dockerfile:
   - JupyterLab base
   - All 4 custom kernels installed
   - SAP SDK packages
   - Data explorer extensions

3. Helm subchart for notebooks:
   - Deploy JupyterHub
   - PVC for user storage
   - NetworkPolicy for isolation

4. Extensions:
   - Data explorer sidebar
   - LLM assistant panel
   - MCP tool browser

Create deployment guide for BTP Kyma.
```

### Expected Output:
- [ ] JupyterHub configuration
- [ ] Custom Docker image
- [ ] Helm subchart

---

## Session 25: Data Lineage - Collectors
**Intent:** "Create data lineage collectors for all sources"

### Vibe Prompt:
```
Create sap-data-lineage/ with lineage collectors:

1. HANA collector in src/collectors/hana.py:
   - Parse query plans for table access
   - Track view dependencies
   - Extract column-level lineage
   - Monitor via audit log

2. AI Core collector in src/collectors/aicore.py:
   - Track prompt → model → response chains
   - Link to source documents (RAG)
   - Track token flows

3. Streaming collector in src/collectors/streaming.py:
   - Track message flows through topics
   - Producer → topic → consumer lineage
   - Schema evolution tracking

4. Graph storage in src/graph/:
   - Use kuzu for embedded graph DB
   - Node types: Table, Column, Model, Topic, Query
   - Edge types: READS, WRITES, CALLS, PRODUCES

Create collectors as background daemons.
```

### Expected Output:
- [ ] `sap-data-lineage/src/collectors/`
- [ ] Kuzu graph schema
- [ ] Collection daemon script

---

## Session 26: Data Lineage - Visualization
**Intent:** "Create interactive lineage visualization"

### Vibe Prompt:
```
Create apps/lineage/ in the portal for lineage visualization:

1. Graph view:
   - Interactive node-link diagram
   - Zoom/pan controls
   - Node filtering by type
   - Search by name

2. Impact analysis:
   - Select a table/column
   - Show all downstream dependents
   - Highlight affected pipelines
   - Estimate impact scope

3. Provenance tracking:
   - Select a data point
   - Trace back to all sources
   - Show transformation chain
   - Time-travel to specific version

4. Lineage API:
   - GET /lineage/node/:id
   - GET /lineage/downstream/:id
   - GET /lineage/upstream/:id
   - POST /lineage/search

Use D3.js or React Flow for visualization.
```

### Expected Output:
- [ ] `apps/lineage/` with graph UI
- [ ] Lineage API server

---

## Session 27: Portal Integration & Gateway
**Intent:** "Create unified API gateway and integrate all apps"

### Vibe Prompt:
```
Create the unified API gateway and complete portal integration:

1. Gateway in sap-ai-fabric-console/gateway/:
   - Route /api/streaming/* to ai-core-streaming
   - Route /api/mcp/* to all MCP servers
   - Route /api/hana/* to HANA connector
   - Route /api/lineage/* to lineage service
   - Rate limiting per user
   - Request logging

2. Portal app registration:
   - apps/dashboard/ at /
   - apps/streaming/ at /streaming
   - apps/deployments/ at /deployments
   - apps/rag-studio/ at /rag
   - apps/governance/ at /governance
   - apps/data-explorer/ at /data
   - apps/prompt-playground/ at /playground
   - apps/lineage/ at /lineage

3. Navigation config:
   - Sidebar with all apps
   - Icons for each app
   - Active state highlighting

4. Build & deploy:
   - Single Docker image
   - Helm subchart for portal
```

### Expected Output:
- [ ] Gateway service
- [ ] All apps integrated
- [ ] Helm chart for portal

---

## Session 28: Phase 2 Helm Update
**Intent:** "Update Helm chart with all Phase 2 components"

### Vibe Prompt:
```
Update sap-ai-fabric-helm/ to include all Phase 2 components:

1. Add subcharts:
   - sap-ai-fabric-console (portal)
   - sap-data-lake-fabric
   - sap-notebooks (JupyterHub)
   - sap-data-lineage

2. Update values.yaml:
   - Enable/disable each component
   - Resource profiles (small, medium, large)
   - Persistence configuration
   - Ingress configuration

3. Add optional dependencies:
   - Prometheus stack (if metrics enabled)
   - Grafana dashboards
   - Cert-manager (if TLS enabled)

4. Create installation profiles:
   - minimal: just core + portal
   - standard: all except notebooks
   - full: everything

Update README with new installation options.
```

### Expected Output:
- [ ] Updated Helm chart v2.0.0
- [ ] Installation profiles
- [ ] Updated documentation

---

## Session 29: E2E Testing Suite
**Intent:** "Create comprehensive E2E test suite"

### Vibe Prompt:
```
Create tests/e2e/ with comprehensive end-to-end tests:

1. Deployment tests:
   - Deploy full stack
   - Verify all services healthy
   - Test service discovery

2. RAG pipeline tests:
   - Upload document
   - Generate embeddings
   - Store in HANA vector
   - Query and verify results

3. Streaming tests:
   - Create topic
   - Produce messages
   - Consume and verify
   - Test backpressure

4. Governance tests:
   - Test public routing
   - Test confidential routing
   - Test blocked requests
   - Test rule updates

5. Portal tests (Playwright):
   - Login flow
   - Navigate all apps
   - Create a RAG pipeline
   - Run a query

Use pytest for Python tests, Playwright for UI tests.
```

### Expected Output:
- [ ] `tests/e2e/` with all test suites
- [ ] CI configuration
- [ ] Test reports

---

## Session 30: Phase 2 Completion
**Intent:** "Finalize Phase 2 and verify improvements"

### Vibe Prompt:
```
Complete Phase 2 with:

1. Verification script:
   - Deploy full Phase 2 stack
   - Run all E2E tests
   - Measure key metrics:
     - Portal load time (<3s)
     - RAG query latency (<5s)
     - Notebook startup (<30s)
   - Generate score comparison

2. Documentation:
   - Update all READMEs
   - Add Phase 2 tutorials (5 more)
   - Architecture diagrams
   - API reference

3. Release:
   - Tag v2.0.0
   - Create GitHub release
   - Update CHANGELOG

4. docs/PHASE2-COMPLETION.md:
   - Deliverables checklist
   - Score: Ease 7→9, Breadth 7→8.5
   - Known issues
   - Phase 3 preview
```

### Expected Output:
- [ ] `scripts/verify-phase2.sh`
- [ ] `docs/PHASE2-COMPLETION.md`
- [ ] v2.0.0 release

---

# 🏆 PHASE 3: PARITY PLUS

## Session 31-40: Visual Pipeline Builder
**Intent:** Build complete visual ETL/ML pipeline builder

Sessions:
- 31: Pipeline DSL definition and parser
- 32: Visual canvas with drag-drop
- 33: Node types (source, transform, sink)
- 34: Executor runtime (Spark, HANA, AI Core)
- 35: Scheduling (cron, event triggers)
- 36: Monitoring and logging
- 37: Git integration and versioning
- 38: Testing framework
- 39: MCP tools integration
- 40: Documentation and tutorials

---

## Session 41-46: Collaboration Features
**Intent:** Build real-time collaboration system

Sessions:
- 41: WebSocket server and CRDT integration
- 42: Notebook co-editing
- 43: Pipeline co-editing
- 44: Comment/annotation system
- 45: Team workspaces and RBAC
- 46: Notification system

---

## Session 47-52: Semantic Layer
**Intent:** Build unified semantic layer

Sessions:
- 47: Business glossary backend
- 48: AI-powered term matching
- 49: Metric definition system
- 50: Cross-source semantic joins
- 51: Natural language to SQL
- 52: Portal integration and documentation

---

## Session 53-56: Final Integration & Release
**Intent:** Complete parity and release

Sessions:
- 53: Full integration testing
- 54: Performance optimization
- 55: Security audit and fixes
- 56: GA release and documentation

---

# 📋 Vibe Coding Session Template

For each session, use this template:

```markdown
## Session [N]: [Title]

### Start Time: ___________

### Intent
[One sentence describing what you want to build]

### Vibe Prompt
```
[Copy the full prompt here]
```

### Progress Checkpoints
- [ ] Initial generation complete
- [ ] Code compiles/runs
- [ ] Tests pass
- [ ] Integrated with existing code

### Output Files
- [ ] File 1
- [ ] File 2
- [ ] ...

### Issues Encountered
- 

### Time Spent: ___________

### Next Session Prep
- 
```

---

# 🎯 Success Metrics

Track these after each phase:

| Metric | Phase 1 | Phase 2 | Phase 3 |
|--------|---------|---------|---------|
| Deployment time | <10 min | <15 min | <15 min |
| Tutorial count | 5 | 10 | 15 |
| Portal apps | 0 | 8 | 12 |
| MCP tools | 20 | 40 | 60 |
| E2E tests | 10 | 50 | 100 |
| Score | 72/80 | 76.5/80 | 79/80 |

---

# 🚦 Getting Started

1. Open this file alongside Cline/Claude
2. Start with Session 1
3. Copy the Vibe Prompt into the chat
4. Let AI generate the code
5. Review, test, commit
6. Move to next session
7. Track progress in the checkboxes

**Let's vibe! 🎵**