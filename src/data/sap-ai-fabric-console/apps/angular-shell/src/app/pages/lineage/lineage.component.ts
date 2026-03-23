import { Component, DestroyRef, OnInit, inject } from '@angular/core';
import { CommonModule } from '@angular/common';
import { FormsModule } from '@angular/forms';
import { Ui5WebcomponentsModule } from '@ui5/webcomponents-ngx';
import { takeUntilDestroyed } from '@angular/core/rxjs-interop';

import {
  GraphIndexRequest,
  GraphIndexResponse,
  GraphQueryResponse,
  GraphSummaryResponse,
  LineageService,
} from '../../services/api/lineage.service';

@Component({
  selector: 'app-lineage',
  standalone: true,
  imports: [CommonModule, FormsModule, Ui5WebcomponentsModule],
  template: `
    <ui5-page background-design="Solid">
      <ui5-bar slot="header" design="Header">
        <ui5-title slot="startContent" level="H3">Data Lineage</ui5-title>
      </ui5-bar>
      <div class="lineage-content">
        <ui5-message-strip *ngIf="error" design="Negative" [hideCloseButton]="true">
          {{ error }}
        </ui5-message-strip>

        <ui5-card>
          <ui5-card-header slot="header" title-text="Graph Summary"></ui5-card-header>
          <div class="summary-grid">
            <div class="summary-item">
              <div class="summary-value">{{ graphSummary.node_count }}</div>
              <div class="summary-label">Nodes</div>
            </div>
            <div class="summary-item">
              <div class="summary-value">{{ graphSummary.edge_count }}</div>
              <div class="summary-label">Edges</div>
            </div>
            <div class="summary-detail">
              <strong>Node Types:</strong> {{ formatTypes(graphSummary.node_types) }}
            </div>
            <div class="summary-detail">
              <strong>Edge Types:</strong> {{ formatTypes(graphSummary.edge_types) }}
            </div>
            <ui5-button design="Transparent" icon="refresh" (click)="refreshSummary()" [disabled]="summaryLoading">
              {{ summaryLoading ? 'Refreshing...' : 'Refresh Summary' }}
            </ui5-button>
          </div>
        </ui5-card>

        <ui5-card>
          <ui5-card-header slot="header" title-text="KùzuDB Graph Query"></ui5-card-header>
          <div class="query-area">
            <ui5-textarea [(ngModel)]="cypherQuery" placeholder="MATCH (n) RETURN n LIMIT 10" [rows]="3"></ui5-textarea>
            <ui5-button design="Emphasized" (click)="runQuery()" [disabled]="queryLoading || !cypherQuery.trim()">
              {{ queryLoading ? 'Running...' : 'Run Query' }}
            </ui5-button>
          </div>
          <div *ngIf="queryResult" class="result-area">
            <h4>Results ({{ queryResult.row_count }} rows):</h4>
            <pre>{{ queryResult.rows | json }}</pre>
          </div>
        </ui5-card>

        <ui5-card>
          <ui5-card-header slot="header" title-text="Index Entities"></ui5-card-header>
          <div class="query-area">
            <ui5-textarea
              [(ngModel)]="indexPayload"
              placeholder='{"vector_stores": [], "deployments": [], "schemas": []}'
              [rows]="8">
            </ui5-textarea>
            <ui5-button design="Attention" (click)="indexEntities()" [disabled]="indexLoading">
              {{ indexLoading ? 'Indexing...' : 'Index Entities' }}
            </ui5-button>
          </div>
          <div *ngIf="indexResult" class="result-area">
            <h4>Index Result</h4>
            <pre>{{ indexResult | json }}</pre>
          </div>
        </ui5-card>
      </div>
    </ui5-page>
  `,
  styles: [`
    .lineage-content { padding: 1rem; }
    .summary-grid {
      padding: 1rem;
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(160px, 1fr));
      gap: 1rem;
      align-items: start;
    }
    .summary-item {
      padding: 1rem;
      border: 1px solid var(--sapList_BorderColor);
      border-radius: 0.5rem;
      background: var(--sapList_Background);
    }
    .summary-value { font-size: 2rem; font-weight: bold; color: var(--sapBrandColor); }
    .summary-label { color: var(--sapContent_LabelColor); }
    .summary-detail { grid-column: 1 / -1; }
    .query-area { padding: 1rem; display: flex; flex-direction: column; gap: 0.5rem; }
    .result-area { padding: 1rem; border-top: 1px solid var(--sapList_BorderColor); }
    pre { background: var(--sapList_Background); padding: 1rem; overflow: auto; max-height: 400px; border-radius: 0.25rem; }
    ui5-message-strip { margin-bottom: 1rem; }
  `]
})
export class LineageComponent implements OnInit {
  private readonly lineageService = inject(LineageService);
  private readonly destroyRef = inject(DestroyRef);

  cypherQuery = 'MATCH (n) RETURN n LIMIT 10';
  indexPayload = '{\n  "vector_stores": [],\n  "deployments": [],\n  "schemas": []\n}';
  graphSummary: GraphSummaryResponse = {
    node_count: 0,
    edge_count: 0,
    node_types: [],
    edge_types: [],
  };
  queryResult: GraphQueryResponse | null = null;
  indexResult: GraphIndexResponse | null = null;
  queryLoading = false;
  summaryLoading = false;
  indexLoading = false;
  error = '';

  ngOnInit(): void {
    this.refreshSummary();
  }

  runQuery(): void {
    if (!this.cypherQuery.trim()) {
      return;
    }

    this.queryLoading = true;
    this.error = '';

    this.lineageService.graphQuery({ cypher: this.cypherQuery.trim() })
      .pipe(takeUntilDestroyed(this.destroyRef))
      .subscribe({
        next: result => {
          this.queryResult = result;
          this.queryLoading = false;
        },
        error: error => {
          this.error = this.getErrorMessage(error, 'Graph query failed. Check your Cypher syntax.');
          this.queryLoading = false;
        }
      });
  }

  refreshSummary(): void {
    this.summaryLoading = true;
    this.error = '';

    this.lineageService.getGraphSummary()
      .pipe(takeUntilDestroyed(this.destroyRef))
      .subscribe({
        next: summary => {
          this.graphSummary = summary;
          this.summaryLoading = false;
        },
        error: error => {
          this.error = this.getErrorMessage(error, 'Failed to load graph summary.');
          this.summaryLoading = false;
        }
      });
  }

  indexEntities(): void {
    const parsedPayload = this.parseIndexPayload();
    if (!parsedPayload) {
      return;
    }

    this.indexLoading = true;
    this.error = '';

    this.lineageService.indexEntities(parsedPayload)
      .pipe(takeUntilDestroyed(this.destroyRef))
      .subscribe({
        next: result => {
          this.indexResult = result;
          this.indexLoading = false;
          this.refreshSummary();
        },
        error: error => {
          this.error = this.getErrorMessage(error, 'Failed to index lineage entities.');
          this.indexLoading = false;
        }
      });
  }

  formatTypes(types: string[]): string {
    return types.length > 0 ? types.join(', ') : 'None';
  }

  private parseIndexPayload(): GraphIndexRequest | null {
    try {
      const parsed = (this.indexPayload.trim() ? JSON.parse(this.indexPayload) : {}) as Record<string, unknown>;

      return {
        vector_stores: Array.isArray(parsed['vector_stores']) ? parsed['vector_stores'] : [],
        deployments: Array.isArray(parsed['deployments']) ? parsed['deployments'] : [],
        schemas: Array.isArray(parsed['schemas']) ? parsed['schemas'] : [],
      };
    } catch {
      this.error = 'Index payload must be valid JSON.';
      return null;
    }
  }

  private getErrorMessage(error: unknown, fallback: string): string {
    if (typeof error === 'object' && error !== null) {
      const apiError = error as { error?: { detail?: string }; message?: string };
      if (typeof apiError.error?.detail === 'string') {
        return apiError.error.detail;
      }
      if (typeof apiError.message === 'string') {
        return apiError.message;
      }
    }

    return fallback;
  }
}
