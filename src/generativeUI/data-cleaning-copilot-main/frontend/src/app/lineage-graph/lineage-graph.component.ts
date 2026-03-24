// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2024 SAP SE
import { Component, OnInit, OnDestroy, inject, signal, computed, ElementRef, ViewChild, AfterViewInit } from '@angular/core';
import { CommonModule } from '@angular/common';
import { FormsModule } from '@angular/forms';
import { Subject, takeUntil } from 'rxjs';
import { CopilotService } from '../copilot.service';

interface LineageNode {
    id: string;
    name: string;
    type: 'table' | 'column' | 'transform' | 'flow';
    isPii?: boolean;
    x?: number;
    y?: number;
}

interface LineageEdge {
    source: string;
    target: string;
    type: 'foreign_key' | 'derives_from' | 'flows_to' | 'copied_from' | 'transformed_from';
    label?: string;
}

interface LineageGraph {
    nodes: LineageNode[];
    edges: LineageEdge[];
}

@Component({
    selector: 'app-lineage-graph',
    standalone: true,
    imports: [CommonModule, FormsModule],
    template: `
        <div class="lineage-container">
            <header class="lineage-header">
                <h1>Data Lineage Graph</h1>
                <div class="controls">
                    <div class="search-box">
                        <input
                            type="text"
                            [(ngModel)]="searchQuery"
                            placeholder="Search table or column..."
                            (keyup.enter)="searchLineage()"
                        />
                        <button class="btn-search" (click)="searchLineage()">🔍</button>
                    </div>
                    <div class="view-controls">
                        <button [class.active]="viewMode() === 'upstream'" (click)="setViewMode('upstream')">
                            ⬆️ Upstream
                        </button>
                        <button [class.active]="viewMode() === 'downstream'" (click)="setViewMode('downstream')">
                            ⬇️ Downstream
                        </button>
                        <button [class.active]="viewMode() === 'both'" (click)="setViewMode('both')">
                            ↕️ Both
                        </button>
                    </div>
                </div>
            </header>

            <!-- Legend -->
            <div class="legend">
                <div class="legend-item">
                    <span class="node-indicator table"></span>
                    <span>Table</span>
                </div>
                <div class="legend-item">
                    <span class="node-indicator column"></span>
                    <span>Column</span>
                </div>
                <div class="legend-item">
                    <span class="node-indicator pii"></span>
                    <span>PII Column</span>
                </div>
                <div class="legend-item">
                    <span class="node-indicator transform"></span>
                    <span>Transform</span>
                </div>
                <div class="legend-item">
                    <span class="edge-indicator fk"></span>
                    <span>Foreign Key</span>
                </div>
                <div class="legend-item">
                    <span class="edge-indicator derived"></span>
                    <span>Derived From</span>
                </div>
            </div>

            <!-- Graph Canvas -->
            <div class="graph-container" #graphContainer>
                <svg #graphSvg [attr.width]="svgWidth" [attr.height]="svgHeight">
                    <!-- Edges -->
                    <g class="edges">
                        @for (edge of graph().edges; track edge.source + edge.target) {
                            <g class="edge" [class]="edge.type">
                                <line
                                    [attr.x1]="getNodeX(edge.source)"
                                    [attr.y1]="getNodeY(edge.source)"
                                    [attr.x2]="getNodeX(edge.target)"
                                    [attr.y2]="getNodeY(edge.target)"
                                    [attr.marker-end]="'url(#arrow)'"
                                />
                                @if (edge.label) {
                                    <text
                                        [attr.x]="(getNodeX(edge.source) + getNodeX(edge.target)) / 2"
                                        [attr.y]="(getNodeY(edge.source) + getNodeY(edge.target)) / 2 - 5"
                                        class="edge-label">
                                        {{ edge.label }}
                                    </text>
                                }
                            </g>
                        }
                    </g>

                    <!-- Arrow marker definition -->
                    <defs>
                        <marker id="arrow" markerWidth="10" markerHeight="10" refX="9" refY="3" orient="auto">
                            <path d="M0,0 L0,6 L9,3 z" fill="#666" />
                        </marker>
                    </defs>

                    <!-- Nodes -->
                    <g class="nodes">
                        @for (node of graph().nodes; track node.id) {
                            <g
                                class="node"
                                [class]="node.type"
                                [class.pii]="node.isPii"
                                [class.selected]="selectedNode() === node.id"
                                [attr.transform]="'translate(' + (node.x || 0) + ',' + (node.y || 0) + ')'"
                                (click)="selectNode(node)"
                            >
                                @if (node.type === 'table') {
                                    <rect x="-50" y="-20" width="100" height="40" rx="4" />
                                    <text class="node-label" dy="5">{{ node.name }}</text>
                                }
                                @if (node.type === 'column') {
                                    <ellipse rx="40" ry="18" />
                                    <text class="node-label" dy="5">{{ node.name }}</text>
                                    @if (node.isPii) {
                                        <text class="pii-badge" x="25" y="-12">🔒</text>
                                    }
                                }
                                @if (node.type === 'transform') {
                                    <polygon points="-30,-20 30,-20 40,0 30,20 -30,20 -40,0" />
                                    <text class="node-label" dy="5">{{ node.name }}</text>
                                }
                            </g>
                        }
                    </g>
                </svg>

                @if (graph().nodes.length === 0 && !loading()) {
                    <div class="empty-state">
                        <div class="empty-icon">🔗</div>
                        <h3>No lineage data</h3>
                        <p>Search for a table or column to view its data lineage.</p>
                    </div>
                }

                @if (loading()) {
                    <div class="loading-overlay">
                        <div class="spinner"></div>
                        <p>Loading lineage...</p>
                    </div>
                }
            </div>

            <!-- Selected Node Details -->
            @if (selectedNode() && selectedNodeData()) {
                <div class="node-details">
                    <div class="details-header">
                        <h3>{{ selectedNodeData()!.name }}</h3>
                        <button class="btn-close" (click)="clearSelection()">×</button>
                    </div>
                    <div class="details-body">
                        <div class="detail-row">
                            <span class="label">Type:</span>
                            <span class="value">{{ selectedNodeData()!.type | titlecase }}</span>
                        </div>
                        @if (selectedNodeData()!.isPii) {
                            <div class="detail-row pii">
                                <span class="label">⚠️ PII:</span>
                                <span class="value">Yes - Contains personally identifiable information</span>
                            </div>
                        }
                        <div class="detail-row">
                            <span class="label">Upstream:</span>
                            <span class="value">{{ getUpstreamCount() }} sources</span>
                        </div>
                        <div class="detail-row">
                            <span class="label">Downstream:</span>
                            <span class="value">{{ getDownstreamCount() }} consumers</span>
                        </div>
                    </div>
                    <div class="details-actions">
                        <button class="btn-secondary" (click)="focusUpstream()">Show Upstream</button>
                        <button class="btn-secondary" (click)="focusDownstream()">Show Downstream</button>
                        @if (selectedNodeData()!.isPii) {
                            <button class="btn-primary" (click)="showPiiExposure()">PII Exposure</button>
                        }
                    </div>
                </div>
            }

            <!-- PII Exposure Panel -->
            @if (showingPiiExposure()) {
                <div class="pii-panel">
                    <div class="panel-header">
                        <h3>PII Exposure Analysis</h3>
                        <button class="btn-close" (click)="closePiiPanel()">×</button>
                    </div>
                    <div class="panel-body">
                        <div class="exposure-section">
                            <h4>📥 Source</h4>
                            <div class="exposure-item">
                                {{ piiExposure()?.source?.table }}.{{ piiExposure()?.source?.column }}
                            </div>
                        </div>
                        @if (piiExposure()?.downstream && piiExposure()!.downstream.length > 0) {
                            <div class="exposure-section">
                                <h4>📤 Downstream Copies ({{ piiExposure()!.downstream.length }})</h4>
                                @for (item of piiExposure()!.downstream; track item.table) {
                                    <div class="exposure-item warning">
                                        {{ item.table }}
                                    </div>
                                }
                            </div>
                        }
                        <div class="exposure-warning">
                            ⚠️ PII data may be present in {{ (piiExposure()?.downstream?.length || 0) + 1 }} locations.
                            Ensure proper access controls and compliance measures.
                        </div>
                    </div>
                </div>
            }
        </div>
    `,
    styles: [
        `
            .lineage-container {
                padding: 20px;
                height: 100vh;
                display: flex;
                flex-direction: column;
                font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
            }

            .lineage-header {
                display: flex;
                justify-content: space-between;
                align-items: center;
                margin-bottom: 16px;
            }

            .lineage-header h1 {
                margin: 0;
                color: #333;
            }

            .controls {
                display: flex;
                gap: 16px;
                align-items: center;
            }

            .search-box {
                display: flex;
                gap: 8px;
            }

            .search-box input {
                padding: 8px 14px;
                border: 1px solid #ddd;
                border-radius: 20px;
                width: 250px;
                font-size: 14px;
            }

            .btn-search {
                background: #2196f3;
                color: white;
                border: none;
                padding: 8px 16px;
                border-radius: 20px;
                cursor: pointer;
            }

            .view-controls {
                display: flex;
                gap: 4px;
            }

            .view-controls button {
                padding: 8px 12px;
                border: 1px solid #ddd;
                background: white;
                cursor: pointer;
                font-size: 13px;
            }

            .view-controls button:first-child {
                border-radius: 20px 0 0 20px;
            }

            .view-controls button:last-child {
                border-radius: 0 20px 20px 0;
            }

            .view-controls button.active {
                background: #2196f3;
                color: white;
                border-color: #2196f3;
            }

            .legend {
                display: flex;
                gap: 20px;
                padding: 12px;
                background: #f5f5f5;
                border-radius: 8px;
                margin-bottom: 16px;
            }

            .legend-item {
                display: flex;
                align-items: center;
                gap: 8px;
                font-size: 13px;
            }

            .node-indicator {
                width: 20px;
                height: 14px;
                border-radius: 2px;
            }

            .node-indicator.table {
                background: #2196f3;
            }

            .node-indicator.column {
                background: #4caf50;
                border-radius: 50%;
            }

            .node-indicator.pii {
                background: #ff5722;
                border-radius: 50%;
            }

            .node-indicator.transform {
                background: #9c27b0;
                clip-path: polygon(20% 0%, 80% 0%, 100% 50%, 80% 100%, 20% 100%, 0% 50%);
            }

            .edge-indicator {
                width: 24px;
                height: 2px;
            }

            .edge-indicator.fk {
                background: #666;
            }

            .edge-indicator.derived {
                background: #ff9800;
                border-style: dashed;
            }

            .graph-container {
                flex: 1;
                background: white;
                border: 1px solid #e0e0e0;
                border-radius: 12px;
                overflow: hidden;
                position: relative;
            }

            svg {
                display: block;
            }

            .edges line {
                stroke: #999;
                stroke-width: 1.5;
            }

            .edges .foreign_key line {
                stroke: #666;
            }

            .edges .derives_from line {
                stroke: #ff9800;
                stroke-dasharray: 5, 5;
            }

            .edges .flows_to line {
                stroke: #2196f3;
            }

            .edge-label {
                font-size: 10px;
                fill: #666;
            }

            .node rect {
                fill: #2196f3;
                stroke: #1976d2;
                stroke-width: 2;
            }

            .node ellipse {
                fill: #4caf50;
                stroke: #388e3c;
                stroke-width: 2;
            }

            .node.pii ellipse {
                fill: #ff5722;
                stroke: #e64a19;
            }

            .node polygon {
                fill: #9c27b0;
                stroke: #7b1fa2;
                stroke-width: 2;
            }

            .node.selected rect,
            .node.selected ellipse,
            .node.selected polygon {
                stroke: #ff5722;
                stroke-width: 3;
            }

            .node-label {
                fill: white;
                font-size: 12px;
                text-anchor: middle;
                font-weight: 500;
            }

            .pii-badge {
                font-size: 14px;
            }

            .node {
                cursor: pointer;
            }

            .node:hover rect,
            .node:hover ellipse,
            .node:hover polygon {
                filter: brightness(1.1);
            }

            .empty-state {
                position: absolute;
                top: 50%;
                left: 50%;
                transform: translate(-50%, -50%);
                text-align: center;
                color: #666;
            }

            .empty-icon {
                font-size: 48px;
                margin-bottom: 16px;
            }

            .loading-overlay {
                position: absolute;
                top: 0;
                left: 0;
                right: 0;
                bottom: 0;
                background: rgba(255, 255, 255, 0.9);
                display: flex;
                flex-direction: column;
                align-items: center;
                justify-content: center;
            }

            .spinner {
                width: 40px;
                height: 40px;
                border: 4px solid #e0e0e0;
                border-top-color: #2196f3;
                border-radius: 50%;
                animation: spin 1s linear infinite;
            }

            @keyframes spin {
                to {
                    transform: rotate(360deg);
                }
            }

            .node-details {
                position: absolute;
                right: 20px;
                top: 80px;
                width: 300px;
                background: white;
                border-radius: 12px;
                box-shadow: 0 4px 20px rgba(0, 0, 0, 0.15);
            }

            .details-header {
                display: flex;
                justify-content: space-between;
                align-items: center;
                padding: 12px 16px;
                border-bottom: 1px solid #e0e0e0;
            }

            .details-header h3 {
                margin: 0;
                font-size: 16px;
            }

            .btn-close {
                background: none;
                border: none;
                font-size: 24px;
                cursor: pointer;
                color: #999;
            }

            .details-body {
                padding: 16px;
            }

            .detail-row {
                display: flex;
                justify-content: space-between;
                padding: 8px 0;
                border-bottom: 1px solid #f0f0f0;
            }

            .detail-row.pii {
                background: #fff3e0;
                margin: 0 -16px;
                padding: 8px 16px;
            }

            .detail-row .label {
                color: #666;
            }

            .detail-row .value {
                font-weight: 500;
            }

            .details-actions {
                padding: 12px 16px;
                border-top: 1px solid #e0e0e0;
                display: flex;
                gap: 8px;
                flex-wrap: wrap;
            }

            .btn-secondary {
                padding: 8px 12px;
                border: 1px solid #ddd;
                background: white;
                border-radius: 6px;
                cursor: pointer;
                font-size: 13px;
            }

            .btn-primary {
                padding: 8px 12px;
                border: none;
                background: #ff5722;
                color: white;
                border-radius: 6px;
                cursor: pointer;
                font-size: 13px;
            }

            .pii-panel {
                position: absolute;
                right: 20px;
                bottom: 20px;
                width: 350px;
                background: white;
                border-radius: 12px;
                box-shadow: 0 4px 20px rgba(0, 0, 0, 0.15);
                border: 2px solid #ff5722;
            }

            .panel-header {
                display: flex;
                justify-content: space-between;
                align-items: center;
                padding: 12px 16px;
                background: #fff3e0;
                border-radius: 10px 10px 0 0;
            }

            .panel-header h3 {
                margin: 0;
                color: #e64a19;
            }

            .panel-body {
                padding: 16px;
            }

            .exposure-section {
                margin-bottom: 16px;
            }

            .exposure-section h4 {
                margin: 0 0 8px;
                font-size: 14px;
            }

            .exposure-item {
                padding: 8px 12px;
                background: #f5f5f5;
                border-radius: 6px;
                margin-bottom: 4px;
                font-family: monospace;
                font-size: 13px;
            }

            .exposure-item.warning {
                background: #ffebee;
                border-left: 3px solid #f44336;
            }

            .exposure-warning {
                padding: 12px;
                background: #fff8e1;
                border-radius: 6px;
                font-size: 13px;
                color: #f57c00;
            }
        `,
    ],
})
export class LineageGraphComponent implements OnInit, OnDestroy, AfterViewInit {
    @ViewChild('graphContainer') graphContainer!: ElementRef;
    @ViewChild('graphSvg') graphSvg!: ElementRef;

    private readonly copilotService = inject(CopilotService);
    private readonly destroy$ = new Subject<void>();

    // State
    searchQuery = '';
    viewMode = signal<'upstream' | 'downstream' | 'both'>('both');
    loading = signal(false);
    graph = signal<LineageGraph>({ nodes: [], edges: [] });
    selectedNode = signal<string | null>(null);
    showingPiiExposure = signal(false);
    piiExposure = signal<{
        source: { table: string; column: string };
        upstream: Array<{ table: string }>;
        downstream: Array<{ table: string }>;
        pii_copies: Array<{ target_table: string; target_column: string }>;
    } | null>(null);

    // SVG dimensions
    svgWidth = 800;
    svgHeight = 600;

    private nodePositions = new Map<string, { x: number; y: number }>();

    ngOnInit(): void {
        // Load demo graph
        this.loadDemoGraph();
    }

    ngAfterViewInit(): void {
        if (this.graphContainer) {
            this.svgWidth = this.graphContainer.nativeElement.clientWidth || 800;
            this.svgHeight = this.graphContainer.nativeElement.clientHeight || 600;
        }
    }

    ngOnDestroy(): void {
        this.destroy$.next();
        this.destroy$.complete();
    }

    searchLineage(): void {
        if (!this.searchQuery.trim()) return;

        this.loading.set(true);
        
        // Try to query via MCP
        this.copilotService
            .queryGraph(`MATCH (n) WHERE n.name CONTAINS '${this.searchQuery}' RETURN n LIMIT 20`)
            .pipe(takeUntil(this.destroy$))
            .subscribe({
                next: (result) => {
                    // Transform result to graph
                    this.loading.set(false);
                },
                error: () => {
                    // Use filtered demo data
                    this.loadDemoGraph();
                    this.loading.set(false);
                },
            });
    }

    setViewMode(mode: 'upstream' | 'downstream' | 'both'): void {
        this.viewMode.set(mode);
    }

    getNodeX(nodeId: string): number {
        const node = this.graph().nodes.find((n) => n.id === nodeId);
        return node?.x || 0;
    }

    getNodeY(nodeId: string): number {
        const node = this.graph().nodes.find((n) => n.id === nodeId);
        return node?.y || 0;
    }

    selectNode(node: LineageNode): void {
        this.selectedNode.set(node.id);
    }

    selectedNodeData = computed(() => {
        const id = this.selectedNode();
        return this.graph().nodes.find((n) => n.id === id) || null;
    });

    clearSelection(): void {
        this.selectedNode.set(null);
    }

    getUpstreamCount(): number {
        const id = this.selectedNode();
        return this.graph().edges.filter((e) => e.target === id).length;
    }

    getDownstreamCount(): number {
        const id = this.selectedNode();
        return this.graph().edges.filter((e) => e.source === id).length;
    }

    focusUpstream(): void {
        this.viewMode.set('upstream');
    }

    focusDownstream(): void {
        this.viewMode.set('downstream');
    }

    showPiiExposure(): void {
        const node = this.selectedNodeData();
        if (!node) return;

        this.showingPiiExposure.set(true);
        this.piiExposure.set({
            source: { table: 'Users', column: node.name },
            upstream: [],
            downstream: [{ table: 'Customers' }, { table: 'Analytics' }, { table: 'Backup' }],
            pii_copies: [],
        });
    }

    closePiiPanel(): void {
        this.showingPiiExposure.set(false);
    }

    private loadDemoGraph(): void {
        const centerX = this.svgWidth / 2;
        const centerY = this.svgHeight / 2;

        const nodes: LineageNode[] = [
            { id: 'users', name: 'Users', type: 'table', x: centerX, y: 100 },
            { id: 'users_email', name: 'email', type: 'column', isPii: true, x: centerX - 100, y: 200 },
            { id: 'users_name', name: 'name', type: 'column', isPii: true, x: centerX + 100, y: 200 },
            { id: 'orders', name: 'Orders', type: 'table', x: centerX - 150, y: 300 },
            { id: 'customers', name: 'Customers', type: 'table', x: centerX + 150, y: 300 },
            { id: 'etl_transform', name: 'ETL', type: 'transform', x: centerX, y: 400 },
            { id: 'analytics', name: 'Analytics', type: 'table', x: centerX - 100, y: 500 },
            { id: 'reports', name: 'Reports', type: 'table', x: centerX + 100, y: 500 },
        ];

        const edges: LineageEdge[] = [
            { source: 'users', target: 'users_email', type: 'foreign_key' },
            { source: 'users', target: 'users_name', type: 'foreign_key' },
            { source: 'users_email', target: 'customers', type: 'copied_from', label: 'PII copy' },
            { source: 'orders', target: 'etl_transform', type: 'flows_to' },
            { source: 'customers', target: 'etl_transform', type: 'flows_to' },
            { source: 'etl_transform', target: 'analytics', type: 'flows_to' },
            { source: 'etl_transform', target: 'reports', type: 'flows_to' },
        ];

        this.graph.set({ nodes, edges });
    }
}