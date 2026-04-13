# Glossary of Terms

**For:** 🏢 👩‍💻 🏛 All audiences

> Quick reference for terms used in the SAP AI Suite documentation.

---

## Core Concepts

| Term | Definition | Document Reference |
|------|------------|-------------------|
| **SAP AI Core** | SAP's managed AI infrastructure on BTP for model deployment and orchestration | [01](01-enterprise-ai-problem.md), [02](02-component-mapping.md) |
| **SAP AI Suite** | Collection of SAP OSS libraries from [github.com/SAP](https://github.com/SAP) for enterprise AI | All documents |
| **Ensemble** | The coordinated group of 13 services working together | [03](03-ensemble-strategy.md), [04](04-ensemble-of-services.md) |

---

## Architectural Patterns

| Term | Definition | Document Reference |
|------|------------|-------------------|
| **Agentic Reasoning** | AI systems that Plan → Act → Observe → Correct autonomously | [06](06-architectural-patterns.md) |
| **Data prep** | Data transformation layer for anonymization, formatting, filtering | [02](02-component-mapping.md), [06](06-architectural-patterns.md) |
| **MCP** | Model Context Protocol — enables AI to discover and use tools | [04](04-ensemble-of-services.md), [06](06-architectural-patterns.md) |
| **OpenAI Compliance** | Standard `/v1/chat/completions` API across all services | [06](06-architectural-patterns.md) |
| **RAG** | Retrieval-Augmented Generation — adding enterprise context to prompts | [02](02-component-mapping.md), [03](03-ensemble-strategy.md) |

---

## SAP Finance Terms

| Term | Definition | Used In |
|------|------------|---------|
| **ACDOCA** | Universal Journal table in SAP S/4HANA (FI/CO integration) | Context examples |
| **BUKRS** | Company Code field in SAP | Data examples |
| **DSO** | Days Sales Outstanding — receivables collection metric | Problem scenarios |
| **EBITDA** | Earnings Before Interest, Taxes, Depreciation, Amortization | Query examples |
| **KUNNR** | Customer Number field in SAP | Anonymization examples |

---

## SAP OSS Components

| Component | SAP Repository | Purpose |
|-----------|----------------|---------|
| **AI SDK JS** | [SAP/ai-sdk-js](https://github.com/SAP/ai-sdk-js) | Model orchestration, safety, routing |
| **CAP LLM Plugin** | [SAP/cap-llm-plugin](https://github.com/SAP/cap-llm-plugin) | RAG pipeline, PII anonymization |
| **UI5 Web Components** | [SAP/ui5-webcomponents-ngx](https://github.com/SAP/ui5-webcomponents-ngx) | Enterprise chat interface |
| **LangChain Integration** | [SAP/langchain-integration-for-sap-hana-cloud](https://github.com/SAP/langchain-integration-for-sap-hana-cloud) | Vector storage, chains |
| **GenAI Toolkit** | [SAP/generative-ai-toolkit-for-sap-hana-cloud](https://github.com/SAP/generative-ai-toolkit-for-sap-hana-cloud) | HANA ML integration |

---

## Technical Terms

| Term | Definition |
|------|------------|
| **BTP** | SAP Business Technology Platform |
| **CAP** | Cloud Application Programming model |
| **OData** | Open Data Protocol for RESTful APIs |
| **PAL** | Predictive Analysis Library (HANA) |
| **PII** | Personally Identifiable Information |
| **SSE** | Server-Sent Events (streaming protocol) |
| **XSUAA** | Extended Services User Account and Authentication |

---

## The 13 Services

| # | Service | Pillar | Purpose |
|---|---------|--------|---------|
| 1 | UI5 Web Components | Interaction | Chat interface |
| 2 | AI SDK JS | Orchestration | Model routing |
| 3 | CAP LLM Plugin | Orchestration | RAG, anonymization |
| 4 | Streaming Core | Foundation | Real-time delivery |
| 5 | MCP PAL | Intelligence | Forecasting |
| 6 | Data Cleaning Copilot | Intelligence | Data quality |
| 7 | HANA Vector Store | Foundation | Knowledge search |
| 8 | GenAI Toolkit | Intelligence | Custom ML |
| 9 | LangChain Integration | Orchestration | Vector store |
| 10 | Vocabulary query | Foundation | Data transformation |
| 11 | OData Vocabularies | Interaction | Semantic definitions |
| 12 | vLLM | Foundation | Private LLM |
| 13 | World Monitor | Governance | Observability |

---

## The Four Patterns

| Pattern | Purpose | When to Use |
|---------|---------|-------------|
| **OpenAI Compliance** | Universal API interface | Multiple LLM providers |
| **Data prep** | Data sanitization | Before any AI reasoning |
| **MCP** | Tool discovery | Exposing capabilities to agents |
| **Agentic Reasoning** | Autonomous decisions | Complex, multi-step tasks |

---

## Quick Links

- **[README.md](README.md)** — Document map and getting started
- **[01-enterprise-ai-problem.md](01-enterprise-ai-problem.md)** — The problems we solve
- **[06-architectural-patterns.md](06-architectural-patterns.md)** — Pattern details

---

*Version 2.0 | Updated 2026-02-27*