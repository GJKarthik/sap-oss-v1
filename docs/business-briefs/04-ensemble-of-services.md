# The Collective Intelligence Framework: 13 Services

**For:** 👩‍💻 Developers, 🏛 Architects

> This architecture leverages **SAP Open Source libraries** from [github.com/SAP](https://github.com/SAP) orchestrated via **SAP AI Core**.

---

## The Five Pillars of Enterprise AI

```mermaid
flowchart TB
    subgraph Interaction["🖥 INTERACTION"]
        UI["UI5 Web Components"]
        ODATA["OData Vocabularies"]
    end
    
    subgraph Orchestration["🎯 ORCHESTRATION"]
        SDK["AI SDK JS"]
        CAP["CAP LLM Plugin"]
        LC["LangChain Integration"]
    end
    
    subgraph Intelligence["🧠 INTELLIGENCE"]
        PAL["MCP PAL"]
        Copilot["Data Cleaning Copilot"]
        Toolkit["GenAI Toolkit"]
    end
    
    subgraph Foundation["⚡ FOUNDATION"]
        Stream["Streaming Core"]
        VLLM["vLLM Engine"]
        Mangle["Mangle Query"]
        HVS["HANA Vector Store"]
    end
    
    subgraph Governance["👁 GOVERNANCE"]
        Monitor["World Monitor"]
    end
    
    Interaction --> Orchestration
    Orchestration --> Intelligence
    Orchestration --> Foundation
    Intelligence --> Foundation
    Monitor -.-> Interaction
    Monitor -.-> Orchestration
    Monitor -.-> Intelligence
    Monitor -.-> Foundation
```

| Pillar | Services | Purpose |
|--------|----------|---------|
| **Interaction** | UI5 Web Components, OData Vocabularies | User interface, semantic standards |
| **Orchestration** | AI SDK, CAP LLM Plugin, LangChain | Model routing, RAG, privacy |
| **Intelligence** | MCP PAL, Data Copilot, GenAI Toolkit | Forecasting, data quality, ML |
| **Foundation** | Streaming Core, vLLM, Mangle, HANA Vector Store | Performance, search, transformation |
| **Governance** | World Monitor | Observability, tracing, audit |

---

## Service Flow Architecture

```mermaid
flowchart TD
    subgraph InteractionLayer["Interaction & Observability"]
        UI["UI5 Angular (1)"]
        WM["World Monitor (13)"]
    end

    subgraph OrchestrationLayer["Orchestration & Logic"]
        SDK["AI SDK JS (2)"]
        CAP["CAP LLM Plugin (3)"]
        ODATA["OData Vocabularies (11)"]
    end

    subgraph InferenceLayer["High Performance & Inference"]
        STR["Streaming Core (4)"]
        VLLM["vLLM Engine (12)"]
        PAL["MCP PAL (5)"]
    end

    subgraph DataLayer["Data & Knowledge Base"]
        HANA["SAP HANA Cloud"]
        HVS["HANA Vector Store (7)"]
        MANGLE["Mangle Query (10)"]
    end

    subgraph AgenticLayer["Agentic & Science Tools"]
        COPILOT["Data Cleaning Copilot (6)"]
        TK["GenAI Toolkit (8)"]
        LC["LangChain Integration (9)"]
    end

    UI --> SDK
    SDK --> STR
    STR --> UI
    SDK <--> ODATA
    SDK --> CAP
    CAP --> HANA
    SDK --> PAL
    PAL --> HANA
    TK --> HANA
    LC --> HANA
    COPILOT --> HANA
    MANGLE --> ES
    SDK --> VLLM
    WM -.-> UI
    WM -.-> SDK
    WM -.-> STR
```

---

## Reasoning Chain Deep Dive

### Semantic Standard (OData Vocabularies)

```mermaid
flowchart LR
    subgraph Semantic["OData Vocabularies"]
        Def["Definitions"]
        Ann["Annotations"]
    end
    
    subgraph Services["All Services"]
        S1["Service 1"]
        S2["Service 2"]
        SN["Service N"]
    end
    
    Def --> S1
    Def --> S2
    Def --> SN
    Ann --> S1
    Ann --> S2
    Ann --> SN
```

| Aspect | Reasoning | Technology |
|--------|-----------|------------|
| **Purpose** | "All services use same definition for 'EBITDA'" | OData `sap.ai.prompt.Prompt` type |
| **Finance Example** | Same calculation across chat, PAL, dashboard | `@Analytics.Measure` on ACDOCA |

### Predictive Bridge (MCP PAL)

```mermaid
flowchart LR
    Query["Forecast Query"] --> SDK["AI SDK"]
    SDK --> |"MCP Tool"| PAL["MCP PAL"]
    PAL --> |"PAL Function"| HANA["HANA Cloud"]
    HANA --> Result["Forecast Result"]
```

| Aspect | Reasoning | Technology |
|--------|-----------|------------|
| **Purpose** | "This needs math, not just text" | HANA PAL `ARIMA_FORECAST` |
| **Finance Example** | "Project next quarter revenue" | MCP `pal_forecast` tool |

---

## Business Value

### Value 1: Resilience

```mermaid
flowchart LR
    GPT["GPT-4<br/>(Primary)"] --> |"UNAVAILABLE"| VLLM["vLLM<br/>(Fallback)"]
    VLLM --> User["User sees:<br/><3s delay"]
```

### Value 2: Modularity

```mermaid
flowchart LR
    subgraph Update["LangChain v0.2 → v0.3"]
        LC["LangChain"]
    end
    
    subgraph Unchanged["Unchanged"]
        STR["Streaming Core"]
        AUTH["XSUAA Auth"]
    end
    
    LC -.-> |"No impact"| STR
    LC -.-> |"No impact"| AUTH
```

### Value 3: Extensibility

```mermaid
flowchart TB
    subgraph NewService["New: Supply Chain Optimizer"]
        API["/v1/chat/completions"]
        MCP["MCP Tools"]
        OTEL["OpenTelemetry"]
    end
    
    subgraph Existing["Existing Infrastructure"]
        SDK["AI SDK"]
        WM["World Monitor"]
    end
    
    API --> SDK
    MCP --> SDK
    OTEL --> WM
```

**Integration time: ~2 hours (no SDK changes)**

---

## The 13 Services Quick Reference

| # | Service | Pillar | SAP Repository | Finance Use Case |
|---|---------|--------|----------------|------------------|
| 1 | UI5 Web Components | Interaction | `SAP/ui5-webcomponents-ngx` | Chat dashboard |
| 2 | AI SDK JS | Orchestration | `SAP/ai-sdk-js` | Model routing |
| 3 | CAP LLM Plugin | Orchestration | `SAP/cap-llm-plugin` | ACDOCA RAG |
| 4 | Streaming Core | Foundation | Custom (Zig) | Real-time delivery |
| 5 | MCP PAL | Intelligence | Custom | Sales forecast |
| 6 | Data Cleaning Copilot | Intelligence | Custom | Data quality audit |
| 7 | HANA Vector Store | Foundation | SAP HANA Cloud | Knowledge search |
| 8 | GenAI Toolkit | Intelligence | `SAP/generative-ai-toolkit-for-sap-hana-cloud` | Custom ML |
| 9 | LangChain Integration | Orchestration | `SAP/langchain-integration-for-sap-hana-cloud` | Vector store |
| 10 | Mangle Query | Foundation | Custom | Log transformation |
| 11 | OData Vocabularies | Interaction | Custom | Semantic definitions |
| 12 | vLLM | Foundation | vLLM | Private LLM |
| 13 | World Monitor | Governance | Custom | Observability |

---

## Next Steps

- **[05-oss-adaptation-strategy.md](05-oss-adaptation-strategy.md)** — How SAP OSS was hardened
- **[06-architectural-patterns.md](06-architectural-patterns.md)** — The four design patterns

---

*Version 2.0 | Updated 2026-02-27*