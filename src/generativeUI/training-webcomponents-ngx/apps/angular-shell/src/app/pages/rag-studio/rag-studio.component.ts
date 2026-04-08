import { Component, DestroyRef, OnInit, inject } from '@angular/core';
import { CommonModule } from '@angular/common';
import { FormsModule } from '@angular/forms';
import { Ui5TrainingComponentsModule } from '../../shared/ui5-training-components.module';
import { takeUntilDestroyed } from '@angular/core/rxjs-interop';
import { McpService, VectorStore, RAGResult } from '../../services/mcp.service';
import { EmptyStateComponent, CrossAppLinkComponent } from '../../shared';
import { I18nService } from '../../services/i18n.service';
import { TranslatePipe } from '../../shared/pipes/translate.pipe';

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
  imports: [CommonModule, FormsModule, Ui5TrainingComponentsModule, EmptyStateComponent, CrossAppLinkComponent, TranslatePipe],
  template: `
    <ui5-page background-design="Solid">
      <app-cross-app-link
        targetApp="training"
        targetRoute="/semantic-search"
        targetLabelKey="nav.semanticSearch"
        icon="search">
      </app-cross-app-link>

      <ui5-bar slot="header" design="Header">
        <ui5-title slot="startContent" level="H3">{{ 'ragStudio.searchStudio' | translate }}</ui5-title>
        <ui5-button
          slot="endContent"
          icon="refresh"
          (click)="refreshStores()"
          [disabled]="storesLoading"
          [attr.aria-label]="i18n.t('ragStudio.refreshKnowledgeBases')"
          class="hide-mobile">
          {{ storesLoading ? ('common.loading' | translate) : ('common.refresh' | translate) }}
        </ui5-button>
        <ui5-button
          *ngIf="canManage"
          slot="endContent"
          design="Emphasized"
          icon="add"
          (click)="toggleCreateForm()"
          [attr.aria-label]="i18n.t('ragStudio.createNew')">
          {{ showCreateForm ? ('ragStudio.closeForm' | translate) : ('ragStudio.newKnowledgeBase' | translate) }}
        </ui5-button>
      </ui5-bar>

      <div class="rag-container" role="region" [attr.aria-label]="i18n.t('ragStudio.searchStudioWorkspace')">
        <!-- Loading indicator -->
        <div class="loading-container" *ngIf="storesLoading && vectorStores.length === 0" role="status" aria-live="polite">
          <ui5-busy-indicator active size="M"></ui5-busy-indicator>
          <span class="loading-text">{{ 'ragStudio.loadingKnowledgeBases' | translate }}</span>
        </div>

        <ui5-message-strip
          *ngIf="error"
          design="Negative"
          [hideCloseButton]="false"
          (close)="error = ''"
          role="alert">
          {{ error }}
        </ui5-message-strip>
        <ui5-message-strip
          *ngIf="success"
          design="Positive"
          [hideCloseButton]="false"
          (close)="success = ''"
          role="status">
          {{ success }}
        </ui5-message-strip>
        <ui5-message-strip *ngIf="!canManage" design="Information" [hideCloseButton]="true" role="note">
          {{ 'ragStudio.viewerMode' | translate }}
        </ui5-message-strip>

        <ui5-card *ngIf="showCreateForm && canManage" class="create-form-card">
          <ui5-card-header slot="header" [titleText]="'ragStudio.createKnowledgeBase' | translate" [subtitleText]="'ragStudio.registerKnowledgeBase' | translate"></ui5-card-header>
          <form class="form-grid" (ngSubmit)="createStore()">
            <div class="field-group">
              <label for="table-name-input" class="field-label">
                {{ 'ragStudio.tableName' | translate }} <span class="required">*</span>
              </label>
              <ui5-input
                id="table-name-input"
                ngDefaultControl
                [(ngModel)]="draftStore.table_name"
                name="tableName"
                placeholder="KB_CUSTOMER_SUPPORT"
                accessible-name="Knowledge base table name"
                required>
              </ui5-input>
            </div>
            <div class="field-group">
              <label for="embedding-model-input" class="field-label">{{ 'ragStudio.embeddingModel' | translate }}</label>
              <ui5-input
                id="embedding-model-input"
                ngDefaultControl
                [(ngModel)]="draftStore.embedding_model"
                name="embeddingModel"
                placeholder="default"
                accessible-name="Embedding model name">
              </ui5-input>
            </div>
            <div class="form-actions">
              <ui5-button
                design="Emphasized"
                type="Submit"
                (click)="createStore()"
                [disabled]="mutating || !draftStore.table_name.trim()">
                {{ mutating ? ('ragStudio.creating' | translate) : ('common.create' | translate) }}
              </ui5-button>
              <ui5-button design="Transparent" (click)="resetCreateForm()" [disabled]="mutating">{{ 'common.cancel' | translate }}</ui5-button>
            </div>
          </form>
        </ui5-card>

        <div class="columns">
          <div class="left-panel">
            <ui5-card [class.card-loading]="storesLoading">
              <ui5-card-header
                slot="header"
                [titleText]="'ragStudio.knowledgeBases' | translate"
                [subtitleText]="'ragStudio.searchIndices' | translate"
                [additionalText]="vectorStores.length + ''">
              </ui5-card-header>
              <ui5-list
                mode="SingleSelect"
                (item-click)="selectStore($event)"
                [attr.aria-label]="'ragStudio.selectKnowledgeBase' | translate">
                <ui5-li
                  *ngFor="let store of vectorStores; let i = index; trackBy: trackByTableName"
                  [attr.data-index]="i"
                  [description]="store.documents_added + ' documents · ' + store.embedding_model"
                  [attr.aria-selected]="selectedStore?.table_name === store.table_name">
                  {{ store.table_name }}
                </ui5-li>
              </ui5-list>

              <app-empty-state
                *ngIf="!storesLoading && vectorStores.length === 0"
                icon="database"
                [title]="'ragStudio.noKnowledgeBases' | translate"
                [description]="'ragStudio.createKnowledgeBaseDesc' | translate"
                [actionText]="canManage ? ('ragStudio.createKnowledgeBase' | translate) : ''"
                (action)="toggleCreateForm()">
              </app-empty-state>
            </ui5-card>
          </div>

          <div class="right-panel">
            <ui5-card *ngIf="selectedStore" role="region" [attr.aria-label]="i18n.t('ragStudio.knowledgeBaseLabel', { name: selectedStore.table_name })">
              <ui5-card-header
                slot="header"
                [titleText]="i18n.t('ragStudio.knowledgeBaseLabel', { name: selectedStore.table_name })"
                [subtitleText]="i18n.t('ragStudio.indexedDocuments', { count: selectedStore.documents_added })">
              </ui5-card-header>

              <div class="store-actions" *ngIf="canManage">
                <ui5-button
                  design="Transparent"
                  icon="upload"
                  (click)="toggleDocumentForm()"
                  aria-label="Add documents to knowledge base">
                  {{ showDocumentForm ? ('ragStudio.closeDocumentForm' | translate) : ('ragStudio.addDocuments' | translate) }}
                </ui5-button>
              </div>

              <div *ngIf="showDocumentForm && canManage" class="form-grid bordered-section">
                <div class="field-group">
                  <label for="documents-input" class="field-label">
                    {{ 'ragStudio.documentsLabel' | translate }} <span class="required">*</span>
                  </label>
                  <ui5-textarea
                    id="documents-input"
                    ngDefaultControl
                    [(ngModel)]="documentDraft"
                    name="documents"
                    [rows]="6"
                    growing
                    placeholder="Enter one document per line."
                    accessible-name="Documents to index">
                  </ui5-textarea>
                  <span class="field-hint">{{ 'ragStudio.enterDocPerLine' | translate }}</span>
                </div>
                <div class="form-actions">
                  <ui5-button
                    design="Emphasized"
                    (click)="addDocumentsToStore()"
                    [disabled]="mutating || !documentDraft.trim()">
                    {{ mutating ? ('ragStudio.indexing' | translate) : ('ragStudio.indexDocuments' | translate) }}
                  </ui5-button>
                </div>
              </div>

              <div class="query-area">
                <div class="field-group">
                  <label for="query-input" class="field-label">{{ 'ragStudio.searchQuery' | translate }}</label>
                  <ui5-textarea
                    id="query-input"
                    ngDefaultControl
                    [(ngModel)]="queryText"
                    name="query"
                    placeholder="Enter a search question..."
                    [rows]="3"
                    accessible-name="RAG query input">
                  </ui5-textarea>
                </div>
                <ui5-button
                  design="Emphasized"
                  icon="search"
                  (click)="runQuery()"
                  [disabled]="queryLoading || !queryText.trim()"
                  aria-label="Search knowledge base">
                  {{ queryLoading ? ('ragStudio.searching' | translate) : ('common.search' | translate) }}
                </ui5-button>
              </div>

              <div *ngIf="ragResult" class="result-area" role="region" [attr.aria-label]="'ragStudio.queryResults' | translate">
                <div class="answer-section">
                  <h4>{{ 'ragStudio.searchSummary' | translate }}</h4>
                  <p class="answer-text" [innerHTML]="highlightQuery(ragResult.answer, queryText)"></p>
                </div>
                <div class="context-section">
                  <h4>{{ 'ragStudio.retrievedDocuments' | translate }} ({{ ragResult.context_docs.length }})</h4>
                  <div *ngIf="ragResult.context_docs.length > 0; else emptyContext" class="context-doc-list">
                    <div *ngFor="let doc of ragResult.context_docs; let i = index; trackBy: trackByIndex" class="context-doc-card">
                      <div class="context-doc-header">
                        <span class="context-doc-rank">#{{ i + 1 }}</span>
                        <span class="context-doc-score" [class.high]="getDocScore(doc) >= 0.8" [class.medium]="getDocScore(doc) >= 0.5 && getDocScore(doc) < 0.8">
                          {{ (getDocScore(doc) * 100).toFixed(0) }}% relevance
                        </span>
                      </div>
                      <div class="context-doc-text" [innerHTML]="highlightQuery(formatContextDoc(doc), queryText)"></div>
                    </div>
                  </div>
                  <ng-template #emptyContext>
                    <p class="no-context">{{ 'ragStudio.noContextDocs' | translate }}</p>
                  </ng-template>
                </div>
              </div>
            </ui5-card>

            <ui5-card *ngIf="!selectedStore" class="full-width-card">
              <app-empty-state
                icon="hint"
                [title]="'ragStudio.selectKnowledgeBase' | translate"
                [description]="'ragStudio.selectKnowledgeBaseDesc' | translate">
              </app-empty-state>
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
      max-width: 1400px;
      margin: 0 auto;
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

    .card-loading {
      opacity: 0.6;
      pointer-events: none;
    }

    .create-form-card {
      max-width: 500px;
    }

    .form-grid {
      padding: 1rem;
      display: grid;
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

    .required {
      color: var(--sapNegativeColor, #b00);
    }

    .field-hint {
      font-size: var(--sapFontSmallSize);
      color: var(--sapContent_LabelColor);
    }

    .form-actions {
      display: flex;
      gap: 0.5rem;
      flex-wrap: wrap;
    }

    .store-actions {
      display: flex;
      gap: 0.5rem;
      flex-wrap: wrap;
      padding: 1rem 1rem 0;
    }

    .query-area {
      padding: 1rem;
      display: grid;
      gap: 1rem;
    }

    .bordered-section {
      border-top: 1px solid var(--sapList_BorderColor);
      border-bottom: 1px solid var(--sapList_BorderColor);
    }

    .result-area {
      padding: 1rem;
      border-top: 1px solid var(--sapList_BorderColor);
      display: grid;
      gap: 1rem;
    }

    .answer-section h4,
    .context-section h4 {
      margin: 0 0 0.5rem 0;
      font-size: var(--sapFontSize);
      font-weight: 600;
      color: var(--sapTextColor);
    }

    .answer-text {
      margin: 0;
      line-height: 1.6;
      background: var(--sapList_Background);
      padding: 1rem;
      border-radius: 0.5rem;
      border: 1px solid var(--sapList_BorderColor);
    }

    .no-context {
      margin: 0;
      color: var(--sapContent_LabelColor);
      font-style: italic;
    }

    .context-doc-list {
      display: grid;
      gap: 0.75rem;
    }

    .context-doc-card {
      border: 1px solid var(--sapList_BorderColor);
      border-radius: 0.5rem;
      overflow: hidden;
    }

    .context-doc-header {
      display: flex;
      justify-content: space-between;
      align-items: center;
      padding: 0.5rem 0.75rem;
      background: var(--sapList_HeaderBackground, #f5f5f5);
      border-bottom: 1px solid var(--sapList_BorderColor);
      font-size: var(--sapFontSmallSize);
    }

    .context-doc-rank {
      font-weight: 700;
      color: var(--sapContent_LabelColor);
    }

    .context-doc-score {
      padding: 0.15rem 0.5rem;
      border-radius: 999px;
      font-weight: 600;
      font-size: 0.7rem;
      background: var(--sapNegativeBackground, #ffebee);
      color: var(--sapNegativeColor, #b00);
    }

    .context-doc-score.high {
      background: var(--sapSuccessBackground, #e6f4ea);
      color: var(--sapPositiveColor, #107e3e);
    }

    .context-doc-score.medium {
      background: var(--sapWarningBackground, #fef7e0);
      color: var(--sapCriticalColor, #e76500);
    }

    .context-doc-text {
      padding: 0.75rem;
      font-size: var(--sapFontSize);
      line-height: 1.6;
      white-space: pre-wrap;
      word-break: break-word;
    }

    :host ::ng-deep mark {
      background: rgba(255, 213, 0, 0.35);
      border-radius: 2px;
      padding: 0 1px;
    }

    .full-width-card {
      width: 100%;
    }

    @media (max-width: 768px) {
      .rag-container {
        padding: 0.75rem;
      }

      .hide-mobile {
        display: none;
      }
    }
  `]
})
export class RagStudioComponent implements OnInit {
  private readonly mcpService = inject(McpService);
  private readonly destroyRef = inject(DestroyRef);
  
  readonly i18n = inject(I18nService);

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
  readonly canManage = true; // Governed by TeamGovernanceService

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
          this.error = readErrorMessage(err, this.i18n.t('ragStudio.loadFailed'));
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
      this.error = this.i18n.t('ragStudio.tableNameRequired');
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
          this.success = this.i18n.t('ragStudio.knowledgeBaseCreated', { name: store.table_name });
          this.mutating = false;
          this.resetCreateForm();
        },
        error: err => {
          this.error = readErrorMessage(err, this.i18n.t('ragStudio.createFailed'));
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
      this.error = this.i18n.t('ragStudio.selectKnowledgeBaseFirst');
      return;
    }

    const documents = this.documentDraft
      .split('\n')
      .map(document => document.trim())
      .filter(Boolean);
    if (documents.length === 0) {
      this.error = this.i18n.t('ragStudio.enterAtLeastOneDoc');
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
          this.success = this.i18n.t('ragStudio.documentsIndexed', { count: response.documents_added, name: this.selectedStore?.table_name ?? '' });
          this.documentDraft = '';
          this.showDocumentForm = false;
          this.mutating = false;
        },
        error: err => {
          this.error = readErrorMessage(err, this.i18n.t('ragStudio.addDocsFailed'));
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
          this.error = readErrorMessage(err, this.i18n.t('ragStudio.queryFailed'));
          this.queryLoading = false;
        }
      });
  }

  trackByTableName(index: number, store: VectorStore): string {
    return store.table_name;
  }

  trackByIndex(index: number): number {
    return index;
  }

  formatContextDoc(doc: unknown): string {
    if (typeof doc === 'string') {
      return doc;
    }
    if (doc && typeof doc === 'object') {
      const obj = doc as Record<string, unknown>;
      return obj['text'] ? String(obj['text']) : JSON.stringify(doc);
    }
    return String(doc);
  }

  getDocScore(doc: unknown): number {
    if (doc && typeof doc === 'object') {
      const score = (doc as Record<string, unknown>)['score'];
      if (typeof score === 'number') return score;
    }
    return 0.5; // default mid-range if no score
  }

  highlightQuery(text: string, query: string): string {
    if (!query || !text) return text;
    const words = query.trim().split(/\s+/).filter(w => w.length > 2);
    if (words.length === 0) return text;
    const escaped = words.map(w => w.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'));
    const regex = new RegExp(`(${escaped.join('|')})`, 'gi');
    return text.replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(regex, '<mark>$1</mark>');
  }
}
