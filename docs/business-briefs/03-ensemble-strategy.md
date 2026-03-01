# The Ensemble in Action: A Request's Journey

**For:** 🏛 Architects, 🔐 Security Officers

> This architecture leverages **SAP Open Source libraries** from [github.com/SAP](https://github.com/SAP) orchestrated via **SAP AI Core**.

---

## The Request Journey: User to Answer in 2.3 Seconds

```mermaid
sequenceDiagram
    participant User as 👤 Controller
    participant UI as 🖥 UI5 Chat
    participant SDK as 🎯 AI SDK
    participant CAP as 📦 CAP Plugin
    participant HANA as 💾 HANA Cloud
    participant Mangle as 🔒 Mangle
    participant LLM as 🤖 LLM (AI Core)
    participant Stream as ⚡ Streaming
    
    Note over User,Stream: Total time: 2.3 seconds
    
    User->>UI: "Why is Q3 EBITDA down in EMEA?"
    activate UI
    UI->>SDK: Route query (0.1s)
    activate SDK
    
    SDK->>CAP: Request context
    activate CAP
    CAP->>HANA: Vector search ACDOCA
    HANA-->>CAP: 23 relevant entries (0.5s)
    CAP->>Mangle: Anonymize PII
    Mangle-->>CAP: "[VENDOR_012]" (0.15s)
    CAP-->>SDK: Enriched context (0.8s total)
    deactivate CAP
    
    SDK->>LLM: Grounded prompt
    activate LLM
    LLM-->>Stream: Token stream begins
    deactivate LLM
    activate Stream
    Stream-->>UI: First token at 1.1s
    Stream-->>UI: Streaming... (1.2s)
    deactivate Stream
    
    UI-->>User: Complete answer at 2.3s
    deactivate SDK
    deactivate UI
```

---

## Stage Details

### Stage 1: Interaction (0-0.1s)

```mermaid
flowchart LR
    subgraph Stage1["🖥 STAGE 1: INTERACTION"]
        User["👤 User"] --> UI["UI5 Chat"]
        UI --> |"Validate"| Val["Input Validation"]
        Val --> |"Context"| Ctx["User Context<br/>(role, permissions)"]
        Ctx --> |"Connect"| SSE["SSE Connection"]
    end
    
    SSE --> SDK["🎯 AI SDK"]
```

| Action | Component | Time |
|--------|-----------|------|
| Input validation | UI5 Chat | 20ms |
| User context attachment | XSUAA | 50ms |
| SSE connection established | Streaming Core | 30ms |

### Stage 2: Contextualization & Security (0.1-0.9s)

```mermaid
flowchart TB
    subgraph Stage2["📦 STAGE 2: CONTEXT & SECURITY"]
        SDK["AI SDK"] --> CAP["CAP LLM Plugin"]
        CAP --> Parse["1. Parse Intent<br/>'EBITDA' + 'Q3' + 'EMEA'"]
        Parse --> Search["2. HANA Vector Search<br/>23 ACDOCA entries"]
        Search --> Vocab["3. Semantic Lookup<br/>EBITDA → OData definition"]
        Vocab --> Anon["4. Anonymize<br/>'Customer ABC' → '[CUST_001]'"]
    end
```

| Action | Technology | Time |
|--------|------------|------|
| Intent parsing | CAP service | 50ms |
| Vector search | HANA Cloud | 500ms |
| Vocabulary lookup | OData service | 100ms |
| PII anonymization | Mangle layer | 150ms |

### Stage 3: Governance & Orchestration (0.9-1.1s)

```mermaid
flowchart TB
    subgraph Stage3["🎯 STAGE 3: ORCHESTRATION"]
        CAP["Enriched Context"] --> SDK["AI SDK Orchestration"]
        SDK --> Model["1. Model Selection<br/>GPT-4 (complex reasoning)"]
        Model --> Safety["2. Safety Filter<br/>Block M&A data requests"]
        Safety --> Ground["3. Grounding<br/>Attach HANA context"]
        Ground --> Tools["4. Tool Registration<br/>PAL forecast available"]
    end
```

| Action | Technology | Time |
|--------|------------|------|
| Model selection | AI SDK routing | 50ms |
| Safety filtering | Content filter | 30ms |
| Context grounding | SDK orchestrator | 80ms |
| Tool registration | MCP protocol | 40ms |

### Stage 4: High-Performance Delivery (1.1-2.3s)

```mermaid
flowchart LR
    subgraph Stage4["⚡ STAGE 4: STREAMING"]
        LLM["LLM (AI Core)"] --> |"Tokens"| Stream["Streaming Core"]
        Stream --> |"SSE"| UI["UI5 Chat"]
        UI --> |"Real-time"| User["👤 User"]
    end
    
    Note["First token: 1.1s<br/>Complete: 2.3s<br/>150 tokens streamed"]
```

| Action | Technology | Time |
|--------|------------|------|
| Token generation | LLM (GPT-4) | 1100ms |
| SSE streaming | Zig async I/O | <5ms latency |
| Total response | 150 tokens | 1200ms |

---

## Key Synergies

### RAG + Orchestration

```mermaid
flowchart LR
    subgraph CAP["📦 CAP Plugin"]
        HANA["23 ACDOCA entries"]
        Vocab["OData definitions"]
    end
    
    subgraph SDK["🎯 AI SDK"]
        Ground["Grounding Module"]
        Prompt["Grounded Prompt:<br/>'Based on these 23 entries...'"]
    end
    
    HANA --> Ground
    Vocab --> Ground
    Ground --> Prompt
```

### Defense in Depth

```mermaid
flowchart TB
    subgraph Security["🔒 DEFENSE IN DEPTH"]
        L1["Layer 1: NETWORK<br/>XSUAA at Streaming Core"]
        L2["Layer 2: DATA<br/>Mangle Anonymization"]
        L3["Layer 3: CONTENT<br/>AI SDK Safety Filter"]
    end
    
    Request["Request"] --> L1
    L1 --> L2
    L2 --> L3
    L3 --> LLM["LLM"]
```

| Layer | Protection | Component |
|-------|------------|-----------|
| **Network** | Token validation, role-based access | XSUAA + Streaming Core |
| **Data** | PII masking, data classification | Mangle layer |
| **Content** | Harmful content blocking, compliance | AI SDK Safety Filter |

---

## Failure Handling & Resilience

```mermaid
flowchart TB
    subgraph Resilience["🛡 RESILIENCE PATTERNS"]
        direction TB
        
        subgraph Primary["Primary Path"]
            GPT["GPT-4 (Azure)"]
            HANA["HANA Vector"]
        end
        
        subgraph Failover["Failover Path"]
            VLLM["vLLM (Local)"]
            Cache["Redis Cache"]
        end
        
        GPT --> |"IF UNAVAILABLE"| VLLM
        HANA --> |"IF TIMEOUT"| Cache
    end
    
    Router["AI SDK Router"] --> GPT
    Router --> HANA
```

### Failure Scenarios

| Failure | Detection | Recovery | User Impact |
|---------|-----------|----------|-------------|
| **LLM Provider Down** | SDK health check | Auto-failover to vLLM | <3s delay |
| **HANA Timeout** | 5s timeout | Serve cached context | Degraded + warning |
| **Streaming Overload** | Load threshold | Horizontal scale-out | Queue delay |
| **PII Leak Attempt** | Mangle detection | Block + alert | Request rejected |

### Circuit Breaker

```typescript
// AI SDK implements circuit breaker pattern
const response = await aiSdk.orchestration.complete({
  model: 'gpt-4',
  fallback: {
    provider: 'vllm-local',
    maxLatency: 5000,
    healthCheck: '/v1/health'
  },
  resilience: {
    retries: 3,
    backoff: 'exponential',
    circuitBreaker: {
      failureThreshold: 5,
      resetTimeout: 30000
    }
  }
});
```

---

## Cost-Optimized Model Routing

```mermaid
flowchart TB
    subgraph Routing["💰 COST-OPTIMIZED ROUTING"]
        Query["User Query"] --> Analyze["Complexity Analysis"]
        
        Analyze --> |"Simple"| GPT35["GPT-3.5<br/>$0.002/query"]
        Analyze --> |"Complex"| GPT4["GPT-4<br/>$0.06/query"]
        Analyze --> |"Forecast"| PAL["GPT-4 + PAL<br/>$0.10/query"]
        Analyze --> |"Sensitive"| VLLM["vLLM Local<br/>Internal cost"]
    end
```

### Routing Decision Flow

```mermaid
flowchart LR
    Query["Query"] --> TokenCount{"Token<br/>Count?"}
    TokenCount --> |"<50"| Simple["Simple"]
    TokenCount --> |">50"| Intent{"Intent?"}
    
    Intent --> |"Lookup"| Simple
    Intent --> |"Analysis"| Complex["Complex"]
    Intent --> |"Forecast"| Forecast["Forecast"]
    
    Simple --> GPT35["GPT-3.5"]
    Complex --> Sensitive{"Sensitive<br/>Data?"}
    Forecast --> GPT4PAL["GPT-4 + PAL"]
    
    Sensitive --> |"No"| GPT4["GPT-4"]
    Sensitive --> |"Yes"| VLLM["vLLM Local"]
```

### Cost Savings Example

| Usage Pattern | Without Routing | With Routing | Savings |
|---------------|----------------|--------------|---------|
| 10,000 simple queries | $600 | $20 | 97% |
| 5,000 complex queries | $300 | $300 | 0% |
| 1,000 sensitive queries | $60 (risk) | $0 | 100% + security |
| **Monthly Total** | **$960** | **$320** | **67%** |

---

## Summary: The Ensemble Advantage

| Capability | How It's Achieved | Business Value |
|------------|-------------------|----------------|
| **Speed** | Zig streaming + SSE | 2.3s response |
| **Accuracy** | HANA RAG + OData | No hallucinations |
| **Security** | Defense-in-depth | Zero PII exposure |
| **Resilience** | Circuit breaker | 99.9% availability |
| **Cost** | Intelligent routing | 67% reduction |

---

## Next Steps

- **[04-ensemble-of-services.md](04-ensemble-of-services.md)** — Deep dive into all 13 services
- **[00-glossary.md](00-glossary.md)** — Definitions of terms used in this document

---

*Version 2.0 | Updated 2026-02-27*