# Integration Guide

Complete guide for integrating the OData Vocabularies Universal Dictionary into your applications.

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Python Integration](#python-integration)
3. [JavaScript/TypeScript Integration](#javascripttypescript-integration)
4. [SAP CAP Integration](#sap-cap-integration)
5. [HANA Cloud Integration](#hana-cloud-integration)
6. [Elasticsearch Integration](#elasticsearch-integration)
7. [AI/LLM Integration](#aillm-integration)
8. [Authentication](#authentication)
9. [Error Handling](#error-handling)
10. [Best Practices](#best-practices)

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                     Your Application                             │
├─────────────────────────────────────────────────────────────────┤
│  ┌─────────────┐   ┌─────────────┐   ┌─────────────────────┐   │
│  │  REST API   │   │   MCP SDK   │   │  Direct Import      │   │
│  │  (HTTP)     │   │  (Protocol) │   │  (Python Module)    │   │
│  └──────┬──────┘   └──────┬──────┘   └──────────┬──────────┘   │
└─────────┼────────────────┼────────────────────┼────────────────┘
          │                │                     │
          ▼                ▼                     ▼
┌─────────────────────────────────────────────────────────────────┐
│              OData Vocabularies MCP Server                       │
│  ┌─────────────┐   ┌─────────────┐   ┌─────────────────────┐   │
│  │ Vocabulary  │   │  Semantic   │   │  Code Generation    │   │
│  │   Search    │   │   Search    │   │  (CDS/GraphQL/SQL)  │   │
│  └─────────────┘   └─────────────┘   └─────────────────────┘   │
│  ┌─────────────┐   ┌─────────────┐   ┌─────────────────────┐   │
│  │    GDPR     │   │    HANA     │   │   Elasticsearch     │   │
│  │ Compliance  │   │  Connector  │   │      Client         │   │
│  └─────────────┘   └─────────────┘   └─────────────────────┘   │
└─────────────────────────────────────────────────────────────────┘
```

---

## Python Integration

### Direct HTTP Client

```python
import aiohttp
import asyncio

class ODataVocabClient:
    def __init__(self, base_url: str = "http://localhost:9150", api_key: str = None):
        self.base_url = base_url
        self.api_key = api_key
        self.session = None
    
    async def __aenter__(self):
        headers = {}
        if self.api_key:
            headers["X-API-Key"] = self.api_key
        self.session = aiohttp.ClientSession(headers=headers)
        return self
    
    async def __aexit__(self, *args):
        await self.session.close()
    
    async def search_terms(self, query: str, vocabulary: str = None, limit: int = 20):
        """Search for vocabulary terms"""
        payload = {"query": query, "limit": limit}
        if vocabulary:
            payload["vocabulary"] = vocabulary
        
        async with self.session.post(
            f"{self.base_url}/mcp/tools/search_terms",
            json=payload
        ) as response:
            return await response.json()
    
    async def semantic_search(self, query: str, limit: int = 10):
        """Semantic similarity search"""
        async with self.session.post(
            f"{self.base_url}/mcp/tools/semantic_search",
            json={"query": query, "limit": limit}
        ) as response:
            return await response.json()
    
    async def suggest_annotations(self, entity: dict):
        """Get annotation suggestions for an entity"""
        async with self.session.post(
            f"{self.base_url}/mcp/tools/suggest_annotations",
            json={"entity": entity}
        ) as response:
            return await response.json()
    
    async def classify_personal_data(self, entity: dict):
        """Classify personal data in entity"""
        async with self.session.post(
            f"{self.base_url}/mcp/tools/classify_personal_data",
            json={"entity": entity}
        ) as response:
            return await response.json()
    
    async def generate_cds(self, entity: dict):
        """Generate CAP CDS from entity"""
        async with self.session.post(
            f"{self.base_url}/mcp/tools/generate_cds",
            json={"entity": entity}
        ) as response:
            return await response.json()

# Usage
async def main():
    async with ODataVocabClient(api_key="your-api-key") as client:
        # Search for UI terms
        results = await client.search_terms("LineItem", vocabulary="UI")
        print(f"Found {len(results['results'])} terms")
        
        # Classify an entity
        entity = {
            "name": "Customer",
            "properties": [
                {"name": "CustomerID", "type": "Edm.String"},
                {"name": "Email", "type": "Edm.String"}
            ]
        }
        classification = await client.classify_personal_data(entity)
        print(f"Has personal data: {classification['has_personal_data']}")

asyncio.run(main())
```

### Synchronous Client

```python
import requests

class ODataVocabClientSync:
    def __init__(self, base_url: str = "http://localhost:9150", api_key: str = None):
        self.base_url = base_url
        self.session = requests.Session()
        if api_key:
            self.session.headers["X-API-Key"] = api_key
    
    def search_terms(self, query: str, vocabulary: str = None) -> dict:
        return self.session.post(
            f"{self.base_url}/mcp/tools/search_terms",
            json={"query": query, "vocabulary": vocabulary}
        ).json()
    
    def get_term(self, qualified_name: str) -> dict:
        return self.session.post(
            f"{self.base_url}/mcp/tools/get_term_definition",
            json={"qualified_name": qualified_name}
        ).json()

# Usage
client = ODataVocabClientSync(api_key="your-key")
term = client.get_term("UI.LineItem")
print(term)
```

---

## JavaScript/TypeScript Integration

### Fetch-based Client

```typescript
interface Entity {
  name: string;
  properties: Property[];
}

interface Property {
  name: string;
  type: string;
  nullable?: boolean;
  isKey?: boolean;
}

class ODataVocabClient {
  private baseUrl: string;
  private apiKey?: string;

  constructor(baseUrl = 'http://localhost:9150', apiKey?: string) {
    this.baseUrl = baseUrl;
    this.apiKey = apiKey;
  }

  private async request<T>(endpoint: string, body: object): Promise<T> {
    const headers: HeadersInit = {
      'Content-Type': 'application/json',
    };
    if (this.apiKey) {
      headers['X-API-Key'] = this.apiKey;
    }

    const response = await fetch(`${this.baseUrl}${endpoint}`, {
      method: 'POST',
      headers,
      body: JSON.stringify(body),
    });

    if (!response.ok) {
      throw new Error(`API error: ${response.status}`);
    }

    return response.json();
  }

  async searchTerms(query: string, vocabulary?: string, limit = 20) {
    return this.request('/mcp/tools/search_terms', {
      query,
      vocabulary,
      limit,
    });
  }

  async semanticSearch(query: string, limit = 10) {
    return this.request('/mcp/tools/semantic_search', {
      query,
      limit,
    });
  }

  async suggestAnnotations(entity: Entity) {
    return this.request('/mcp/tools/suggest_annotations', { entity });
  }

  async classifyPersonalData(entity: Entity) {
    return this.request('/mcp/tools/classify_personal_data', { entity });
  }

  async generateCDS(entity: Entity) {
    return this.request('/mcp/tools/generate_cds', { entity });
  }

  async generateGraphQL(entity: Entity) {
    return this.request('/mcp/tools/generate_graphql', { entity });
  }
}

// Usage
const client = new ODataVocabClient('http://localhost:9150', 'your-api-key');

const results = await client.searchTerms('HeaderInfo', 'UI');
console.log(results);

const cds = await client.generateCDS({
  name: 'Product',
  properties: [
    { name: 'ProductID', type: 'Edm.String', isKey: true },
    { name: 'Name', type: 'Edm.String' },
    { name: 'Price', type: 'Edm.Decimal' },
  ],
});
console.log(cds.code);
```

---

## SAP CAP Integration

### Using in CDS Build Scripts

```javascript
// scripts/annotate-entities.js
const ODataVocabClient = require('./odata-vocab-client');

async function annotateEntities(cdsModel) {
  const client = new ODataVocabClient();
  
  for (const entity of Object.values(cdsModel.definitions)) {
    if (entity.kind !== 'entity') continue;
    
    const properties = Object.entries(entity.elements || {}).map(([name, elem]) => ({
      name,
      type: mapCdsToEdm(elem.type),
      nullable: !elem.notNull,
      isKey: elem.key || false,
    }));
    
    const suggestions = await client.suggestAnnotations({
      name: entity.name,
      properties,
    });
    
    console.log(`Annotations for ${entity.name}:`, suggestions);
  }
}

function mapCdsToEdm(cdsType) {
  const mapping = {
    'cds.String': 'Edm.String',
    'cds.Integer': 'Edm.Int32',
    'cds.Decimal': 'Edm.Decimal',
    'cds.Boolean': 'Edm.Boolean',
    'cds.Date': 'Edm.Date',
    'cds.Timestamp': 'Edm.DateTimeOffset',
  };
  return mapping[cdsType] || 'Edm.String';
}
```

### CAP Server Plugin

```javascript
// srv/vocabulary-service.js
const cds = require('@sap/cds');

module.exports = class VocabularyService extends cds.ApplicationService {
  async init() {
    this.on('searchTerms', this.handleSearchTerms);
    this.on('suggestAnnotations', this.handleSuggestAnnotations);
    await super.init();
  }
  
  async handleSearchTerms(req) {
    const { query, vocabulary } = req.data;
    const response = await fetch('http://localhost:9150/mcp/tools/search_terms', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ query, vocabulary }),
    });
    return response.json();
  }
  
  async handleSuggestAnnotations(req) {
    const { entity } = req.data;
    const response = await fetch('http://localhost:9150/mcp/tools/suggest_annotations', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ entity }),
    });
    return response.json();
  }
};
```

---

## HANA Cloud Integration

### Configure HANA Connection

```bash
# Environment variables
export HANA_HOST=your-instance.hana.cloud.sap
export HANA_PORT=443
export HANA_USER=DBADMIN
export HANA_PASSWORD=your-password
```

### Discover and Annotate Tables

```python
import asyncio

async def annotate_hana_tables():
    async with ODataVocabClient(api_key="your-key") as client:
        # Discover tables
        tables = await client._request(
            "/mcp/tools/discover_hana_tables",
            {"schema": "MY_SCHEMA"}
        )
        
        for table in tables["tables"]:
            # Get metadata with suggested annotations
            metadata = await client._request(
                "/mcp/tools/get_hana_metadata",
                {"table_name": table["name"], "schema": "MY_SCHEMA"}
            )
            
            print(f"\n{table['name']}:")
            for col in metadata["columns"]:
                if col.get("suggested_annotations"):
                    print(f"  {col['name']}: {col['suggested_annotations']}")

asyncio.run(annotate_hana_tables())
```

---

## Elasticsearch Integration

### Index Vocabularies

```python
async def index_vocabularies_to_es():
    async with ODataVocabClient() as client:
        # Get all vocabularies
        vocabs = await client._request("/mcp/tools/list_vocabularies", {})
        
        for vocab in vocabs["vocabularies"]:
            # Get full vocabulary
            full_vocab = await client._request(
                "/mcp/tools/get_vocabulary",
                {"vocabulary": vocab["alias"]}
            )
            
            # Index to Elasticsearch
            for term in full_vocab.get("terms", []):
                await es_client.index(
                    index="odata_vocabulary",
                    document={
                        "term_name": term["name"],
                        "vocabulary": vocab["alias"],
                        "qualified_name": term["qualified_name"],
                        "description": term.get("description"),
                        "type": term.get("type"),
                    }
                )
```

---

## AI/LLM Integration

### LangChain Integration

```python
from langchain.tools import Tool
from langchain.agents import AgentExecutor

def create_vocab_tools():
    client = ODataVocabClientSync()
    
    return [
        Tool(
            name="search_odata_terms",
            description="Search for OData vocabulary terms by keyword",
            func=lambda q: str(client.search_terms(q))
        ),
        Tool(
            name="get_term_definition",
            description="Get the definition of an OData term by qualified name (e.g., UI.LineItem)",
            func=lambda q: str(client.get_term(q))
        ),
        Tool(
            name="suggest_annotations",
            description="Suggest OData annotations for an entity definition (pass JSON)",
            func=lambda q: str(client.suggest_annotations(json.loads(q)))
        ),
    ]

# Use in agent
tools = create_vocab_tools()
agent = create_agent(llm, tools)
```

### OpenAI Function Calling

```python
functions = [
    {
        "name": "search_vocabulary_terms",
        "description": "Search for OData vocabulary terms",
        "parameters": {
            "type": "object",
            "properties": {
                "query": {"type": "string", "description": "Search query"},
                "vocabulary": {"type": "string", "description": "Filter by vocabulary (UI, Common, etc)"}
            },
            "required": ["query"]
        }
    },
    {
        "name": "classify_personal_data",
        "description": "Check if entity fields contain personal data",
        "parameters": {
            "type": "object",
            "properties": {
                "entity_name": {"type": "string"},
                "fields": {
                    "type": "array",
                    "items": {"type": "object", "properties": {"name": {"type": "string"}, "type": {"type": "string"}}}
                }
            },
            "required": ["entity_name", "fields"]
        }
    }
]
```

---

## Authentication

### API Key Authentication

```python
# Header
headers = {"X-API-Key": "your-api-key"}

# Or in Authorization header
headers = {"Authorization": "ApiKey your-api-key"}
```

### JWT Authentication

```python
import jwt

# Generate JWT (if you have the secret)
token = jwt.encode(
    {"sub": "user-id", "role": "admin", "exp": datetime.utcnow() + timedelta(hours=24)},
    "your-jwt-secret",
    algorithm="HS256"
)

headers = {"Authorization": f"Bearer {token}"}
```

---

## Error Handling

### Python Error Handling

```python
class ODataVocabError(Exception):
    def __init__(self, status_code: int, error: str, message: str):
        self.status_code = status_code
        self.error = error
        self.message = message
        super().__init__(message)

async def make_request(session, url, payload):
    async with session.post(url, json=payload) as response:
        data = await response.json()
        
        if response.status == 400:
            raise ODataVocabError(400, data["error"], data["message"])
        elif response.status == 401:
            raise ODataVocabError(401, "unauthorized", "Invalid API key")
        elif response.status == 429:
            retry_after = response.headers.get("Retry-After", 60)
            raise ODataVocabError(429, "rate_limited", f"Retry after {retry_after}s")
        elif response.status >= 500:
            raise ODataVocabError(response.status, "server_error", data.get("message", "Unknown error"))
        
        return data
```

### Retry Logic

```python
import asyncio
from tenacity import retry, stop_after_attempt, wait_exponential

@retry(stop=stop_after_attempt(3), wait=wait_exponential(multiplier=1, min=1, max=10))
async def resilient_request(client, endpoint, payload):
    return await client._request(endpoint, payload)
```

---

## Best Practices

### 1. Connection Pooling

```python
# Reuse client instances
client = ODataVocabClient()

# Don't create new clients for each request
# BAD: for item in items: ODataVocabClient().search(item)
# GOOD: for item in items: client.search(item)
```

### 2. Batch Operations

```python
# Batch entity processing
async def process_entities_batch(entities, batch_size=10):
    results = []
    for i in range(0, len(entities), batch_size):
        batch = entities[i:i+batch_size]
        tasks = [client.suggest_annotations(e) for e in batch]
        batch_results = await asyncio.gather(*tasks)
        results.extend(batch_results)
    return results
```

### 3. Caching

```python
from functools import lru_cache

@lru_cache(maxsize=1000)
def get_term_cached(qualified_name: str):
    return client.get_term(qualified_name)
```

### 4. Health Checks

```python
async def ensure_healthy():
    response = await client.session.get(f"{client.base_url}/health")
    data = await response.json()
    if data["status"] != "healthy":
        raise RuntimeError(f"Service unhealthy: {data}")
```

### 5. Logging

```python
import logging

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("odata-vocab")

async def logged_request(client, endpoint, payload):
    logger.info(f"Request: {endpoint}")
    start = time.time()
    result = await client._request(endpoint, payload)
    logger.info(f"Response: {endpoint} ({time.time()-start:.2f}s)")
    return result