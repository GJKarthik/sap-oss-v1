import { Component, DestroyRef, OnInit, inject } from '@angular/core';
import { CommonModule } from '@angular/common';
import { FormsModule } from '@angular/forms';
import { Ui5WebcomponentsModule } from '@ui5/webcomponents-ngx';
import { takeUntilDestroyed } from '@angular/core/rxjs-interop';
import { AuthService } from '../../services/auth.service';
import { McpService, VectorStore, RAGResult } from '../../services/mcp.service';

function readErrorMessage(error: unknown, fallback: string): string {
  const detail = (error as { error?: { detail?: string } | string; message?: string })?.error;
  if (typeof detail === 'string' && detail.trim()) {
    return detail;
  }
  if (detail && typeof detail === 'object' && 'detail' in detail && typeof detail.detail === 'string') {
    return detail.detail;
  }
  const message = (error as { message?: string })?.message;
  return message?.trim() ? message : fallback;
}

@Component({
  selector: 'app-rag-studio',
  standalone: true,
  imports: [CommonModule, FormsModule, Ui5WebcomponentsModule],
  template: `
    <ui5-page background-design="Solid">
      <ui5-bar slot="header" design="Header">
        <ui5-title slot="startContent" level="H3">RAG Studio</ui5-title>
        <ui5-button *ngIf="canManage" slot="endContent" design="Emphasized" icon="add" (click)="toggleCreateForm()">
          {{ showCreateForm ? 'Close Form' : 'New Knowledge Base' }}
        </ui5-button>
      </ui5-bar>

      <div class="rag-container">
        <ui5-message-strip *ngIf="error" design="Negative" [hideCloseButton]="true">
          {{ error }}
        </ui5-message-strip>
        <ui5-message-strip *ngIf="success" design="Positive" [hideCloseButton]="true">
          {{ success }}
        </ui5-message-strip>
        <ui5-message-strip *ngIf="!canManage" design="Information" [hideCloseButton]="true">
          Viewer mode: knowledge base management is disabled.
        </ui5-message-strip>

        <ui5-card *ngIf="showCreateForm && canManage" class="full-width-card">
          <ui5-card-header slot="header" title-text="Create Knowledge Base" subtitle-text="Register a vector store in HANA"></ui5-card-header>
          <div class="form-grid">
            <label class="field-label">
              Table Name
              <ui5-input ngDefaultControl [(ngModel)]="draftStore.table_name" placeholder="KB_CUSTOMER_SUPPORT"></ui5-input>
            </label>
            <label class="field-label">
              Embedding Model
              <ui5-input ngDefaultControl [(ngModel)]="draftStore.embedding_model" placeholder="default"></ui5-input>
            </label>
            <div class="form-actions">
              <ui5-button design="Emphasized" (click)="createStore()" [disabled]="mutating">Create</ui5-button>
              <ui5-button design="Transparent" (click)="resetCreateForm()" [disabled]="mutating">Cancel</ui5-button>
            </div>
          </div>
        </ui5-card>

        <div class="columns">
          <div class="left-panel">
            <ui5-card>
              <ui5-card-header slot="header" title-text="Knowledge Bases" [additionalText]="vectorStores.length + ''"></ui5-card-header>
              <ui5-list mode="SingleSelect" (item-click)="selectStore($event)">
                <ui5-li
                  *ngFor="let store of vectorStores; let i = index"
                  [attr.data-index]="i"
                  [description]="store.documents_added + ' documents · ' + store.embedding_model">
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
              <ui5-card-header
                slot="header"
                [titleText]="'Knowledge Base: ' + selectedStore.table_name"
                [subtitleText]="selectedStore.documents_added + ' indexed documents'">
              </ui5-card-header>

              <div class="store-actions" *ngIf="canManage">
                <ui5-button design="Transparent" icon="upload" (click)="toggleDocumentForm()">
                  {{ showDocumentForm ? 'Close Document Form' : 'Add Documents' }}
                </ui5-button>
              </div>

              <div *ngIf="showDocumentForm && canManage" class="form-grid bordered-section">
                <label class="field-label">
                  Documents
                  <ui5-textarea
                    ngDefaultControl
                    [(ngModel)]="documentDraft"
                    [rows]="6"
                    growing
                    placeholder="Enter one document per line.">
                  </ui5-textarea>
                </label>
                <div class="form-actions">
                  <ui5-button design="Emphasized" (click)="addDocumentsToStore()" [disabled]="mutating">Index Documents</ui5-button>
                </div>
              </div>

              <div class="query-area">
                <ui5-textarea ngDefaultControl [(ngModel)]="queryText" placeholder="Enter your question..." [rows]="3"></ui5-textarea>
                <ui5-button design="Emphasized" (click)="runQuery()" [disabled]="queryLoading">
                  {{ queryLoading ? 'Searching...' : 'Search' }}
                </ui5-button>
              </div>

              <div *ngIf="ragResult" class="result-area">
                <h4>Answer</h4>
                <p>{{ ragResult.answer }}</p>
                <h4>Context Documents</h4>
                <ui5-list *ngIf="ragResult.context_docs.length > 0; else emptyContext">
                  <ui5-li *ngFor="let doc of ragResult.context_docs">{{ formatContextDoc(doc) }}</ui5-li>
                </ui5-list>
                <ng-template #emptyContext>
                  <div class="empty-state">No context documents were returned for this query.</div>
                </ng-template>
              </div>
            </ui5-card>

            <ui5-card *ngIf="!selectedStore" class="full-width-card">
              <ui5-card-header slot="header" title-text="Select a Knowledge Base"></ui5-card-header>
              <div class="empty-state">
                Choose a knowledge base from the left to search or add documents.
              </div>
            </ui5-card>
          </div>
        </div>
      </div>
    </ui5-page>
  `,
  styles: [`
    .rag-container {
      padding: 1rem;
      display: flex;
      flex-direction: column;
      gap: 1rem;
    }

    .columns {
      display: flex;
      flex-direction: column;
      gap: 1rem;
    }

    @media (min-width: 960px) {
      .columns {
        flex-direction: row;
        align-items: flex-start;
      }

      .left-panel {
        width: 320px;
        flex-shrink: 0;
      }

      .right-panel {
        flex: 1;
      }
    }

    .form-grid {
      padding: 1rem;
      display: grid;
      gap: 1rem;
    }

    .field-label {
      display: grid;
      gap: 0.5rem;
      color: var(--sapContent_LabelColor);
    }

    .form-actions,
    .store-actions {
      display: flex;
      gap: 0.5rem;
      flex-wrap: wrap;
      padding: 1rem 1rem 0;
    }

    .query-area {
      padding: 1rem;
      display: grid;
      gap: 0.75rem;
    }

    .bordered-section {
      border-top: 1px solid var(--sapList_BorderColor);
      border-bottom: 1px solid var(--sapList_BorderColor);
    }

    .result-area {
      padding: 1rem;
      border-top: 1px solid var(--sapList_BorderColor);
      display: grid;
      gap: 0.75rem;
    }

    .empty-state {
      padding: 1rem;
      color: var(--sapContent_LabelColor);
    }

    .full-width-card {
      width: 100%;
    }
  `]
})
export class RagStudioComponent implements OnInit {
  private readonly mcpService = inject(McpService);
  private readonly destroyRef = inject(DestroyRef);
  private readonly authService = inject(AuthService);

  vectorStores: VectorStore[] = [];
  selectedStore: VectorStore | null = null;
  queryText = '';
  ragResult: RAGResult | null = null;
  storesLoading = false;
  queryLoading = false;
  mutating = false;
  showCreateForm = false;
  showDocumentForm = false;
  documentDraft = '';
  error = '';
  success = '';
  draftStore = {
    table_name: '',
    embedding_model: 'default',
  };
  readonly canManage = this.authService.getUser()?.role === 'admin';

  ngOnInit(): void {
    this.refreshStores();
  }

  refreshStores(): void {
    this.storesLoading = true;
    this.error = '';
    this.success = '';
    this.mcpService.fetchVectorStores()
      .pipe(takeUntilDestroyed(this.destroyRef))
      .subscribe({
        next: stores => {
          this.vectorStores = stores;
          if (this.selectedStore) {
            this.selectedStore = stores.find(store => store.table_name === this.selectedStore?.table_name) ?? null;
          }
          this.storesLoading = false;
        },
        error: err => {
          this.error = readErrorMessage(err, 'Failed to load knowledge bases.');
          this.storesLoading = false;
        }
      });
  }

  toggleCreateForm(): void {
    this.showCreateForm = !this.showCreateForm;
    if (!this.showCreateForm) {
      this.resetCreateForm();
    }
  }

  resetCreateForm(): void {
    this.showCreateForm = false;
    this.draftStore = {
      table_name: '',
      embedding_model: 'default',
    };
  }

  createStore(): void {
    const tableName = this.draftStore.table_name.trim();
    const embeddingModel = this.draftStore.embedding_model.trim() || 'default';
    if (!tableName) {
      this.error = 'Table name is required.';
      return;
    }

    this.mutating = true;
    this.error = '';
    this.success = '';
    this.mcpService.createVectorStore(tableName, embeddingModel)
      .pipe(takeUntilDestroyed(this.destroyRef))
      .subscribe({
        next: store => {
          this.vectorStores = [...this.vectorStores, store].sort((left, right) => left.table_name.localeCompare(right.table_name));
          this.selectedStore = store;
          this.success = `Knowledge base "${store.table_name}" created.`;
          this.mutating = false;
          this.resetCreateForm();
        },
        error: err => {
          this.error = readErrorMessage(err, 'Failed to create knowledge base.');
          this.mutating = false;
        }
      });
  }

  toggleDocumentForm(): void {
    this.showDocumentForm = !this.showDocumentForm;
    if (!this.showDocumentForm) {
      this.documentDraft = '';
    }
  }

  addDocumentsToStore(): void {
    if (!this.selectedStore) {
      this.error = 'Select a knowledge base first.';
      return;
    }

    const documents = this.documentDraft
      .split('\n')
      .map(document => document.trim())
      .filter(Boolean);
    if (documents.length === 0) {
      this.error = 'Enter at least one document.';
      return;
    }

    this.mutating = true;
    this.error = '';
    this.success = '';
    this.mcpService.addDocuments(this.selectedStore.table_name, documents)
      .pipe(takeUntilDestroyed(this.destroyRef))
      .subscribe({
        next: response => {
          if (this.selectedStore) {
            this.selectedStore.documents_added += response.documents_added;
            this.vectorStores = this.vectorStores.map(store =>
              store.table_name === this.selectedStore?.table_name ? this.selectedStore! : store
            );
          }
          this.success = `${response.documents_added} document(s) indexed into "${this.selectedStore?.table_name}".`;
          this.documentDraft = '';
          this.showDocumentForm = false;
          this.mutating = false;
        },
        error: err => {
          this.error = readErrorMessage(err, 'Failed to add documents.');
          this.mutating = false;
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
      this.queryText = '';
      this.showDocumentForm = false;
      this.documentDraft = '';
    }
  }

  runQuery(): void {
    if (!this.selectedStore || !this.queryText.trim()) {
      return;
    }

    this.queryLoading = true;
    this.error = '';
    this.success = '';
    this.mcpService.ragQuery(this.queryText.trim(), this.selectedStore.table_name)
      .pipe(takeUntilDestroyed(this.destroyRef))
      .subscribe({
        next: result => {
          this.ragResult = result;
          this.queryLoading = false;
        },
        error: err => {
          this.error = readErrorMessage(err, 'RAG query failed.');
          this.queryLoading = false;
        }
      });
  }

  formatContextDoc(doc: unknown): string {
    if (typeof doc === 'string') {
      return doc;
    }

    if (doc && typeof doc === 'object') {
      return JSON.stringify(doc);
    }

    return String(doc);
  }
}
