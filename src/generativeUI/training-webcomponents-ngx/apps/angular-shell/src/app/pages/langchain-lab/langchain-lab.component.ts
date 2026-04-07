import { Component, CUSTOM_ELEMENTS_SCHEMA, signal, ChangeDetectionStrategy } from '@angular/core';
import { CommonModule } from '@angular/common';
import { Ui5WebcomponentsModule } from '@ui5/webcomponents-ngx';

@Component({
  selector: 'app-langchain-lab',
  standalone: true,
  imports: [CommonModule, Ui5WebcomponentsModule],
  schemas: [CUSTOM_ELEMENTS_SCHEMA],
  changeDetection: ChangeDetectionStrategy.OnPush,
  template: `
    <ui5-page background-design="Solid" class="langchain-aura">
      <ui5-bar slot="header" design="Header">
        <ui5-title slot="startContent" level="H3">LangChain Chain Architect</ui5-title>
        <ui5-tag slot="endContent" design="Positive">HANA Vector Engine Active</ui5-tag>
      </ui5-bar>

      <div class="lab-content" role="main">
        <!-- Visual Chain Flow -->
        <section class="glass-card chain-viewer">
          <ui5-title level="H4">Visual Chain Execution: Self-Querying Retrieval</ui5-title>
          <div class="svg-container">
            <svg viewBox="0 0 1000 200" class="chain-svg">
              <defs>
                <marker id="arrow" viewBox="0 0 10 10" refX="5" refY="5" markerWidth="6" markerHeight="6" orient="auto-start-reverse">
                  <path d="M 0 0 L 10 5 L 0 10 z" fill="var(--sapBrandColor)" />
                </marker>
              </defs>
              
              <!-- Nodes -->
              <g transform="translate(100, 100)" class="chain-node">
                <rect x="-60" y="-30" width="120" height="60" rx="8" class="node-rect" />
                <text text-anchor="middle" y="5" class="node-text">User Query</text>
              </g>

              <g transform="translate(300, 100)" class="chain-node chain-node--active">
                <rect x="-60" y="-30" width="120" height="60" rx="8" class="node-rect" />
                <text text-anchor="middle" y="5" class="node-text">Query Constructor</text>
                <circle r="4" fill="var(--sapBrandColor)">
                  <animateMotion path="M 0 0 L 100 0" dur="1s" repeatCount="indefinite" />
                </circle>
              </g>

              <g transform="translate(550, 100)" class="chain-node">
                <rect x="-80" y="-30" width="160" height="60" rx="8" class="node-rect" />
                <text text-anchor="middle" y="5" class="node-text">HANA Vector Store</text>
              </g>

              <g transform="translate(850, 100)" class="chain-node">
                <rect x="-60" y="-30" width="120" height="60" rx="8" class="node-rect" />
                <text text-anchor="middle" y="5" class="node-text">Final Response</text>
              </g>

              <!-- Connectors -->
              <line x1="160" y1="100" x2="240" y2="100" class="chain-line" marker-end="url(#arrow)" />
              <line x1="360" y1="100" x2="470" y2="100" class="chain-line chain-line--active" marker-end="url(#arrow)" />
              <line x1="630" y1="100" x2="790" y2="100" class="chain-line" marker-end="url(#arrow)" />
            </svg>
          </div>
        </section>

        <div class="grid-layout">
          <ui5-card class="glass-panel">
            <ui5-card-header slot="header" title-text="Chain Architecture" subtitle-text="Component Definitions"></ui5-card-header>
            <ui5-list separators="None">
              <ui5-li icon="database" description="SAP HANA Cloud Vector Store">Vector Store</ui5-li>
              <ui5-li icon="ai" description="meta-llama/Llama-3.1-8B">Language Model</ui5-li>
              <ui5-li icon="filter" description="Structured Metadata Filtering">Self-Query Retriever</ui5-li>
            </ui5-list>
          </ui5-card>

          <ui5-card class="glass-panel">
            <ui5-card-header slot="header" title-text="Trace Logs" subtitle-text="LangSmith compatible stream"></ui5-card-header>
            <div class="log-stream">
              <div class="log-entry"><span>[14:20:01]</span> Entering Chain: SelfQueryRetriever</div>
              <div class="log-entry"><span>[14:20:02]</span> Invoking LLM for structured query construction...</div>
              <div class="log-entry log-entry--info"><span>[14:20:03]</span> SQL Generated: SELECT * FROM BANKING_DOCS WHERE REGION = 'EMEA'</div>
              <div class="log-entry"><span>[14:20:04]</span> HANA Vector Search (top_k=5)...</div>
            </div>
          </ui5-card>
        </div>
      </div>
    </ui5-page>
  `,
  styles: [`
    .langchain-aura {
      background: radial-gradient(circle at 100% 100%, rgba(0, 143, 211, 0.08) 0%, transparent 40%),
                  var(--sapBackgroundColor);
    }
    .lab-content { padding: 1.5rem; max-width: 1400px; margin: 0 auto; display: flex; flex-direction: column; gap: 1.5rem; }
    
    .glass-card {
      background: rgba(255, 255, 255, 0.72);
      backdrop-filter: blur(12px);
      border: 1px solid rgba(255, 255, 255, 0.4);
      border-radius: 1rem;
      padding: 1.5rem;
    }

    .chain-viewer { height: 300px; display: flex; flex-direction: column; }
    .svg-container { flex: 1; display: flex; align-items: center; justify-content: center; }
    .chain-svg { width: 100%; height: auto; }

    .node-rect { fill: #fff; stroke: var(--sapList_BorderColor); stroke-width: 2; }
    .node-text { font-size: 12px; font-weight: 600; fill: var(--sapTextColor); }
    .chain-node--active .node-rect { stroke: var(--sapBrandColor); stroke-width: 3; filter: drop-shadow(0 0 8px rgba(8, 84, 160, 0.2)); }
    
    .chain-line { stroke: var(--sapList_BorderColor); stroke-width: 2; }
    .chain-line--active { stroke: var(--sapBrandColor); stroke-dasharray: 5 2; animation: dash 1s linear infinite; }
    @keyframes dash { to { stroke-dashoffset: -7; } }

    .grid-layout { display: grid; grid-template-columns: 1fr 1fr; gap: 1.5rem; }
    .glass-panel { background: rgba(255, 255, 255, 0.7) !important; backdrop-filter: blur(10px); }

    .log-stream { padding: 1rem; font-family: monospace; font-size: 0.8rem; height: 200px; overflow-y: auto; display: flex; flex-direction: column; gap: 0.5rem; }
    .log-entry span { color: var(--sapContent_LabelColor); }
    .log-entry--info { color: var(--sapBrandColor); font-weight: bold; }
  `]
})
export class LangchainLabComponent {}
