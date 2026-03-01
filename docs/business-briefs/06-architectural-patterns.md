# Architectural Patterns: OpenAI, Mangle, MCP, Agentic

**For:** 🏛 Architects, 👩‍💻 Developers

> This architecture leverages **SAP Open Source libraries** from [github.com/SAP](https://github.com/SAP) orchestrated via **SAP AI Core**.

---

## Why These Four Patterns?

```mermaid
flowchart TB
    subgraph Patterns["THE FOUR PILLARS"]
        COMM["📡 COMMUNICATION<br/>(OpenAI)"]
        PREP["🧹 PREPARATION<br/>(Mangle)"]
        CAP["🔧 CAPABILITY<br/>(MCP)"]
        COG["🧠 COGNITION<br/>(Agentic)"]
    end
    
    COMM --> Brain["ENTERPRISE<br/>AI BRAIN"]
    PREP --> Brain
    CAP --> Brain
    COG --> Brain
```

| Pattern | Phase | Question | Without It |
|---------|-------|----------|------------|
| **OpenAI Compliance** | Communication | "How do services talk?" | Custom code per integration |
| **Mangle** | Preparation | "Is data safe?" | PII leaks, noisy context |
| **MCP** | Capability | "What can AI do?" | Hard-coded functions |
| **Agentic** | Cognition | "How does AI decide?" | Brittle if-else trees |

---

## Pattern Summary: The Way vs. Anti-Pattern

| Pattern | ✅ The Pattern | ❌ Anti-Pattern | Value |
|---------|---------------|----------------|-------|
| **OpenAI** | `/v1/chat/completions` everywhere | Custom code per provider | Swappable services |
| **Mangle** | Clean data *before* reasoning | Hope model ignores PII | Security + quality |
| **MCP** | Discoverable "Tools" | Hard-coded function calls | Extensible agents |
| **Agentic** | Plan → Act → Observe → Correct | Linear if-else trees | Self-healing |

---

## 1. OpenAI Compliance: Universal Interface

```mermaid
flowchart TB
    subgraph SDK["AI SDK"]
        Router["Model Router"]
    end
    
    subgraph Providers["All Expose /v1/chat/completions"]
        VLLM["vLLM"]
        ES["Elasticsearch"]
        Azure["Azure OpenAI"]
    end
    
    App["Application"] --> SDK
    Router --> VLLM
    Router --> ES
    Router --> Azure
```

#### Anti-Pattern
```javascript
// ❌ Provider-specific code
if (provider === 'vllm') {
  response = await axios.post(`${vllmUrl}/generate`);
} else if (provider === 'elasticsearch') {
  response = await esClient.search({ ... });
} else if (provider === 'openai') {
  response = await openai.chat.completions.create({ ... });
}
```

#### The Pattern
```typescript
// ✅ Single interface for all
const response = await sdk.chatCompletion({
  model: config.model,  // vllm, elasticsearch, gpt-4
  messages: [{ role: 'user', content: message }]
});
```

---

## 2. Mangle: Data Sanitization

```mermaid
flowchart LR
    subgraph Raw["Raw Data"]
        R1["BUKRS: 1000"]
        R2["NAME1: John Smith"]
        R3["WRBTR: 50000"]
    end
    
    subgraph Mangle["Mangle Operations"]
        M1["1. Anonymize"]
        M2["2. Enrich"]
        M3["3. Format"]
    end
    
    subgraph Clean["Model-Ready"]
        C1["company: 'US Entity'"]
        C2["customer: '[CUST_01]'"]
        C3["amount: 50000"]
    end
    
    Raw --> Mangle --> Clean
```

#### Anti-Pattern
```javascript
// ❌ Send raw data, hope for the best
const response = await llm.complete({
  prompt: `Analyze: ${JSON.stringify(rawAcdocaRows)}`
  // Includes: customer names, SSNs, bank accounts...
});
```

---

## 3. MCP: Services as Tools

```mermaid
flowchart TB
    Agent["AI Agent"] --> Registry["MCP Registry"]
    
    subgraph Tools["Available Tools"]
        T1["pal_forecast<br/>Run ARIMA forecast"]
        T2["vector_search<br/>Search HANA vectors"]
        T3["data_quality_audit<br/>Check data quality"]
    end
    
    Registry --> T1
    Registry --> T2
    Registry --> T3
    
    Agent --> |"Decides"| T1
```

#### Anti-Pattern
```javascript
// ❌ Hard-coded function calls
if (query.includes('forecast')) {
  return await palForecast(query);  // Can't add new tools
} else if (query.includes('search')) {
  return await vectorSearch(query);
}
```

#### The Pattern
```typescript
// ✅ Agent discovers and invokes tools
const tools = await mcp.listTools();
const result = await agent.invoke({
  query: userQuery,
  availableTools: tools  // Agent decides which to use
});
```

---

## 4. Agentic Reasoning: Autonomous Loop

```mermaid
flowchart TB
    Plan["📋 PLAN<br/>'What should I do?'"]
    Act["⚡ ACT<br/>'Do it'"]
    Observe["👁 OBSERVE<br/>'What happened?'"]
    Correct["🔧 CORRECT<br/>'Fix it'"]
    
    Plan --> Act
    Act --> Observe
    Observe --> |"Error"| Correct
    Correct --> Plan
    Observe --> |"Success"| Done["✅ Return"]
```

#### Anti-Pattern
```javascript
// ❌ Linear, no self-correction
const data = await fetchData();
if (!data) return "No data";  // Stop
const forecast = await runForecast(data);
if (!forecast) return "Failed";  // Stop - no retry
return formatResult(forecast);
```

---

## Request-to-Reasoning Pipeline

```mermaid
flowchart TB
    subgraph Step1["1. INGRESS"]
        S1["UI5 (1) → AI SDK (2)"]
    end
    
    subgraph Step2["2. MANGLE"]
        S2["Mangle (10) → CAP (3) → HANA"]
    end
    
    subgraph Step3["3. DISCOVERY"]
        S3["SDK → MCP → PAL (5), ES (7)"]
    end
    
    subgraph Step4["4. REASONING"]
        S4["LLM (12) or Agent (6)"]
    end
    
    subgraph Step5["5. EGRESS"]
        S5["Streaming (4) → World Monitor (13)"]
    end
    
    Step1 --> Step2 --> Step3 --> Step4 --> Step5
```

---

## Pattern Decision Tree

```mermaid
flowchart TD
    Start["New Requirement"] --> Q1{"Expose capability<br/>to AI agents?"}
    Q1 --> |"Yes"| MCP["Implement MCP"]
    Q1 --> |"No"| Q2{"Data needs<br/>cleaning?"}
    
    Q2 --> |"Yes"| Mangle["Add Mangle layer"]
    Q2 --> |"No"| Q3{"Complex<br/>decisions?"}
    
    Q3 --> |"Yes"| Agent["Use Agentic"]
    Q3 --> |"No"| Q4{"Multiple<br/>providers?"}
    
    Q4 --> |"Yes"| OpenAI["OpenAI compliance"]
    Q4 --> |"No"| Simple["Simple REST"]
```

---

## Summary

| Benefit | Pattern | Impact |
|---------|---------|--------|
| **Interoperability** | OpenAI | Add models in hours |
| **Security** | Mangle | Zero PII exposure |
| **Autonomy** | MCP | Any registered tool |
| **Resilience** | Agentic | Self-correcting |

---

## Next Steps

- **[00-glossary.md](00-glossary.md)** — Terms reference
- **[01-enterprise-ai-problem.md](01-enterprise-ai-problem.md)** — Problems these patterns solve

---

*Version 2.0 | Updated 2026-02-27*