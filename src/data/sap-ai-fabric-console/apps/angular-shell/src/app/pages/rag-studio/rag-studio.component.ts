/**
 * RAG Studio Component - Angular/UI5 Version
 */
import { Component, DestroyRef, OnInit, inject } from '@angular/core';
import { CommonModule } from '@angular/common';
import { FormsModule } from '@angular/forms';
import { Ui5WebcomponentsModule } from '@ui5/webcomponents-ngx';
import { takeUntilDestroyed } from '@angular/core/rxjs-interop';

import {
  DocumentAddResponse,
  RAGQueryResponse,
  RagService,
  SimilaritySearchResponse,
  VectorStore,
} from '../../services/api/rag.service';

interface VectorStoreForm {
  table_name: string;
  embedding_model: string;
}

@Component({
  selector: 'app-rag-studio',
  standalone: true,
  imports: [CommonModule, FormsModule, Ui5WebcomponentsModule],
  template: `
    <ui5-page background-design="Solid">
      <ui5-bar slot="header" design="Header">
        <ui5-title slot="startContent" level="H3">RAG Studio</ui5-title>
        <ui5-button slot="endContent" design="Emphasized" icon="add" (click)="showCreateDialog = !showCreateDialog">
          {{ showCreateDialog ? 'Hide Create Form' : 'New Knowledge Base' }}
        </ui5-button>
      </ui5-bar>

      <div class="rag-container">
        <ui5-message-strip *ngIf="error" design="Negative" [hideCloseButton]="true">
          {{ error }}
        </ui5-message-strip>

        <div class="left-panel">
          <ui5-card>
            <ui5-card-header slot="header" title-text="Knowledge Bases" [additionalText]="vectorStores.length + ''"></ui5-card-header>
            <ui5-list mode="SingleSelect" (item-click)="selectStore($event)">
              <ui5-li
                *ngFor="let store of vectorStores; let i = index"
                [attr.data-index]="i"
                [description]="store.embedding_model + ' • ' + store.documents_added + ' documents'">
                {{ store.table_name }}
              </ui5-li>
            </ui5-list>
            <div *ngIf="!storesLoading && vectorStores.length === 0" class="empty-state">
              No knowledge bases found.
            </div>
          </ui5-card>

          <ui5-card *ngIf="showCreateDialog" class="form-card">
            <ui5-card-header slot="header" title-text="Create Knowledge Base"></ui5-card-header>
            <div class="card-body form-stack">
              <ui5-input [(ngModel)]="newStore.table_name" placeholder="Table name"></ui5-input>
              <ui5-input [(ngModel)]="newStore.embedding_model" placeholder="Embedding model"></ui5-input>
              <div class="actions-row">
                <ui5-button design="Emphasized" (click)="createStore()" [disabled]="createLoading || !newStore.table_name.trim()">
                  {{ createLoading ? 'Creating...' : 'Create' }}
                </ui5-button>
                <ui5-button design="Transparent" (click)="showCreateDialog = false" [disabled]="createLoading">
                  Cancel
                </ui5-button>
              </div>
            </div>
          </ui5-card>
        </div>

        <div class="right-panel">
          <ui5-card *ngIf="selectedStore">
            <ui5-card-header
              slot="header"
              [titleText]="selectedStore.table_name"
              [subtitleText]="'Embedding model: ' + selectedStore.embedding_model"
              [additionalText]="selectedStore.status">
            </ui5-card-header>
            <div class="card-body">
              <div class="meta-row">
                <ui5-tag design="Neutral">{{ selectedStore.documents_added }} documents</ui5-tag>
                <ui5-button design="Transparent" icon="refresh" (click)="loadStores(selectedStore.table_name)" [disabled]="storesLoading">
                  Refresh Store
                </ui5-button>
              </div>

              <div class="section-block">
                <h4>Add Documents</h4>
                <ui5-textarea
                  [(ngModel)]="documentsText"
                  placeholder="Enter one document per line"
                  [rows]="6">
                </ui5-textarea>
                <div class="actions-row">
                  <ui5-button design="Attention" (click)="addDocuments()" [disabled]="documentsLoading || !documentsText.trim()">
                    {{ documentsLoading ? 'Indexing...' : 'Add Documents' }}
                  </ui5-button>
                </div>
                <ui5-message-strip *ngIf="documentResult" design="Positive" [hideCloseButton]="true">
                  Added {{ documentResult.documents_added }} documents ({{ documentResult.status }}).
                </ui5-message-strip>
              </div>
            </div>
          </ui5-card>

          <ui5-card *ngIf="selectedStore">
            <ui5-card-header slot="header" [titleText]="'Query: ' + selectedStore.table_name"></ui5-card-header>
            <div class="query-area">
              <ui5-textarea [(ngModel)]="queryText" placeholder="Enter your question..." [rows]="3"></ui5-textarea>
              <div class="actions-row">
                <ui5-button design="Emphasized" (click)="runQuery()" [disabled]="queryLoading || !queryText.trim()">
                  {{ queryLoading ? 'Searching...' : 'RAG Query' }}
                </ui5-button>
                <ui5-button design="Default" (click)="runSimilaritySearch()" [disabled]="similarityLoading || !queryText.trim()">
                  {{ similarityLoading ? 'Searching...' : 'Similarity Search' }}
                </ui5-button>
              </div>
            </div>
            <div *ngIf="ragResult" class="result-area">
              <h4>Answer:</h4>
              <p>{{ ragResult.answer }}</p>
              <h4>Context Documents:</h4>
              <ui5-list>
                <ui5-li *ngFor="let doc of ragResult.context_docs">{{ doc }}</ui5-li>
              </ui5-list>
            </div>
            <div *ngIf="similarityResult" class="result-area">
              <h4>Similarity Search Results:</h4>
              <pre>{{ similarityResult.results | json }}</pre>
            </div>
          </ui5-card>

          <div *ngIf="!selectedStore" class="empty-state">
            Select or create a knowledge base to add documents and run queries.
          </div>
        </div>
      </div>
    </ui5-page>
  `,
  styles: [`
    .rag-container { display: flex; flex-direction: column; gap: 1rem; padding: 1rem; height: 100%; }
    @media (min-width: 768px) { .rag-container { flex-direction: row; } }
    .left-panel { width: 100%; }
    @media (min-width: 768px) { .left-panel { width: 300px; } }
    .right-panel { flex: 1; display: flex; flex-direction: column; gap: 1rem; }
    .card-body { padding: 1rem; }
    .form-card { margin-top: 1rem; }
    .form-stack { display: flex; flex-direction: column; gap: 0.75rem; }
    .actions-row { display: flex; flex-wrap: wrap; gap: 0.5rem; }
    .meta-row { display: flex; justify-content: space-between; align-items: center; gap: 0.75rem; margin-bottom: 1rem; }
    .section-block { display: flex; flex-direction: column; gap: 0.75rem; }
    .query-area { padding: 1rem; display: flex; flex-direction: column; gap: 0.5rem; }
    .result-area { padding: 1rem; border-top: 1px solid var(--sapList_BorderColor); }
    .empty-state { padding: 1rem; color: var(--sapContent_LabelColor); }
    pre { background: var(--sapList_Background); padding: 1rem; overflow: auto; max-height: 280px; border-radius: 0.25rem; }
    ui5-message-strip { margin-bottom: 1rem; }
  `]
})
export class RagStudioComponent implements OnInit {
  private readonly ragService = inject(RagService);
  private readonly destroyRef = inject(DestroyRef);

  vectorStores: VectorStore[] = [];
  selectedStore: VectorStore | null = null;
  queryText = '';
  documentsText = '';
  ragResult: RAGQueryResponse | null = null;
  similarityResult: SimilaritySearchResponse | null = null;
  documentResult: DocumentAddResponse | null = null;
  storesLoading = false;
  createLoading = false;
  documentsLoading = false;
  queryLoading = false;
  similarityLoading = false;
  showCreateDialog = false;
  error = '';
  newStore: VectorStoreForm = {
    table_name: '',
    embedding_model: 'default',
  };

  ngOnInit(): void {
    this.loadStores();
  }

  loadStores(selectedTableName = this.selectedStore?.table_name): void {
    this.storesLoading = true;
    this.error = '';

    this.ragService.listVectorStores()
      .pipe(takeUntilDestroyed(this.destroyRef))
      .subscribe({
        next: stores => {
          this.vectorStores = stores;
          const matchedStore = selectedTableName
            ? stores.find(store => store.table_name === selectedTableName) ?? null
            : null;
          this.selectedStore = matchedStore ?? stores[0] ?? null;
          this.storesLoading = false;
        },
        error: error => {
          this.error = this.getErrorMessage(error, 'Failed to load knowledge bases.');
          this.storesLoading = false;
        }
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
      this.ragResult = null;
      this.similarityResult = null;
      this.documentResult = null;
    }
  }

  createStore(): void {
    const tableName = this.newStore.table_name.trim();
    if (!tableName) {
      return;
    }

    this.createLoading = true;
    this.error = '';

    this.ragService.createVectorStore({
      table_name: tableName,
      embedding_model: this.newStore.embedding_model.trim() || undefined,
    })
      .pipe(takeUntilDestroyed(this.destroyRef))
      .subscribe({
        next: store => {
          this.newStore = { table_name: '', embedding_model: 'default' };
          this.showCreateDialog = false;
          this.createLoading = false;
          this.loadStores(store.table_name);
        },
        error: error => {
          this.error = this.getErrorMessage(error, 'Failed to create knowledge base.');
          this.createLoading = false;
        }
      });
  }

  addDocuments(): void {
    if (!this.selectedStore) {
      return;
    }

    const documents = this.documentsText
      .split(/\n+/)
      .map(document => document.trim())
      .filter(Boolean);

    if (documents.length === 0) {
      return;
    }

    this.documentsLoading = true;
    this.error = '';

    this.ragService.addDocuments({
      table_name: this.selectedStore.table_name,
      documents,
    })
      .pipe(takeUntilDestroyed(this.destroyRef))
      .subscribe({
        next: result => {
          this.documentResult = result;
          this.documentsText = '';
          this.documentsLoading = false;
          this.loadStores(this.selectedStore?.table_name);
        },
        error: error => {
          this.error = this.getErrorMessage(error, 'Failed to add documents.');
          this.documentsLoading = false;
        }
      });
  }

  runQuery(): void {
    if (!this.selectedStore || !this.queryText.trim()) {
      return;
    }

    this.queryLoading = true;
    this.error = '';

    this.ragService.ragQuery({
      query: this.queryText.trim(),
      table_name: this.selectedStore.table_name,
    })
      .pipe(takeUntilDestroyed(this.destroyRef))
      .subscribe({
        next: result => {
          this.ragResult = result;
          this.queryLoading = false;
        },
        error: error => {
          this.error = this.getErrorMessage(error, 'RAG query failed.');
          this.queryLoading = false;
        }
      });
  }

  runSimilaritySearch(): void {
    if (!this.selectedStore || !this.queryText.trim()) {
      return;
    }

    this.similarityLoading = true;
    this.error = '';

    this.ragService.similaritySearch({
      query: this.queryText.trim(),
      table_name: this.selectedStore.table_name,
    })
      .pipe(takeUntilDestroyed(this.destroyRef))
      .subscribe({
        next: result => {
          this.similarityResult = result;
          this.similarityLoading = false;
        },
        error: error => {
          this.error = this.getErrorMessage(error, 'Similarity search failed.');
          this.similarityLoading = false;
        }
      });
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
