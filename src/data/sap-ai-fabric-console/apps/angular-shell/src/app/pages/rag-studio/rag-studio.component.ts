/**
 * RAG Studio Component - Angular/UI5 Version
 */
import { Component, OnInit, inject } from '@angular/core';
import { McpService, VectorStore, RAGResult } from '../../services/mcp.service';

@Component({
  selector: 'app-rag-studio',
  standalone: false,
  template: `
    <ui5-page background-design="Solid">
      <ui5-bar slot="header" design="Header">
        <ui5-title slot="startContent" level="H3">RAG Studio</ui5-title>
        <ui5-button slot="endContent" design="Emphasized" icon="add" (click)="showCreateDialog = true">
          New Knowledge Base
        </ui5-button>
      </ui5-bar>

      <div class="rag-container">
        <div class="left-panel">
          <ui5-card>
            <ui5-card-header slot="header" title-text="Knowledge Bases"></ui5-card-header>
            <ui5-list mode="SingleSelect" (item-click)="selectStore($event)">
              <ui5-li *ngFor="let store of vectorStores; let i = index" [attr.data-index]="i" [description]="store.documents_added + ' documents'">
                {{ store.table_name }}
              </ui5-li>
            </ui5-list>
          </ui5-card>
        </div>

        <div class="right-panel">
          <ui5-card *ngIf="selectedStore">
            <ui5-card-header slot="header" [titleText]="'Query: ' + selectedStore.table_name"></ui5-card-header>
            <div class="query-area">
              <ui5-textarea [(ngModel)]="queryText" placeholder="Enter your question..." [rows]="3"></ui5-textarea>
              <ui5-button design="Emphasized" (click)="runQuery()" [disabled]="loading">
                {{ loading ? 'Searching...' : 'Search' }}
              </ui5-button>
            </div>
            <div *ngIf="ragResult" class="result-area">
              <h4>Answer:</h4>
              <p>{{ ragResult.answer }}</p>
              <h4>Context Documents:</h4>
              <ui5-list>
                <ui5-li *ngFor="let doc of ragResult.context_docs">{{ doc }}</ui5-li>
              </ui5-list>
            </div>
          </ui5-card>
        </div>
      </div>
    </ui5-page>
  `,
  styles: [`
    .rag-container { display: flex; gap: 1rem; padding: 1rem; height: 100%; }
    .left-panel { width: 300px; }
    .right-panel { flex: 1; }
    .query-area { padding: 1rem; display: flex; flex-direction: column; gap: 0.5rem; }
    .result-area { padding: 1rem; border-top: 1px solid var(--sapList_BorderColor); }
  `]
})
export class RagStudioComponent implements OnInit {
  private readonly mcpService = inject(McpService);

  vectorStores: VectorStore[] = [];
  selectedStore: VectorStore | null = null;
  queryText = '';
  ragResult: RAGResult | null = null;
  loading = false;
  showCreateDialog = false;

  ngOnInit(): void {
    this.mcpService.fetchVectorStores().subscribe(stores => this.vectorStores = stores);
  }

  selectStore(event: Event): void {
    const listEvent = event as CustomEvent<{ item?: HTMLElement }>;
    const indexValue = listEvent.detail.item?.dataset['index'];
    if (indexValue === undefined) {
      return;
    }

    const index = Number(indexValue);
    if (!Number.isNaN(index)) {
      this.selectedStore = this.vectorStores[index] ?? null;
    }
  }

  runQuery(): void {
    if (!this.selectedStore || !this.queryText.trim()) return;
    this.loading = true;
    this.mcpService.ragQuery(this.queryText, this.selectedStore.table_name).subscribe({
      next: (result) => { this.ragResult = result; this.loading = false; },
      error: () => { this.loading = false; }
    });
  }
}
