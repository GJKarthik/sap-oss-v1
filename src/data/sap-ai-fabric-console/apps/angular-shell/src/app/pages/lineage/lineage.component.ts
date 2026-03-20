import { Component, inject } from '@angular/core';
import { McpService } from '../../services/mcp.service';

@Component({
  selector: 'app-lineage',
  standalone: false,
  template: `
    <ui5-page background-design="Solid">
      <ui5-bar slot="header" design="Header">
        <ui5-title slot="startContent" level="H3">Data Lineage</ui5-title>
      </ui5-bar>
      <div class="lineage-content">
        <ui5-card>
          <ui5-card-header slot="header" title-text="KùzuDB Graph Query"></ui5-card-header>
          <div class="query-area">
            <ui5-textarea [(ngModel)]="cypherQuery" placeholder="MATCH (n) RETURN n LIMIT 10" [rows]="3"></ui5-textarea>
            <ui5-button design="Emphasized" (click)="runQuery()">Run Query</ui5-button>
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
    .query-area { padding: 1rem; display: flex; flex-direction: column; gap: 0.5rem; }
    .result-area { padding: 1rem; border-top: 1px solid var(--sapList_BorderColor); }
    pre { background: var(--sapList_Background); padding: 1rem; overflow: auto; max-height: 400px; }
  `]
})
export class LineageComponent {
  private readonly mcpService = inject(McpService);

  cypherQuery = 'MATCH (n) RETURN n LIMIT 10';
  queryResult: { rows: unknown[]; rowCount: number } | null = null;
  
  runQuery(): void {
    this.mcpService.kuzuQuery(this.cypherQuery).subscribe(r => this.queryResult = r);
  }
}
