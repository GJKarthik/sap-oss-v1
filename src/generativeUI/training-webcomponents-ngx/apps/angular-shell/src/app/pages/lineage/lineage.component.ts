import { Component, DestroyRef, OnInit, inject, ElementRef, ViewChild, AfterViewChecked } from '@angular/core';
import { CommonModule } from '@angular/common';
import { FormsModule } from '@angular/forms';
import { Ui5TrainingComponentsModule } from '../../shared/ui5-training-components.module';
import { takeUntilDestroyed } from '@angular/core/rxjs-interop';
import { EmptyStateComponent, CrossAppLinkComponent } from '../../shared';
import { TranslatePipe } from '../../shared/pipes/translate.pipe';
import {
  PersonalKnowledgeBase,
  PersonalKnowledgeService,
} from '../../services/personal-knowledge.service';

interface GraphNode { id: string; label: string; type: string; x: number; y: number; }
interface GraphEdge { source: string; target: string; label: string; }

@Component({
  selector: 'app-lineage',
  standalone: true,
  imports: [CommonModule, FormsModule, Ui5TrainingComponentsModule, EmptyStateComponent, TranslatePipe, CrossAppLinkComponent],
  template: `
    <ui5-page background-design="Solid">
      <ui5-bar slot="header" design="Header">
        <ui5-title slot="startContent" level="H3">Personal Knowledge Graph</ui5-title>
        <ui5-button slot="endContent" icon="refresh" (click)="refresh()" [disabled]="loading" aria-label="Refresh knowledge graph">
          {{ loading ? ('common.loading' | translate) : ('common.refresh' | translate) }}
        </ui5-button>
      </ui5-bar>

      <app-cross-app-link
        targetApp="training"
        targetRoute="/rag-studio"
        targetLabelKey="nav.ragStudio"
        icon="database">
      </app-cross-app-link>

      <div class="lineage-content" role="region" aria-label="Personal knowledge graph explorer">
        <div class="loading-container" *ngIf="summaryLoading" role="status" aria-live="polite">
          <ui5-busy-indicator active size="M"></ui5-busy-indicator>
          <span class="loading-text">Loading knowledge graph…</span>
        </div>

        <ui5-message-strip *ngIf="error" design="Negative" [hideCloseButton]="false" (close)="error = ''" role="alert">{{ error }}</ui5-message-strip>

        <!-- Summary bar -->
        <div class="summary-bar">
          <div class="summary-item"><span>Nodes</span><ui5-tag design="Information">{{ summary.node_count }}</ui5-tag></div>
          <div class="summary-item"><span>Relationships</span><ui5-tag design="Information">{{ summary.edge_count }}</ui5-tag></div>
          <div class="summary-item" *ngIf="summary.status"><span>Status</span>
            <ui5-tag [design]="statusTagDesign(summary.status)">{{ summary.status }}</ui5-tag>
          </div>
          <div class="summary-spacer"></div>
          <ui5-button *ngIf="graphNodes.length" [design]="viewMode === 'graph' ? 'Emphasized' : 'Default'" (click)="viewMode = 'graph'">Graph</ui5-button>
          <ui5-button *ngIf="graphNodes.length" [design]="viewMode === 'table' ? 'Emphasized' : 'Default'" (click)="viewMode = 'table'">Table</ui5-button>
        </div>

        <!-- Visual graph -->
        <ui5-card *ngIf="graphNodes.length && viewMode === 'graph'" class="graph-card">
          <ui5-card-header slot="header" titleText="Knowledge Graph" [subtitleText]="graphNodes.length + ' nodes · ' + graphEdges.length + ' relationships'"></ui5-card-header>
          <div class="graph-viewport" #graphViewport>
            <svg [attr.width]="svgWidth" [attr.height]="svgHeight" class="graph-svg">
              <defs>
                <marker id="arrowhead" markerWidth="10" markerHeight="7" refX="28" refY="3.5" orient="auto"><polygon points="0 0, 10 3.5, 0 7" fill="var(--sapContent_IconColor)"/></marker>
              </defs>
              <!-- Edges -->
              <g *ngFor="let edge of graphEdges">
                <line [attr.x1]="getNode(edge.source)?.x" [attr.y1]="getNode(edge.source)?.y" [attr.x2]="getNode(edge.target)?.x" [attr.y2]="getNode(edge.target)?.y" class="graph-edge" marker-end="url(#arrowhead)"/>
                <text [attr.x]="edgeMidX(edge)" [attr.y]="edgeMidY(edge) - 6" class="edge-label">{{ edge.label }}</text>
              </g>
              <!-- Nodes -->
              <g *ngFor="let node of graphNodes" class="graph-node-group" (click)="selectNode(node)">
                <circle [attr.cx]="node.x" [attr.cy]="node.y" r="22" [class.selected]="selectedNode?.id === node.id" [attr.fill]="nodeColor(node.type)"/>
                <text [attr.x]="node.x" [attr.y]="node.y + 4" class="node-label">{{ node.label | slice:0:8 }}</text>
                <text [attr.x]="node.x" [attr.y]="node.y + 38" class="node-type-label">{{ node.type }}</text>
              </g>
            </svg>
          </div>
        </ui5-card>

        <!-- Node detail panel -->
        <ui5-card *ngIf="selectedNode" class="detail-card">
          <ui5-card-header slot="header" [titleText]="selectedNode.label" [subtitleText]="'Type: ' + selectedNode.type">
          </ui5-card-header>
          <div class="detail-body">
            <div class="detail-row"><span class="detail-label">ID</span><span>{{ selectedNode.id }}</span></div>
            <div class="detail-row"><span class="detail-label">Type</span><ui5-tag design="Information">{{ selectedNode.type }}</ui5-tag></div>
            <div class="detail-row"><span class="detail-label">Connections</span><span>{{ getConnectionCount(selectedNode.id) }} edges</span></div>
            <div *ngIf="vocabAnnotations[selectedNode.id]" class="annotation-badges">
              <span class="detail-label">Signals</span>
              <div class="badge-row">
                <ui5-badge *ngFor="let ann of vocabAnnotations[selectedNode.id]" [colorScheme]="ann.colorScheme">{{ ann.label }}</ui5-badge>
              </div>
            </div>
            <ui5-button design="Transparent" icon="decline" (click)="selectedNode = null">{{ 'common.close' | translate }}</ui5-button>
          </div>
        </ui5-card>

        <!-- Table view -->
        <ui5-card *ngIf="graphNodes.length && viewMode === 'table'">
          <ui5-card-header slot="header" titleText="Graph Results" [subtitleText]="queryResult?.rowCount + ' rows'"></ui5-card-header>
          <div class="result-area"><pre>{{ queryResult?.rows | json }}</pre></div>
        </ui5-card>

        <!-- Query input -->
        <ui5-card>
          <ui5-card-header slot="header" titleText="Graph Query" subtitleText="Explore remembered bases, documents, wiki pages, and inferred concepts."></ui5-card-header>
          <div class="query-area">
            <div class="field-group">
              <label class="detail-label">Scope</label>
              <select class="graph-select" [(ngModel)]="selectedKnowledgeBaseId" (ngModelChange)="refresh()">
                <option value="">All knowledge bases</option>
                <option *ngFor="let base of knowledgeBases" [value]="base.id">{{ base.name }}</option>
              </select>
            </div>
            <div class="query-presets">
              <ui5-button *ngFor="let q of presetQueries" design="Default" (click)="lineageQuery = q.query; runQuery()">{{ q.label }}</ui5-button>
            </div>
            <ui5-textarea id="lineage-query" ngDefaultControl [(ngModel)]="lineageQuery" placeholder="show graph relationships" [rows]="3" accessible-name="Knowledge graph query input"></ui5-textarea>
            <ui5-button design="Emphasized" icon="play" (click)="runQuery()" [disabled]="loading || !lineageQuery.trim()">{{ loading ? 'Running…' : 'Run Query' }}</ui5-button>
          </div>
          <app-empty-state *ngIf="!loading && !queryResult && !summaryLoading && !graphNodes.length" icon="explorer" title="Explore your graph" description="Run a graph query to see how knowledge bases, documents, wiki pages, and concepts connect."></app-empty-state>
        </ui5-card>
      </div>
    </ui5-page>
  `,
  styles: [`
    .lineage-content { padding: 1rem; max-width: 1400px; margin: 0 auto; display: flex; flex-direction: column; gap: 1rem; }
    .loading-container { display: flex; align-items: center; justify-content: center; padding: 2rem; gap: 1rem; }
    .loading-text { color: var(--sapContent_LabelColor); }
    .summary-bar { display: flex; gap: 1rem; align-items: center; flex-wrap: wrap; padding: 0.5rem 0; }
    .summary-item { display: flex; flex-direction: column; gap: 0.25rem; }
    .summary-item span:first-child { font-size: var(--sapFontSmallSize); color: var(--sapContent_LabelColor); }
    .summary-spacer { flex: 1; }
    .graph-card { overflow: hidden; }
    .graph-viewport { overflow: auto; background: var(--sapShell_Background, #f5f6f7); border-top: 1px solid var(--sapList_BorderColor); min-height: 400px; max-height: 600px; }
    .graph-svg { display: block; }
    .graph-edge { stroke: var(--sapContent_IconColor); stroke-width: 1.5; opacity: 0.5; }
    .edge-label { font-size: 10px; fill: var(--sapContent_LabelColor); text-anchor: middle; }
    .graph-node-group { cursor: pointer; }
    .graph-node-group circle { stroke: var(--sapContent_ForegroundBorderColor); stroke-width: 2; transition: stroke-width 0.15s; }
    .graph-node-group circle.selected { stroke: var(--sapSelectedColor, #0854a0); stroke-width: 3; }
    .graph-node-group:hover circle { stroke-width: 3; }
    .node-label { font-size: 11px; fill: #fff; text-anchor: middle; font-weight: 600; pointer-events: none; }
    .node-type-label { font-size: 9px; fill: var(--sapContent_LabelColor); text-anchor: middle; pointer-events: none; }
    .detail-card { max-width: 400px; }
    .detail-body { padding: 1rem; display: flex; flex-direction: column; gap: 0.5rem; }
    .detail-row { display: flex; justify-content: space-between; align-items: center; }
    .detail-label { font-weight: 600; color: var(--sapContent_LabelColor); font-size: var(--sapFontSmallSize); }
    .annotation-badges { display: flex; flex-direction: column; gap: 0.25rem; }
    .badge-row { display: flex; gap: 0.25rem; flex-wrap: wrap; }
    .query-area { padding: 1rem; display: flex; flex-direction: column; gap: 0.75rem; }
    .field-group { display: flex; flex-direction: column; gap: 0.4rem; max-width: 320px; }
    .graph-select {
      width: 100%;
      padding: 0.5rem 0.75rem;
      border: 1px solid var(--sapField_BorderColor, #89919a);
      border-radius: 0.375rem;
      background: var(--sapField_Background, #fff);
      color: var(--sapTextColor, #32363a);
      font: inherit;
    }
    .query-presets { display: flex; gap: 0.5rem; flex-wrap: wrap; }
    .result-area { padding: 1rem; border-top: 1px solid var(--sapList_BorderColor); }
    pre { background: var(--sapList_Background); padding: 1rem; overflow: auto; max-height: 300px; border-radius: 0.25rem; margin: 0; font-family: 'SFMono-Regular', Consolas, monospace; font-size: var(--sapFontSmallSize); }
    @media (max-width: 768px) { .lineage-content { padding: 0.75rem; } }
  `]
})
export class LineageComponent implements OnInit {
  private readonly knowledge = inject(PersonalKnowledgeService);
  private readonly destroyRef = inject(DestroyRef);

  lineageQuery = 'show graph relationships';
  queryResult: { rows: unknown[]; rowCount: number } | null = null;
  summary: { node_count: number; edge_count: number; status?: string; error?: string } = { node_count: 0, edge_count: 0, status: 'loading' };
  loading = false;
  summaryLoading = true;
  error = '';
  knowledgeBases: PersonalKnowledgeBase[] = [];
  selectedKnowledgeBaseId = '';

  graphNodes: GraphNode[] = [];
  graphEdges: GraphEdge[] = [];
  selectedNode: GraphNode | null = null;
  viewMode: 'graph' | 'table' = 'graph';
  svgWidth = 900;
  svgHeight = 500;
  vocabAnnotations: Record<string, Array<{ label: string; colorScheme: string }>> = {};

  get presetQueries() {
    return [
      { label: 'Graph relationships', query: 'show graph relationships' },
      { label: 'Knowledge bases', query: 'show knowledge base nodes' },
      { label: 'Document sources', query: 'show documents' },
      { label: 'Wiki pages', query: 'show wiki pages' },
      { label: 'Concepts', query: 'show concepts' },
    ];
  }

  private readonly NODE_COLORS: Record<string, string> = {
    KnowledgeBase: '#0854a0',
    WikiPage: '#107e3e',
    Document: '#e9730c',
    Concept: '#6c32a9',
    default: '#5b738b',
  };

  ngOnInit(): void {
    this.loadKnowledgeBases();
    this.loadSummary();
  }

  refresh(): void { this.loadSummary(); this.queryResult = null; this.graphNodes = []; this.graphEdges = []; this.selectedNode = null; }

  getNode(id: string): GraphNode | undefined { return this.graphNodes.find(n => n.id === id); }
  nodeColor(type: string): string { return this.NODE_COLORS[type] || this.NODE_COLORS['default']; }
  selectNode(node: GraphNode): void { this.selectedNode = this.selectedNode?.id === node.id ? null : node; }
  edgeMidX(e: GraphEdge): number { const s = this.getNode(e.source), t = this.getNode(e.target); return s && t ? (s.x + t.x) / 2 : 0; }
  edgeMidY(e: GraphEdge): number { const s = this.getNode(e.source), t = this.getNode(e.target); return s && t ? (s.y + t.y) / 2 : 0; }
  getConnectionCount(id: string): number { return this.graphEdges.filter(e => e.source === id || e.target === id).length; }

  private loadSummary(): void {
    this.summaryLoading = true;
    this.error = '';
    this.knowledge.getGraphSummary(this.selectedKnowledgeBaseId || undefined).pipe(takeUntilDestroyed(this.destroyRef)).subscribe({
      next: summary => {
        this.summary = { ...summary, status: summary.status || 'ready' };
        this.summaryLoading = false;
        this.runQuery();
      },
      error: () => { this.summary = { node_count: 0, edge_count: 0, status: 'unavailable' }; this.summaryLoading = false; }
    });
  }

  statusTagDesign(status?: string): 'Critical' | 'Information' | 'Positive' {
    if (!status) return 'Information';
    if (status === 'loading') return 'Information';
    if (status.includes('unavailable') || status.includes('error')) return 'Critical';
    return 'Positive';
  }

  private loadKnowledgeBases(): void {
    this.knowledge.listBases().pipe(takeUntilDestroyed(this.destroyRef)).subscribe({
      next: (bases) => {
        this.knowledgeBases = bases;
      },
      error: () => {
        this.knowledgeBases = [];
      },
    });
  }

  runQuery(): void {
    if (!this.lineageQuery.trim()) return;
    this.loading = true;
    this.error = '';
    this.knowledge.queryGraph(this.lineageQuery, { baseId: this.selectedKnowledgeBaseId || undefined }).pipe(takeUntilDestroyed(this.destroyRef)).subscribe({
      next: r => { this.queryResult = { rows: r.rows, rowCount: r.row_count }; this.buildGraph(r.rows); this.loading = false; },
      error: () => { this.error = 'Knowledge graph query failed'; this.loading = false; }
    });
  }

  /** Extract nodes and edges from query result rows and layout in a force-free circle. */
  private buildGraph(rows: unknown[]): void {
    const nodeMap = new Map<string, GraphNode>();
    const edges: GraphEdge[] = [];
    this.vocabAnnotations = {};

    for (const row of rows) {
      if (!row || typeof row !== 'object') continue;
      const record = row as Record<string, unknown>;
      if (record['source_id'] && record['target_id']) {
        const sourceId = String(record['source_id']);
        const targetId = String(record['target_id']);
        const sourceName = String(record['source_name'] ?? sourceId).slice(0, 20);
        const targetName = String(record['target_name'] ?? targetId).slice(0, 20);
        const sourceType = String(record['source_type'] ?? 'Node');
        const targetType = String(record['target_type'] ?? 'Node');
        if (!nodeMap.has(sourceId)) {
          nodeMap.set(sourceId, { id: sourceId, label: sourceName, type: sourceType, x: 0, y: 0 });
        }
        if (!nodeMap.has(targetId)) {
          nodeMap.set(targetId, { id: targetId, label: targetName, type: targetType, x: 0, y: 0 });
        }
        edges.push({ source: sourceId, target: targetId, label: String(record['relationship'] ?? '') });
        if (targetType === 'Concept') {
          const relationship = String(record['relationship'] ?? 'related');
          this.vocabAnnotations[targetId] = [{ label: relationship, colorScheme: '8' }];
        }
        continue;
      }

      if (record['id'] || record['name']) {
        const id = String(record['id'] ?? record['name']);
        const label = String(record['name'] ?? record['label'] ?? id).slice(0, 20);
        const type = String(record['type'] ?? 'Node');
        if (!nodeMap.has(id)) {
          nodeMap.set(id, { id, label, type, x: 0, y: 0 });
        }
      }
    }

    // Circle layout
    const nodes = Array.from(nodeMap.values());
    const cx = 450, cy = 250, radius = Math.min(200, 40 * nodes.length);
    nodes.forEach((n, i) => {
      const angle = (2 * Math.PI * i) / Math.max(nodes.length, 1) - Math.PI / 2;
      n.x = cx + radius * Math.cos(angle);
      n.y = cy + radius * Math.sin(angle);
    });

    this.svgWidth = Math.max(900, cx + radius + 80);
    this.svgHeight = Math.max(500, cy + radius + 80);
    this.graphNodes = nodes;
    this.graphEdges = edges.filter(e => nodeMap.has(e.source) && nodeMap.has(e.target));
    this.selectedNode = null;
  }
}
