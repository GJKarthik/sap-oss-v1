# SAP BTP World Monitor Implementation Plan

**Project:** World Monitor - SAP BTP Enterprise Deployment  
**Duration:** 30 Days  
**Start Date:** 2026-02-26  

---

## Executive Summary

This plan outlines the complete implementation of a real-time global intelligence dashboard on SAP Business Technology Platform, featuring:

1. **Backend**: SAP AI Core (GenAI Hub) + HANA Cloud Vector Engine + Object Store
2. **Frontend**: Angular 18 + UI5 Web Components + SAP VizFrame Charts
3. **Deployment**: Cloud Foundry with MTA (Multi-Target Application)

---

## Confirmed Requirements

| Decision | Choice | Rationale |
|----------|--------|-----------|
| **Priority** | BTP Backend First | Establishes data foundation |
| **UI Scope** | All 50+ Panels | Complete feature parity |
| **Visualization** | SAP VizFrame | SAP-native, Fiori compliant |
| **PWA** | SAP Launchpad aligned | Enterprise mobile support |

---

## SAP BTP Services Configuration

### Object Store (S3)
```
Bucket: hcp-055af4b0-2344-40d2-88fe-ddc1c4aad6c5
Region: us-east-1
Host: s3.amazonaws.com
```

### HANA Cloud
```
Host: d93a8739-44a8-4845-bef3-8ec724dea2ce.hana.prod-us10.hanacloud.ondemand.com
Port: 443
Region: prod-us10 (us-east-1)
User: DBADMIN
```

### SAP AI Core
```
Base URL: https://api.ai.prod-ap11.ap-southeast-1.aws.ml.hana.ondemand.com
Auth URL: https://scbtest-xhlxpm6g.authentication.ap11.hana.ondemand.com/oauth/token
Region: ap-southeast-1 (Singapore)
Resource Group: default
```

---

## Phase 1: SAP BTP Backend Services (Days 1-15)

### Week 1: Object Store + HANA Integration (Days 1-5)

#### Day 1: BTP Object Store S3 Client

**Deliverables:**
- `packages/btp-object-store/src/s3-client.ts`
- `packages/btp-object-store/src/types.ts`
- `packages/btp-object-store/tests/s3-client.test.ts`

**Implementation:**
```typescript
// s3-client.ts
import { S3Client, PutObjectCommand, GetObjectCommand } from '@aws-sdk/client-s3';

export interface BTPObjectStoreConfig {
  bucket: string;
  region: string;
  accessKeyId: string;
  secretAccessKey: string;
}

export class BTPObjectStore {
  private client: S3Client;
  private bucket: string;

  constructor(config: BTPObjectStoreConfig) {
    this.client = new S3Client({
      region: config.region,
      credentials: {
        accessKeyId: config.accessKeyId,
        secretAccessKey: config.secretAccessKey,
      },
    });
    this.bucket = config.bucket;
  }

  async upload(key: string, body: Buffer | string): Promise<void> { ... }
  async download(key: string): Promise<Buffer> { ... }
  async list(prefix: string): Promise<string[]> { ... }
  async delete(key: string): Promise<void> { ... }
}
```

---

#### Day 2: Document Upload/Download/Streaming

**Deliverables:**
- `packages/btp-object-store/src/document-store.ts`
- `packages/btp-object-store/src/chunked-upload.ts`
- Large file streaming support

**Key Features:**
- Multipart upload for files > 5MB
- Streaming download for large documents
- Metadata management
- MIME type detection

---

#### Day 3: HANA Cloud Connection Module

**Deliverables:**
- `packages/hana-vector/src/hana-client.ts`
- `packages/hana-vector/src/connection-pool.ts`
- Connection pooling and retry logic

**Implementation:**
```typescript
// hana-client.ts
import hana from '@sap/hana-client';

export interface HANAConfig {
  host: string;
  port: number;
  user: string;
  password: string;
  schema?: string;
  encrypt?: boolean;
  sslValidateCertificate?: boolean;
}

export class HANAClient {
  private pool: ConnectionPool;

  constructor(config: HANAConfig) {
    this.pool = new ConnectionPool({
      serverNode: `${config.host}:${config.port}`,
      uid: config.user,
      pwd: config.password,
      currentSchema: config.schema,
      encrypt: config.encrypt ?? true,
      sslValidateCertificate: config.sslValidateCertificate ?? true,
    });
  }

  async query<T>(sql: string, params?: any[]): Promise<T[]> { ... }
  async execute(sql: string, params?: any[]): Promise<number> { ... }
  async createTable(definition: TableDefinition): Promise<void> { ... }
}
```

---

#### Day 4: HANAVectorStore Implementation

**Deliverables:**
- `packages/hana-vector/src/vector-store.ts`
- `packages/hana-vector/src/types.ts`
- DDL for vector table creation

**Implementation:**
```typescript
// vector-store.ts
export interface VectorDocument {
  id: string;
  content: string;
  embedding: number[];
  metadata: Record<string, any>;
}

export class HANAVectorStore {
  private client: HANAClient;
  private tableName: string;
  private embeddingDims: number;

  async createTable(): Promise<void> {
    await this.client.execute(`
      CREATE TABLE "${this.tableName}" (
        "ID" NVARCHAR(255) PRIMARY KEY,
        "CONTENT" NCLOB,
        "EMBEDDING" REAL_VECTOR(${this.embeddingDims}),
        "METADATA" NCLOB,
        "CREATED_AT" TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        "UPDATED_AT" TIMESTAMP DEFAULT CURRENT_TIMESTAMP
      )
    `);
  }

  async upsert(documents: VectorDocument[]): Promise<void> { ... }
  async delete(ids: string[]): Promise<void> { ... }
  async similaritySearch(query: number[], k: number): Promise<VectorDocument[]> { ... }
}
```

---

#### Day 5: Vector Similarity Search with COSINE_SIMILARITY

**Deliverables:**
- `packages/hana-vector/src/similarity-search.ts`
- `packages/hana-vector/src/hybrid-search.ts`
- Tests with real HANA Cloud connection

**Implementation:**
```typescript
// similarity-search.ts
export class SimilaritySearch {
  async search(
    embedding: number[],
    options: SearchOptions
  ): Promise<SearchResult[]> {
    const sql = `
      SELECT 
        "ID", 
        "CONTENT", 
        "METADATA",
        COSINE_SIMILARITY("EMBEDDING", TO_REAL_VECTOR(?)) AS "SCORE"
      FROM "${this.tableName}"
      WHERE COSINE_SIMILARITY("EMBEDDING", TO_REAL_VECTOR(?)) > ?
      ORDER BY "SCORE" DESC
      LIMIT ?
    `;
    
    return this.client.query(sql, [
      JSON.stringify(embedding),
      JSON.stringify(embedding),
      options.minScore ?? 0.5,
      options.k ?? 10,
    ]);
  }
}
```

---

### Week 2: AI Core + RAG Pipeline (Days 6-10)

#### Day 6: AI Core Client Wrapper

**Deliverables:**
- `packages/ai-core/src/ai-core-client.ts`
- `packages/ai-core/src/auth.ts`
- OAuth2 client credentials flow

**Implementation:**
```typescript
// ai-core-client.ts
export interface AICoreConfig {
  baseUrl: string;
  authUrl: string;
  clientId: string;
  clientSecret: string;
  resourceGroup: string;
}

export class AICoreClient {
  private config: AICoreConfig;
  private accessToken?: string;
  private tokenExpiry?: Date;

  async getAccessToken(): Promise<string> {
    if (this.accessToken && this.tokenExpiry && this.tokenExpiry > new Date()) {
      return this.accessToken;
    }
    
    const response = await fetch(this.config.authUrl, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/x-www-form-urlencoded',
        'Authorization': `Basic ${Buffer.from(
          `${this.config.clientId}:${this.config.clientSecret}`
        ).toString('base64')}`,
      },
      body: 'grant_type=client_credentials',
    });
    
    const data = await response.json();
    this.accessToken = data.access_token;
    this.tokenExpiry = new Date(Date.now() + (data.expires_in - 60) * 1000);
    return this.accessToken;
  }

  async request(endpoint: string, options: RequestInit): Promise<Response> {
    const token = await this.getAccessToken();
    return fetch(`${this.config.baseUrl}${endpoint}`, {
      ...options,
      headers: {
        ...options.headers,
        'Authorization': `Bearer ${token}`,
        'AI-Resource-Group': this.config.resourceGroup,
      },
    });
  }
}
```

---

#### Day 7: GenAI Hub Integration

**Deliverables:**
- `packages/ai-core/src/genai-hub.ts`
- `packages/ai-core/src/models.ts`
- Chat completion and embedding APIs

**Implementation:**
```typescript
// genai-hub.ts
export class GenAIHub {
  private client: AICoreClient;

  async chat(request: ChatRequest): Promise<ChatResponse> {
    const response = await this.client.request(
      '/v2/inference/deployments/default/chat/completions',
      {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          model: request.model || 'gpt-4',
          messages: request.messages,
          temperature: request.temperature ?? 0.7,
          max_tokens: request.maxTokens ?? 1024,
        }),
      }
    );
    return response.json();
  }

  async embed(request: EmbedRequest): Promise<EmbedResponse> {
    const response = await this.client.request(
      '/v2/inference/deployments/default/embeddings',
      {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          model: request.model || 'text-embedding-ada-002',
          input: request.input,
        }),
      }
    );
    return response.json();
  }

  async *chatStream(request: ChatRequest): AsyncGenerator<ChatChunk> {
    // SSE streaming implementation
  }
}
```

---

#### Day 8: Embedding Generation Pipeline

**Deliverables:**
- `packages/ai-core/src/embedding-pipeline.ts`
- `packages/ai-core/src/chunker.ts`
- Document chunking and batch embedding

**Implementation:**
```typescript
// embedding-pipeline.ts
export class EmbeddingPipeline {
  private genaiHub: GenAIHub;
  private chunker: DocumentChunker;

  async processDocument(
    content: string,
    metadata: Record<string, any>
  ): Promise<VectorDocument[]> {
    // Chunk the document
    const chunks = this.chunker.chunk(content, {
      chunkSize: 512,
      chunkOverlap: 50,
    });
    
    // Generate embeddings for all chunks
    const embeddings = await this.genaiHub.embed({
      input: chunks.map(c => c.text),
    });
    
    // Create vector documents
    return chunks.map((chunk, i) => ({
      id: `${metadata.id}_chunk_${i}`,
      content: chunk.text,
      embedding: embeddings.data[i].embedding,
      metadata: {
        ...metadata,
        chunkIndex: i,
        totalChunks: chunks.length,
      },
    }));
  }
}
```

---

#### Day 9: Unified RAG Orchestrator

**Deliverables:**
- `packages/btp-rag/src/orchestrator.ts`
- `packages/btp-rag/src/retriever.ts`
- Complete RAG chain

**Implementation:**
```typescript
// orchestrator.ts
export class RAGOrchestrator {
  private vectorStore: HANAVectorStore;
  private genaiHub: GenAIHub;
  private embeddingPipeline: EmbeddingPipeline;

  async query(question: string): Promise<RAGResponse> {
    // 1. Generate query embedding
    const queryEmbedding = await this.genaiHub.embed({
      input: [question],
    });
    
    // 2. Retrieve relevant documents
    const documents = await this.vectorStore.similaritySearch(
      queryEmbedding.data[0].embedding,
      { k: 5, minScore: 0.7 }
    );
    
    // 3. Build context
    const context = this.buildContext(documents);
    
    // 4. Generate response
    const response = await this.genaiHub.chat({
      messages: [
        { role: 'system', content: this.systemPrompt },
        { role: 'user', content: `Context:\n${context}\n\nQuestion: ${question}` },
      ],
    });
    
    return {
      answer: response.choices[0].message.content,
      sources: documents,
      usage: response.usage,
    };
  }
}
```

---

#### Day 10: E2E Testing with Real Credentials

**Deliverables:**
- `packages/btp-rag/tests/e2e-integration.test.ts`
- Integration tests with actual BTP services
- Performance benchmarks

---

### Week 3: CAP Service Layer (Days 11-15)

#### Day 11: CAP Service with CDS Models

**Deliverables:**
```
world-monitor-cap/
├── srv/
│   ├── intelligence-service.cds
│   └── intelligence-service.js
├── db/
│   └── schema.cds
├── package.json
└── .cdsrc.json
```

**CDS Schema:**
```cds
// db/schema.cds
namespace world.monitor;

entity Documents {
  key ID : UUID;
  content : LargeString;
  embedding : LargeBinary; // REAL_VECTOR stored as binary
  metadata : LargeString; // JSON
  source : String(100);
  category : String(50);
  createdAt : Timestamp;
  updatedAt : Timestamp;
}

entity IntelligenceReports {
  key ID : UUID;
  country : String(3);
  ciiScore : Decimal(5,2);
  threatLevel : String(20);
  summary : LargeString;
  signals : LargeString; // JSON array
  timestamp : Timestamp;
}

entity NewsItems {
  key ID : UUID;
  title : String(500);
  content : LargeString;
  source : String(100);
  url : String(500);
  publishedAt : Timestamp;
  category : String(50);
  threatLevel : String(20);
}
```

---

#### Day 12: OData Endpoints

**Service Definition:**
```cds
// srv/intelligence-service.cds
using world.monitor as wm from '../db/schema';

service IntelligenceService @(path: '/api') {
  
  @readonly entity Documents as projection on wm.Documents;
  
  @readonly entity IntelligenceReports as projection on wm.IntelligenceReports;
  
  @readonly entity NewsItems as projection on wm.NewsItems;
  
  // Actions
  action queryRAG(question: String) returns {
    answer: String;
    sources: array of Documents;
    usage: {
      promptTokens: Integer;
      completionTokens: Integer;
    };
  };
  
  action ingestDocument(
    content: String,
    metadata: String,
    source: String,
    category: String
  ) returns Documents;
  
  action generateBrief(country: String) returns IntelligenceReports;
  
  // Functions
  function getCountryCII(country: String) returns Decimal;
  function searchSimilar(query: String, limit: Integer) returns array of Documents;
}
```

---

#### Day 13: WebSocket for Real-Time Data

**Deliverables:**
- `srv/websocket-handler.js`
- Real-time news feed updates
- Market signal streaming

**Implementation:**
```javascript
// srv/websocket-handler.js
const WebSocket = require('ws');

module.exports = function(app) {
  const wss = new WebSocket.Server({ server: app.server, path: '/ws' });
  
  wss.on('connection', (ws) => {
    // Subscribe to channels
    ws.on('message', (message) => {
      const { action, channel } = JSON.parse(message);
      if (action === 'subscribe') {
        ws.channel = channel;
      }
    });
    
    // Send updates
    const interval = setInterval(() => {
      if (ws.channel === 'news') {
        ws.send(JSON.stringify(getLatestNews()));
      } else if (ws.channel === 'markets') {
        ws.send(JSON.stringify(getMarketData()));
      }
    }, 5000);
    
    ws.on('close', () => clearInterval(interval));
  });
};
```

---

#### Day 14: MTA Deployment Configuration

**Deliverables:**
```
world-monitor-cap/
├── mta.yaml
├── xs-security.json
└── xs-app.json
```

**MTA Configuration:**
```yaml
# mta.yaml
_schema-version: "3.1"
ID: world-monitor
version: 1.0.0
description: World Monitor Intelligence Platform

modules:
  - name: world-monitor-srv
    type: nodejs
    path: gen/srv
    parameters:
      buildpack: nodejs_buildpack
      memory: 512M
    requires:
      - name: world-monitor-db
      - name: world-monitor-uaa
      - name: world-monitor-objectstore
      - name: world-monitor-aicore
    provides:
      - name: srv-api
        properties:
          srv-url: ${default-url}

  - name: world-monitor-db-deployer
    type: hdb
    path: gen/db
    parameters:
      buildpack: nodejs_buildpack
    requires:
      - name: world-monitor-db

  - name: world-monitor-ui
    type: approuter.nodejs
    path: app/router
    parameters:
      memory: 256M
    requires:
      - name: srv-api
        group: destinations
        properties:
          name: srv-api
          url: ~{srv-url}
          forwardAuthToken: true
      - name: world-monitor-uaa

resources:
  - name: world-monitor-db
    type: com.sap.xs.hdi-container
    parameters:
      service: hana
      service-plan: hdi-shared

  - name: world-monitor-uaa
    type: com.sap.xs.uaa
    parameters:
      service: xsuaa
      service-plan: application
      config:
        xsappname: world-monitor
        tenant-mode: dedicated

  - name: world-monitor-objectstore
    type: org.cloudfoundry.managed-service
    parameters:
      service: objectstore
      service-plan: s3-standard

  - name: world-monitor-aicore
    type: org.cloudfoundry.managed-service
    parameters:
      service: aicore
      service-plan: extended
```

---

#### Day 15: Deploy to BTP Cloud Foundry

**Deployment Steps:**
```bash
# Build MTA archive
mbt build

# Deploy to Cloud Foundry
cf deploy mta_archives/world-monitor_1.0.0.mtar

# Verify services
cf apps
cf services
```

---

## Phase 2: World Monitor UI5 Angular Conversion (Days 16-30)

### Week 4: Angular Foundation (Days 16-20)

#### Day 16: Angular 18 Project Structure

**Deliverables:**
```
world-monitor-ui5/
├── angular.json
├── package.json
├── tsconfig.json
├── src/
│   ├── app/
│   │   ├── app.component.ts
│   │   ├── app.module.ts
│   │   ├── app-routing.module.ts
│   │   └── core/
│   │       ├── core.module.ts
│   │       └── interceptors/
│   ├── assets/
│   ├── environments/
│   └── styles/
├── xs-app.json
└── ui5.yaml
```

**Package.json:**
```json
{
  "name": "world-monitor-ui5",
  "version": "1.0.0",
  "scripts": {
    "start": "ng serve",
    "build": "ng build --configuration production",
    "build:cf": "ng build --configuration production && npm run copy-approuter"
  },
  "dependencies": {
    "@angular/core": "^18.0.0",
    "@angular/router": "^18.0.0",
    "@ui5/webcomponents-ngx": "^2.0.0",
    "@sap/cds-odata-v4-adapter": "^1.0.0"
  }
}
```

---

#### Day 17: UI5 Web Components Integration

**Deliverables:**
- `src/app/shared/ui5.module.ts`
- UI5 component imports
- Theme configuration

**Implementation:**
```typescript
// src/app/shared/ui5.module.ts
import { NgModule } from '@angular/core';
import { Ui5WebcomponentsModule } from '@ui5/webcomponents-ngx';
import '@ui5/webcomponents-fiori/dist/ShellBar';
import '@ui5/webcomponents-fiori/dist/SideNavigation';
import '@ui5/webcomponents/dist/Panel';
import '@ui5/webcomponents/dist/Table';
import '@ui5/webcomponents/dist/Card';
import '@ui5/webcomponents/dist/List';
import '@ui5/webcomponents/dist/Badge';
import '@ui5/webcomponents/dist/Dialog';
import '@ui5/webcomponents/dist/TabContainer';

// Apply SAP Fiori theme
import '@ui5/webcomponents-theming/dist/Assets';
import { setTheme } from '@ui5/webcomponents-base/dist/config/Theme';
setTheme('sap_horizon_dark');

@NgModule({
  imports: [Ui5WebcomponentsModule],
  exports: [Ui5WebcomponentsModule],
})
export class UI5Module {}
```

---

#### Day 18: Routing and Feature Modules

**Deliverables:**
- `src/app/app-routing.module.ts`
- Feature module structure
- Lazy loading configuration

**Implementation:**
```typescript
// src/app/app-routing.module.ts
import { NgModule } from '@angular/core';
import { RouterModule, Routes } from '@angular/router';

const routes: Routes = [
  {
    path: '',
    loadChildren: () => import('./features/dashboard/dashboard.module')
      .then(m => m.DashboardModule),
  },
  {
    path: 'country/:code',
    loadChildren: () => import('./features/country-brief/country-brief.module')
      .then(m => m.CountryBriefModule),
  },
  {
    path: 'markets',
    loadChildren: () => import('./features/markets/markets.module')
      .then(m => m.MarketsModule),
  },
  {
    path: 'intelligence',
    loadChildren: () => import('./features/intelligence/intelligence.module')
      .then(m => m.IntelligenceModule),
  },
];

@NgModule({
  imports: [RouterModule.forRoot(routes)],
  exports: [RouterModule],
})
export class AppRoutingModule {}
```

---

#### Day 19: Core Services

**Deliverables:**
- `src/app/core/services/intelligence.service.ts`
- `src/app/core/services/websocket.service.ts`
- `src/app/core/services/odata.service.ts`

**Implementation:**
```typescript
// src/app/core/services/intelligence.service.ts
import { Injectable } from '@angular/core';
import { HttpClient } from '@angular/common/http';
import { Observable } from 'rxjs';

@Injectable({ providedIn: 'root' })
export class IntelligenceService {
  private baseUrl = '/api';

  constructor(private http: HttpClient) {}

  getCountryCII(country: string): Observable<number> {
    return this.http.get<number>(`${this.baseUrl}/getCountryCII(country='${country}')`);
  }

  queryRAG(question: string): Observable<RAGResponse> {
    return this.http.post<RAGResponse>(`${this.baseUrl}/queryRAG`, { question });
  }

  getIntelligenceReports(): Observable<IntelligenceReport[]> {
    return this.http.get<ODataResponse<IntelligenceReport>>(
      `${this.baseUrl}/IntelligenceReports`
    ).pipe(map(r => r.value));
  }

  getNewsItems(params?: ODataParams): Observable<NewsItem[]> {
    const queryString = buildODataQuery(params);
    return this.http.get<ODataResponse<NewsItem>>(
      `${this.baseUrl}/NewsItems${queryString}`
    ).pipe(map(r => r.value));
  }
}
```

---

#### Day 20: XSUAA Authentication

**Deliverables:**
- `src/app/core/services/auth.service.ts`
- `src/app/core/guards/auth.guard.ts`
- Token refresh interceptor

**Implementation:**
```typescript
// src/app/core/services/auth.service.ts
import { Injectable } from '@angular/core';
import { HttpClient } from '@angular/common/http';

@Injectable({ providedIn: 'root' })
export class AuthService {
  private user?: User;

  constructor(private http: HttpClient) {}

  async init(): Promise<void> {
    try {
      const response = await this.http.get<User>('/api/user').toPromise();
      this.user = response;
    } catch (error) {
      console.error('Authentication failed:', error);
    }
  }

  isAuthenticated(): boolean {
    return !!this.user;
  }

  getUser(): User | undefined {
    return this.user;
  }

  logout(): void {
    window.location.href = '/logout';
  }
}
```

---

### Week 5: Core Components with SAP VizFrame (Days 21-25)

#### Day 21: SAP VizFrame Map Integration

**Deliverables:**
- `src/app/features/map/map.module.ts`
- `src/app/features/map/geo-map.component.ts`
- SAP UI5 GeoMap with VizFrame charts

**Implementation:**
```typescript
// src/app/features/map/geo-map.component.ts
import { Component, OnInit, ViewChild, ElementRef } from '@angular/core';

@Component({
  selector: 'app-geo-map',
  template: `
    <ui5-card>
      <ui5-card-header slot="header" title-text="Global Intelligence Map"></ui5-card-header>
      <div #mapContainer class="map-container">
        <!-- SAP UI5 GeoMap -->
        <div id="geoMapChart" style="height: 600px;"></div>
      </div>
    </ui5-card>
  `,
})
export class GeoMapComponent implements OnInit {
  @ViewChild('mapContainer', { static: true }) mapContainer!: ElementRef;

  ngOnInit(): void {
    this.initVizFrame();
  }

  private initVizFrame(): void {
    // Initialize SAP VizFrame GeoMap
    sap.ui.require(['sap/viz/ui5/controls/VizFrame'], (VizFrame: any) => {
      const oVizFrame = new VizFrame({
        vizType: 'geo_choropleth',
        uiConfig: {
          applicationSet: 'fiori',
        },
        vizProperties: {
          legend: { visible: true },
          title: { visible: false },
          geoMap: {
            showLabels: true,
            defaultMap: {
              url: '/assets/world.geo.json',
            },
          },
        },
      });
      
      oVizFrame.placeAt(this.mapContainer.nativeElement);
    });
  }
}
```

---

#### Day 22: Panel Components (10 Key Panels)

**Deliverables:**
- `src/app/features/panels/panels.module.ts`
- 10 converted panel components using UI5

**Panel Mapping:**
| Original | Angular UI5 |
|----------|-------------|
| NewsPanel.ts | news-panel.component.ts |
| CIIPanel.ts | cii-panel.component.ts |
| MacroSignalsPanel.ts | macro-signals-panel.component.ts |
| StrategicPosturePanel.ts | strategic-posture-panel.component.ts |
| ServiceStatusPanel.ts | service-status-panel.component.ts |
| MarketPanel.ts | market-panel.component.ts |
| PredictionPanel.ts | prediction-panel.component.ts |
| DisplacementPanel.ts | displacement-panel.component.ts |
| ClimateAnomalyPanel.ts | climate-anomaly-panel.component.ts |
| EconomicPanel.ts | economic-panel.component.ts |

**Example Panel:**
```typescript
// src/app/features/panels/news-panel.component.ts
import { Component, OnInit, Input } from '@angular/core';
import { IntelligenceService } from '../../core/services/intelligence.service';

@Component({
  selector: 'app-news-panel',
  template: `
    <ui5-panel header-text="Live News Feed" collapsed="false">
      <ui5-list mode="None">
        <ui5-li *ngFor="let item of newsItems" 
                icon="newspaper"
                [additionalText]="item.source">
          <ui5-badge slot="badge" 
                     [color-scheme]="getThreatColor(item.threatLevel)">
            {{ item.threatLevel }}
          </ui5-badge>
          {{ item.title }}
        </ui5-li>
      </ui5-list>
    </ui5-panel>
  `,
})
export class NewsPanelComponent implements OnInit {
  newsItems: NewsItem[] = [];

  constructor(private intelligenceService: IntelligenceService) {}

  ngOnInit(): void {
    this.loadNews();
  }

  loadNews(): void {
    this.intelligenceService.getNewsItems({
      $top: 20,
      $orderby: 'publishedAt desc',
    }).subscribe(items => this.newsItems = items);
  }

  getThreatColor(level: string): string {
    const colors: Record<string, string> = {
      critical: '1',  // Red
      high: '2',      // Orange
      medium: '3',    // Yellow
      low: '6',       // Blue
      info: '8',      // Gray
    };
    return colors[level.toLowerCase()] || '8';
  }
}
```

---

#### Day 23: VizFrame Charts (News/Data Panels)

**Deliverables:**
- `src/app/features/charts/charts.module.ts`
- VizFrame line, bar, donut charts
- Real-time chart updates

**Implementation:**
```typescript
// src/app/features/charts/viz-chart.component.ts
import { Component, Input, OnInit, OnChanges, ViewChild, ElementRef } from '@angular/core';

@Component({
  selector: 'app-viz-chart',
  template: `
    <div #chartContainer class="chart-container" [style.height.px]="height"></div>
  `,
})
export class VizChartComponent implements OnInit, OnChanges {
  @ViewChild('chartContainer', { static: true }) chartContainer!: ElementRef;
  @Input() chartType: 'line' | 'bar' | 'donut' | 'column' = 'line';
  @Input() data: any[] = [];
  @Input() height = 300;

  private vizFrame: any;

  ngOnInit(): void {
    this.initChart();
  }

  ngOnChanges(): void {
    if (this.vizFrame) {
      this.updateData();
    }
  }

  private initChart(): void {
    sap.ui.require([
      'sap/viz/ui5/controls/VizFrame',
      'sap/viz/ui5/data/FlattenedDataset',
    ], (VizFrame: any, FlattenedDataset: any) => {
      this.vizFrame = new VizFrame({
        vizType: this.chartType,
        uiConfig: { applicationSet: 'fiori' },
        vizProperties: {
          plotArea: { dataLabel: { visible: true } },
          legend: { visible: true },
          title: { visible: false },
        },
      });
      
      this.vizFrame.placeAt(this.chartContainer.nativeElement);
      this.updateData();
    });
  }

  private updateData(): void {
    // Update VizFrame dataset
  }
}
```

---

#### Day 24: Market/Economic Panels with VizFrame

**Deliverables:**
- `src/app/features/markets/markets.module.ts`
- Market radar with donut chart
- Stock index sparklines
- ETF flow bar charts

**Implementation:**
```typescript
// src/app/features/markets/macro-signals.component.ts
@Component({
  selector: 'app-macro-signals',
  template: `
    <ui5-panel header-text="Market Radar">
      <div class="signal-grid">
        <ui5-card *ngFor="let signal of signals">
          <ui5-card-header 
            slot="header" 
            [title-text]="signal.name"
            [status]="signal.status">
          </ui5-card-header>
          <app-viz-chart 
            chartType="donut" 
            [data]="signal.data" 
            [height]="120">
          </app-viz-chart>
        </ui5-card>
      </div>
      
      <div class="verdict">
        <ui5-badge [color-scheme]="verdictColor">
          {{ verdict }}
        </ui5-badge>
      </div>
    </ui5-panel>
  `,
})
export class MacroSignalsComponent implements OnInit {
  signals: MacroSignal[] = [];
  verdict: 'BUY' | 'CASH' = 'CASH';
  verdictColor = '8';

  // ... implementation
}
```

---

#### Day 25: Intelligence Panels (CII, Brief)

**Deliverables:**
- `src/app/features/intelligence/intelligence.module.ts`
- Country Instability Index (CII) panel
- Country Brief page
- RAG query interface

**Implementation:**
```typescript
// src/app/features/intelligence/cii-panel.component.ts
@Component({
  selector: 'app-cii-panel',
  template: `
    <ui5-panel header-text="Country Instability Index">
      <ui5-table>
        <ui5-table-column slot="columns">
          <ui5-label>Country</ui5-label>
        </ui5-table-column>
        <ui5-table-column slot="columns">
          <ui5-label>CII Score</ui5-label>
        </ui5-table-column>
        <ui5-table-column slot="columns">
          <ui5-label>Trend</ui5-label>
        </ui5-table-column>
        <ui5-table-column slot="columns">
          <ui5-label>Status</ui5-label>
        </ui5-table-column>
        
        <ui5-table-row *ngFor="let country of countries">
          <ui5-table-cell>
            <ui5-link (click)="openBrief(country.code)">
              {{ country.name }}
            </ui5-link>
          </ui5-table-cell>
          <ui5-table-cell>
            <app-viz-chart chartType="donut" [data]="[country.cii]" [height]="40">
            </app-viz-chart>
          </ui5-table-cell>
          <ui5-table-cell>
            <ui5-icon [name]="getTrendIcon(country.trend)"></ui5-icon>
          </ui5-table-cell>
          <ui5-table-cell>
            <ui5-badge [color-scheme]="getStatusColor(country.status)">
              {{ country.status }}
            </ui5-badge>
          </ui5-table-cell>
        </ui5-table-row>
      </ui5-table>
    </ui5-panel>
  `,
})
export class CIIPanelComponent {
  countries: CountryIntelligence[] = [];
  
  openBrief(code: string): void {
    this.router.navigate(['/country', code]);
  }
}
```

---

### Week 6: Integration & Deployment (Days 26-30)

#### Day 26: Connect Angular to CAP Backend

**Deliverables:**
- OData v4 client configuration
- CSRF token handling
- Batch request support

---

#### Day 27: Real-Time WebSocket Updates

**Deliverables:**
- WebSocket service with reconnection
- RxJS observables for live data
- Panel subscription management

---

#### Day 28: SAP Fiori Theming

**Deliverables:**
- Dark/Light theme toggle
- Custom Fiori variables
- Responsive layouts

---

#### Day 29: BTP Approuter Deployment

**Deliverables:**
- `xs-app.json` configuration
- XSUAA integration
- MTA module for UI

---

#### Day 30: Final Testing and Go-Live

**Deliverables:**
- E2E tests
- Performance validation
- Production deployment

---

## Component Conversion Matrix

### All 50+ Panels Mapped

| # | Original Component | Angular UI5 Component | Priority |
|---|-------------------|----------------------|----------|
| 1 | NewsPanel | news-panel.component | High |
| 2 | CIIPanel | cii-panel.component | High |
| 3 | DeckGLMap | geo-map.component (VizFrame) | High |
| 4 | MacroSignalsPanel | macro-signals-panel.component | High |
| 5 | StrategicPosturePanel | strategic-posture-panel.component | High |
| 6 | MarketPanel | market-panel.component | High |
| 7 | CountryBriefPage | country-brief.component | High |
| 8 | ServiceStatusPanel | service-status-panel.component | Medium |
| 9 | PredictionPanel | prediction-panel.component | Medium |
| 10 | DisplacementPanel | displacement-panel.component | Medium |
| 11 | ClimateAnomalyPanel | climate-anomaly-panel.component | Medium |
| 12 | EconomicPanel | economic-panel.component | Medium |
| 13 | ETFFlowsPanel | etf-flows-panel.component | Medium |
| 14 | StablecoinPanel | stablecoin-panel.component | Medium |
| 15 | GeoHubsPanel | geo-hubs-panel.component | Medium |
| 16 | InvestmentsPanel | investments-panel.component | Medium |
| 17 | UcdpEventsPanel | ucdp-events-panel.component | Medium |
| 18 | GdeltIntelPanel | gdelt-intel-panel.component | Medium |
| 19 | CascadePanel | cascade-panel.component | Medium |
| 20 | InsightsPanel | insights-panel.component | Medium |
| 21 | TechHubsPanel | tech-hubs-panel.component | Low |
| 22 | TechEventsPanel | tech-events-panel.component | Low |
| 23 | TechReadinessPanel | tech-readiness-panel.component | Low |
| 24 | RegulationPanel | regulation-panel.component | Low |
| 25 | LiveNewsPanel | live-news-panel.component | Low |
| 26 | LiveWebcamsPanel | live-webcams-panel.component | Low |
| 27 | PopulationExposurePanel | population-exposure-panel.component | Low |
| 28 | SatelliteFiresPanel | satellite-fires-panel.component | Low |
| 29 | StrategicRiskPanel | strategic-risk-panel.component | Low |
| 30 | SignalModal | signal-modal.component | Low |
| 31 | CountryIntelModal | country-intel-modal.component | Low |
| 32 | CountryTimeline | country-timeline.component | Low |
| 33 | SearchModal | search-modal.component | Low |
| 34 | StoryModal | story-modal.component | Low |
| 35 | DownloadBanner | download-banner.component | Low |
| 36 | IntelligenceGapBadge | intelligence-gap-badge.component | Low |
| 37 | LanguageSelector | language-selector.component | Low |
| 38 | MapPopup | map-popup.component | Low |
| 39 | MobileWarningModal | mobile-warning-modal.component | Low |
| 40 | MonitorPanel | monitor-panel.component | Low |
| 41 | Panel | base-panel.component | Low |
| 42 | PizzIntIndicator | pizz-int-indicator.component | Low |
| 43 | PlaybackControl | playback-control.component | Low |
| 44 | RuntimeConfigPanel | runtime-config-panel.component | Low |
| 45 | StatusPanel | status-panel.component | Low |
| 46 | VerificationChecklist | verification-checklist.component | Low |
| 47 | VirtualList | virtual-list.component | Low |
| 48 | WorldMonitorTab | world-monitor-tab.component | Low |
| 49 | CommunityWidget | community-widget.component | Low |
| 50 | MapContainer | map-container.component | Low |

---

## Delivery Timeline Summary

| Week | Days | Phase | Deliverables |
|------|------|-------|--------------|
| 1 | 1-5 | BTP Backend | Object Store + HANA Vector |
| 2 | 6-10 | BTP Backend | AI Core + RAG Pipeline |
| 3 | 11-15 | BTP Backend | CAP Service + Deployment |
| 4 | 16-20 | UI5 Angular | Foundation + Services |
| 5 | 21-25 | UI5 Angular | VizFrame + All 50 Panels |
| 6 | 26-30 | Integration | WebSocket + Themes + Go-Live |

---

## Success Criteria

1. ✅ All 50+ panels converted to UI5 Angular
2. ✅ SAP VizFrame charts replace deck.gl/MapLibre
3. ✅ BTP-native services (AI Core, HANA, Object Store)
4. ✅ SAP Launchpad-aligned PWA
5. ✅ XSUAA authentication
6. ✅ MTA deployment to Cloud Foundry
7. ✅ Real-time WebSocket updates
8. ✅ Dark/Light Fiori themes

---

## Next Steps

1. Toggle to **Act mode** to begin implementation
2. Day 1 starts with BTP Object Store S3 client
3. Credentials already captured and ready to use