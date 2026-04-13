# Component Mapping: Building a Multi-Layered Enterprise AI Stack

**For:** 🏛 Architects, 👩‍💻 Developers

> This architecture leverages **SAP Open Source libraries** from [github.com/SAP](https://github.com/SAP) orchestrated via **SAP AI Core**.

---

## Quick Reference: Component-to-Problem Mapping

| Component | SAP OSS Repository | Problem Solved | Finance Use Case |
|-----------|-------------------|----------------|------------------|
| **UI5 Web Components** | `SAP/ui5-webcomponents-ngx` | Inconsistent UI/UX | Standard chat interface |
| **CAP LLM Plugin** | `SAP/cap-llm-plugin` | Data Gap & PII Risk | Auto-retrieve ACDOCA, mask names |
| **AI SDK JS** | `SAP/ai-sdk-js` | Provider Fragmentation | Switch GPT-4/Claude in config |
| **Streaming Core** | Custom (streaming) | Performance & Scale | 50 concurrent users at month-end |

---

## Component Architecture

```mermaid
flowchart TB
    subgraph Layer1["🖥 LAYER 1: INTERACTION"]
        UI["UI5 Web Components<br/>SAP/ui5-webcomponents-ngx"]
        ODATA["OData Vocabularies<br/>Semantic definitions"]
    end
    
    subgraph Layer2["🎯 LAYER 2: ORCHESTRATION"]
        SDK["SAP AI SDK<br/>SAP/ai-sdk-js"]
        CAP["CAP LLM Plugin<br/>SAP/cap-llm-plugin"]
        LC["LangChain Integration<br/>SAP/langchain-integration-for-sap-hana-cloud"]
    end
    
    subgraph Layer3["📦 LAYER 3: CONTEXT & SECURITY"]
        DP["Data prep layer<br/>PII Anonymization"]
        RAG["RAG Pipeline<br/>Vector Search"]
    end
    
    subgraph Layer4["⚡ LAYER 4: FOUNDATION"]
        STR["Streaming Core<br/>native SSE"]
        HANA["SAP HANA Cloud<br/>Vectors, PAL"]
    end
    
    UI --> SDK
    SDK --> CAP
    SDK --> LC
    CAP --> MNG
    CAP --> RAG
    RAG --> HANA
    SDK --> STR
    STR --> UI
```

---

## 1. Frontend Layer: UI5 Web Components for Angular

**Problem Addressed**: Inconsistent AI UI/UX and Accessibility.

The **`SAP/ui5-webcomponents-ngx`** library provides ready-to-use, enterprise-themed Angular components (chat panels, result viewers, markdown renderers) that ensure a consistent experience across AI applications.

### Capabilities
- **Chat Components**: Pre-built conversation UI with streaming support
- **Result Renderers**: Markdown, tables, charts for AI responses
- **Accessibility**: WCAG 2.1 compliant, keyboard navigation, screen reader support

```mermaid
flowchart LR
    subgraph UI5["UI5 Web Components"]
        Chat["ui5-chat<br/>Conversation panel"]
        Render["ui5-markdown<br/>Result renderer"]
        Table["ui5-table<br/>Data display"]
    end
    
    User["👤 User"] --> Chat
    Chat --> |"Streaming"| Render
    Render --> Table
```

| Aspect | Value |
|--------|-------|
| **Development Time** | 60% faster than custom UI |
| **Consistency** | SAP Fiori design language |
| **Repository** | [SAP/ui5-webcomponents-ngx](https://github.com/SAP/ui5-webcomponents-ngx) |

---

## 2. Middleware Layer: CAP LLM Plugin

**Problem Addressed**: The Enterprise Data Gap & Data Privacy (PII).

The **`SAP/cap-llm-plugin`** acts as the intelligent bridge between enterprise data and the LLM. It automates the Retrieval-Augmented Generation (RAG) process.

### Capabilities

| Capability | Function | Finance Relevance |
|------------|----------|-------------------|
| **HANA Vector Search** | Retrieves relevant enterprise context from SAP HANA Cloud | Find similar past variance explanations |
| **Anonymization Engine** | Automatically detects and masks sensitive data (PII) | Remove customer names, employee IDs |
| **Semantic Enrichment** | Adds metadata from OData vocabularies | AI understands "BUKRS" means Company Code |

### How It Solves the Data Gap

```mermaid
sequenceDiagram
    participant User as 👤 User
    participant CAP as 📦 CAP Plugin
    participant HANA as 💾 HANA Cloud
    participant DataPrep as 🔒 Data prep
    participant SDK as 🎯 AI SDK
    
    User->>CAP: "What caused Q3 cost overrun?"
    CAP->>HANA: Vector search: "cost" + "Q3"
    HANA-->>CAP: 47 relevant ACDOCA rows
    CAP->>DataPrep: Raw data with PII
    DataPrep-->>CAP: Anonymized data
    CAP->>CAP: Enrich with OData vocab
    CAP-->>SDK: Clean, enriched context
    SDK-->>User: Specific, actionable answer
```

| Aspect | Value |
|--------|-------|
| **Security** | Zero PII sent to external LLMs |
| **Accuracy** | Responses grounded in actual HANA data |
| **Repository** | [SAP/cap-llm-plugin](https://github.com/SAP/cap-llm-plugin) |

---

## 3. SDK Layer: SAP AI SDK for JavaScript

**Problem Addressed**: Model Provider Fragmentation and Orchestration.

The **`SAP/ai-sdk-js`** standardizes access to multiple foundation models and the SAP AI Core Generative AI Hub.

### Capabilities

| Capability | Function | Finance Relevance |
|------------|----------|-------------------|
| **Model Abstraction** | Single API for OpenAI, Gemini, Claude, local vLLM | Use best model per task |
| **Safety Filtering** | Enforces content filtering to prevent harmful outputs | Block inappropriate content |
| **Grounding** | Ensures responses tied to provided context | Prevent hallucinated numbers |
| **Tool Calling** | Invoke MCP tools during reasoning | Call PAL for forecast |

### Provider Flexibility

```mermaid
flowchart TB
    subgraph SDK["SAP AI SDK"]
        Router["Model Router"]
        Safety["Safety Filter"]
        Ground["Grounding"]
    end
    
    subgraph Providers["LLM Providers via AI Core"]
        GPT["Azure OpenAI<br/>GPT-4"]
        Claude["Anthropic<br/>Claude"]
        Gemini["Google<br/>Gemini"]
        VLLM["Private<br/>vLLM"]
    end
    
    App["Application"] --> SDK
    Router --> GPT
    Router --> Claude
    Router --> Gemini
    Router --> VLLM
```

```typescript
// Unified SDK (single interface for all providers)
import { OrchestrationClient } from '@sap-ai-sdk/orchestration';

const response = await client.chatCompletion({
  model: 'gpt-4',  // or 'claude-3' or 'gemini-pro' or 'vllm-local'
  messages: [{ role: 'user', content: message }],
  safetyFilter: 'enterprise',
  grounding: { source: 'hana-vectors' }
});
```

| Aspect | Value |
|--------|-------|
| **Lock-in Prevention** | Switch providers in config, not code |
| **Governance** | Single enforcement point for safety, cost, logging |
| **Repository** | [SAP/ai-sdk-js](https://github.com/SAP/ai-sdk-js) |

---

## 4. Streaming Core: High-Performance Gateway

**Problem Addressed**: Real-Time Performance and Scalability.

The Streaming Core is a high-performance, low-latency engine designed for massive throughput. Built for low-latency streaming, it acts as a high-performance gateway for AI responses.

### Why a dedicated streaming gateway?

| Aspect | Benefit | Alternative Comparison | When to Use |
|--------|---------|----------------------|-------------|
| **Performance** | C-level speed, no GC pauses | 10x faster than Node.js | All external-facing streaming |
| **Memory Safety** | Compile-time guarantees | Safer than C | High-concurrency endpoints |
| **Concurrency** | Native async I/O, 10,000+ connections | 5x more than Python | Month-end close scenarios |
| **Resource Efficiency** | 50MB for 1,000 streams | Node.js needs 500MB+ | Cost-sensitive deployments |

### Deployment Architecture

```mermaid
flowchart TB
    subgraph Users["👥 Users (1,000 concurrent)"]
        U1["User 1"]
        U2["User 2"]
        UN["User N"]
    end
    
    subgraph Gateway["⚡ Streaming Core (native)"]
        LB["Load Balancer"]
        SSE["SSE Manager<br/>async I/O"]
        AUTH["XSUAA Auth<br/>native"]
        BUF["Token Buffer<br/>zero-copy"]
    end
    
    subgraph Backend["🎯 Backend"]
        SDK["AI SDK"]
        LLM["LLM Provider"]
    end
    
    U1 --> LB
    U2 --> LB
    UN --> LB
    LB --> SSE
    SSE --> AUTH
    SSE --> BUF
    BUF --> SDK
    SDK --> LLM
    
    style Gateway fill:#f9f,stroke:#333
```

| Aspect | Value |
|--------|-------|
| **User Experience** | "Speed of thought" interactivity |
| **Scalability** | 50 concurrent users during month-end |
| **Metrics** | Memory: 50MB | Latency: <5ms | Throughput: 50K tokens/s |

---

## Component Interdependencies

Understanding deployment ordering and dependencies:

```mermaid
flowchart LR
    subgraph Foundation["Deploy First"]
        HANA["HANA Cloud"]
        XSUAA["XSUAA"]
    end
    
    subgraph Core["Deploy Second"]
        STR["Streaming Core"]
        DP["Data prep service"]
    end
    
    subgraph Services["Deploy Third"]
        CAP["CAP LLM Plugin"]
        SDK["AI SDK"]
    end
    
    subgraph Frontend["Deploy Last"]
        UI["UI5 Components"]
    end
    
    HANA --> CAP
    XSUAA --> STR
    XSUAA --> SDK
    STR --> SDK
    MNG --> CAP
    CAP --> SDK
    SDK --> UI
```

| Component | Depends On | Deployment Order |
|-----------|------------|------------------|
| HANA Cloud | — | 1st |
| XSUAA | — | 1st |
| Streaming Core | XSUAA | 2nd |
| Data prep service | HANA | 2nd |
| CAP LLM Plugin | HANA, data prep | 3rd |
| AI SDK | XSUAA, Streaming, CAP | 4th |
| UI5 Components | AI SDK | 5th |

---

## Summary: The Four Layers Working Together

```mermaid
flowchart TB
    subgraph L1["LAYER 1: INTERACTION"]
        direction LR
        L1A["How users interact with AI"]
        L1B["Chat panels, accessibility, Fiori design"]
    end
    
    subgraph L2["LAYER 2: ORCHESTRATION"]
        direction LR
        L2A["How the system coordinates AI"]
        L2B["Model selection, safety, grounding, tools"]
    end
    
    subgraph L3["LAYER 3: CONTEXT"]
        direction LR
        L3A["How enterprise data reaches AI"]
        L3B["HANA vector search, PII anonymization, RAG"]
    end
    
    subgraph L4["LAYER 4: FOUNDATION"]
        direction LR
        L4A["How responses reach users fast"]
        L4B["SSE streaming, XSUAA auth, scaling"]
    end
    
    L1 --> L2
    L2 --> L3
    L3 --> L4
```

---

## Next Steps

- **[03-ensemble-strategy.md](03-ensemble-strategy.md)** — See how these layers work together in a real request flow
- **[00-glossary.md](00-glossary.md)** — Definitions of terms used in this document

---

*Version 2.0 | Updated 2026-02-27*