/**
 * RAG Studio Component - Angular/UI5 Version
 */
import { Component, DestroyRef, OnInit, inject } from '@angular/core';
import { CommonModule } from '@angular/common';
import { FormsModule } from '@angular/forms';
import { Ui5WebcomponentsModule } from '@ui5/webcomponents-ngx';
import { takeUntilDestroyed } from '@angular/core/rxjs-interop';
import { McpService, VectorStore, RAGResult } from '../../services/mcp.service';

@Component({
  selector: 'app-rag-studio',
  standalone: true,
  imports: [CommonModule, FormsModule, Ui5WebcomponentsModule],
  template: `
    <ui5-page background-design="Solid">
      <ui5-bar slot="header" design="Header">
        <ui5-title slot="startContent" level="H3">RAG Studio</ui5-title>
        <ui5-button slot="endContent" design="Emphasized" icon="add" (click)="showCreateDialog = true">
          New Knowledge Base
        </ui5-button>
      </ui5-bar>

      <div class="rag-container">
        <ui5-message-strip *ngIf="error" design="Negative" [hideCloseButton]="true">
          {{ error }}
        </ui5-message-strip>

        <div class="left-panel">
          <ui5-card>
            <ui5-card-header slot="header" title-text="Knowledge Bases"></ui5-card-header>
            <ui5-list mode="SingleSelect" (item-click)="selectStore($event)">
              <ui5-li *ngFor="let store of vectorStores; let i = index" [attr.data-index]="i" [description]="store.documents_added + ' documents'">
                {{ store.table_name }}
              </ui5-li>
            </ui5-list>
            <div *ngIf="!storesLoading && vectorStores.length === 0" class="empty-state">
              No knowledge bases found.
            </div>
          </ui5-card>
        </div>

        <div class="right-panel">
          <ui5-card *ngIf="selectedStore">
            <ui5-card-header slot="header" [titleText]="'Query: ' + selectedStore.table_name"></ui5-card-header>
            <div class="query-area">
              <ui5-textarea [(ngModel)]="queryText" placeholder="Enter your question..." [rows]="3"></ui5-textarea>
              <ui5-button design="Emphasized" (click)="runQuery()" [disabled]="queryLoading">
                {{ queryLoading ? 'Searching...' : 'Search' }}
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
    .rag-container { display: flex; flex-direction: column; gap: 1rem; padding: 1rem; height: 100%; }
    @media (min-width: 768px) { .rag-container { flex-direction: row; } }
    .left-panel { width: 100%; }
    @media (min-width: 768px) { .left-panel { width: 300px; } }
    .right-panel { flex: 1; }
    .query-area { padding: 1rem; display: flex; flex-direction: column; gap: 0.5rem; }
    .result-area { padding: 1rem; border-top: 1px solid var(--sapList_BorderColor); }
    .empty-state { padding: 1rem; color: var(--sapContent_LabelColor); }
    ui5-message-strip { margin-bottom: 1rem; }
  `]
})
export class RagStudioComponent implements OnInit {
  private readonly mcpService = inject(McpService);
  private readonly destroyRef = inject(DestroyRef);

  vectorStores: VectorStore[] = [];
  selectedStore: VectorStore | null = null;
  queryText = '';
  ragResult: RAGResult | null = null;
  storesLoading = false;
  queryLoading = false;
  showCreateDialog = false;
  error = '';

  ngOnInit(): void {
    this.storesLoading = true;
    this.mcpService.fetchVectorStores()
      .pipe(takeUntilDestroyed(this.destroyRef))
      .subscribe({
        next: stores => { this.vectorStores = stores; this.storesLoading = false; },
        error: () => { this.error = 'Failed to load knowledge bases.'; this.storesLoading = false; }
      });
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
    this.queryLoading = true;
    this.error = '';
    this.mcpService.ragQuery(this.queryText, this.selectedStore.table_name)
      .pipe(takeUntilDestroyed(this.destroyRef))
      .subscribe({
        next: (result) => { this.ragResult = result; this.queryLoading = false; },
        error: () => { this.error = 'RAG query failed.'; this.queryLoading = false; }
      });
  }
}
