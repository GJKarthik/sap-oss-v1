import { Component, DestroyRef, OnInit, inject } from '@angular/core';
import { CommonModule } from '@angular/common';
import { FormsModule } from '@angular/forms';
import { Ui5WebcomponentsModule } from '@ui5/webcomponents-ngx';
import { takeUntilDestroyed } from '@angular/core/rxjs-interop';
import { McpService } from '../../services/mcp.service';

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

        <ui5-card *ngIf="summary" class="summary-card">
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
              <ui5-tag [design]="summary.status === 'kuzu_unavailable' || summary.status === 'unavailable' ? 'Critical' : 'Positive'">
                {{ summary.status }}
              </ui5-tag>
            </div>
          </div>
        </ui5-card>

        <ui5-card>
          <ui5-card-header slot="header" title-text="KùzuDB Graph Query"></ui5-card-header>
          <div class="query-area">
            <ui5-textarea ngDefaultControl [(ngModel)]="cypherQuery" placeholder="MATCH (n) RETURN n LIMIT 10" [rows]="3"></ui5-textarea>
            <ui5-button design="Emphasized" (click)="runQuery()" [disabled]="loading">
              {{ loading ? 'Running...' : 'Run Query' }}
            </ui5-button>
          </div>
          <div *ngIf="queryResult" class="result-area">
            <h4>Results ({{ queryResult.rowCount }} rows):</h4>
            <pre>{{ queryResult.rows | json }}</pre>
          </div>
        </ui5-card>
      </div>
    </ui5-page>
  `,
  styles: [`
    .lineage-content { padding: 1rem; }
    .summary-card { margin-bottom: 1rem; }
    .summary-grid { padding: 1rem; display: flex; gap: 1rem; flex-wrap: wrap; }
    .summary-item { display: flex; gap: 0.5rem; align-items: center; }
    .query-area { padding: 1rem; display: flex; flex-direction: column; gap: 0.5rem; }
    .result-area { padding: 1rem; border-top: 1px solid var(--sapList_BorderColor); }
    pre { background: var(--sapList_Background); padding: 1rem; overflow: auto; max-height: 400px; border-radius: 0.25rem; }
    ui5-message-strip { margin-bottom: 1rem; }
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
  } | null = null;
  loading = false;
  error = '';

  ngOnInit(): void {
    this.mcpService.graphSummary()
      .pipe(takeUntilDestroyed(this.destroyRef))
      .subscribe({
        next: summary => {
          this.summary = summary;
        },
        error: () => {
          this.summary = { node_count: 0, edge_count: 0, status: 'unavailable' };
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
