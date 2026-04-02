import { Component, DestroyRef, OnInit, inject } from '@angular/core';
import { CommonModule } from '@angular/common';
import { FormsModule } from '@angular/forms';
import { Ui5WebcomponentsModule } from '@ui5/webcomponents-ngx';
import { takeUntilDestroyed } from '@angular/core/rxjs-interop';
import { McpService } from '../../services/mcp.service';
import { EmptyStateComponent } from '../../shared';

@Component({
  selector: 'app-lineage',
  standalone: true,
  imports: [CommonModule, FormsModule, Ui5WebcomponentsModule, EmptyStateComponent],
  template: `
    <ui5-page background-design="Solid">
      <ui5-bar slot="header" design="Header">
        <ui5-title slot="startContent" level="H3">Data Lineage</ui5-title>
        <ui5-button 
          slot="endContent" 
          icon="refresh" 
          (click)="refresh()" 
          [disabled]="loading"
          aria-label="Refresh lineage data">
          {{ loading ? 'Loading...' : 'Refresh' }}
        </ui5-button>
      </ui5-bar>
      <div class="lineage-content" role="region" aria-label="Data lineage explorer">
        <!-- Loading indicator -->
        <div class="loading-container" *ngIf="summaryLoading" role="status" aria-live="polite">
          <ui5-busy-indicator active size="M"></ui5-busy-indicator>
          <span class="loading-text">Loading lineage graph...</span>
        </div>

        <ui5-message-strip 
          *ngIf="error" 
          design="Negative" 
          [hideCloseButton]="false"
          (close)="error = ''"
          role="alert">
          {{ error }}
        </ui5-message-strip>

        <ui5-card class="summary-card" [class.card-loading]="summaryLoading">
          <ui5-card-header slot="header" title-text="Graph Summary"></ui5-card-header>
          <div class="summary-grid">
            <div class="summary-item">
              <span>Nodes</span>
              <ui5-tag design="Information">{{ summary.node_count }}</ui5-tag>
            </div>
            <div class="summary-item">
              <span>Edges</span>
              <ui5-tag design="Information">{{ summary.edge_count }}</ui5-tag>
            </div>
            <div class="summary-item" *ngIf="summary.status">
              <span>Status</span>
              <ui5-tag [design]="summary.status === 'kuzu_unavailable' || summary.status === 'unavailable' ? 'Critical' : (summary.status === 'loading' ? 'Information' : 'Positive')">
                {{ summary.status }}
              </ui5-tag>
            </div>
          </div>
        </ui5-card>

        <ui5-card>
          <ui5-card-header 
            slot="header" 
            title-text="KùzuDB Graph Query"
            subtitle-text="Run Cypher queries against the lineage graph">
          </ui5-card-header>
          <div class="query-area">
            <div class="field-group">
              <label for="cypher-query" class="field-label">Cypher Query</label>
              <ui5-textarea 
                id="cypher-query"
                ngDefaultControl 
                [(ngModel)]="cypherQuery" 
                placeholder="MATCH (n) RETURN n LIMIT 10" 
                [rows]="3"
                accessible-name="Cypher query input">
              </ui5-textarea>
            </div>
            <ui5-button 
              design="Emphasized" 
              icon="play"
              (click)="runQuery()" 
              [disabled]="loading || !cypherQuery.trim()"
              aria-label="Execute Cypher query">
              {{ loading ? 'Running...' : 'Run Query' }}
            </ui5-button>
          </div>
          
          <div *ngIf="queryResult" class="result-area" role="region" aria-label="Query results">
            <div class="result-header">
              <h4>Results</h4>
              <ui5-tag design="Information">{{ queryResult.rowCount }} rows</ui5-tag>
            </div>
            <pre>{{ queryResult.rows | json }}</pre>
          </div>

          <app-empty-state
            *ngIf="!loading && !queryResult && !summaryLoading"
            icon="explorer"
            title="Run a Query"
            description="Enter a Cypher query above to explore the data lineage graph.">
          </app-empty-state>
        </ui5-card>
      </div>
    </ui5-page>
  `,
  styles: [`
    .lineage-content { 
      padding: 1rem; 
      max-width: 1200px;
      margin: 0 auto;
      display: flex;
      flex-direction: column;
      gap: 1rem;
    }

    .loading-container {
      display: flex;
      align-items: center;
      justify-content: center;
      padding: 2rem;
      gap: 1rem;
    }

    .loading-text {
      color: var(--sapContent_LabelColor);
    }

    .card-loading {
      opacity: 0.6;
      pointer-events: none;
    }

    .summary-card { 
      max-width: 600px;
    }

    .summary-grid { 
      padding: 1rem; 
      display: flex; 
      gap: 1.5rem; 
      flex-wrap: wrap; 
    }

    .summary-item { 
      display: flex; 
      flex-direction: column;
      gap: 0.25rem; 
    }

    .summary-item span:first-child {
      font-size: var(--sapFontSmallSize);
      color: var(--sapContent_LabelColor);
    }

    .query-area { 
      padding: 1rem; 
      display: flex; 
      flex-direction: column; 
      gap: 1rem; 
    }

    .field-group {
      display: flex;
      flex-direction: column;
      gap: 0.5rem;
    }

    .field-label {
      color: var(--sapContent_LabelColor);
      font-weight: 500;
    }

    .result-area { 
      padding: 1rem; 
      border-top: 1px solid var(--sapList_BorderColor); 
    }

    .result-header {
      display: flex;
      align-items: center;
      gap: 0.75rem;
      margin-bottom: 0.75rem;
    }

    .result-header h4 {
      margin: 0;
      font-size: var(--sapFontSize);
      font-weight: 600;
    }

    pre { 
      background: var(--sapList_Background); 
      padding: 1rem; 
      overflow: auto; 
      max-height: 400px; 
      border-radius: 0.25rem;
      margin: 0;
      font-family: 'SFMono-Regular', Consolas, 'Liberation Mono', Menlo, monospace;
      font-size: var(--sapFontSmallSize);
    }

    @media (max-width: 768px) {
      .lineage-content {
        padding: 0.75rem;
      }
    }
  `]
})
export class LineageComponent implements OnInit {
  private readonly mcpService = inject(McpService);
  private readonly destroyRef = inject(DestroyRef);

  cypherQuery = 'MATCH (n) RETURN n LIMIT 10';
  queryResult: { rows: unknown[]; rowCount: number } | null = null;
  summary: {
    node_count: number;
    edge_count: number;
    status?: string;
    error?: string;
  } = {
    node_count: 0,
    edge_count: 0,
    status: 'loading',
  };
  loading = false;
  summaryLoading = true;
  error = '';

  ngOnInit(): void {
    this.loadSummary();
  }

  refresh(): void {
    this.loadSummary();
    this.queryResult = null;
  }

  private loadSummary(): void {
    this.summaryLoading = true;
    this.error = '';
    this.mcpService.graphSummary()
      .pipe(takeUntilDestroyed(this.destroyRef))
      .subscribe({
        next: summary => {
          this.summary = {
            ...summary,
            status: summary.status || 'ready',
          };
          this.summaryLoading = false;
        },
        error: () => {
          this.summary = { node_count: 0, edge_count: 0, status: 'unavailable' };
          this.summaryLoading = false;
        }
      });
  }

  runQuery(): void {
    if (!this.cypherQuery.trim()) return;
    this.loading = true;
    this.error = '';
    this.mcpService.kuzuQuery(this.cypherQuery)
      .pipe(takeUntilDestroyed(this.destroyRef))
      .subscribe({
        next: r => { this.queryResult = r; this.loading = false; },
        error: () => { this.error = 'Graph query failed. Check your Cypher syntax.'; this.loading = false; }
      });
  }
}
