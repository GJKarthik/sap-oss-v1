import { Component, DestroyRef, OnInit, inject } from '@angular/core';
import { CommonModule } from '@angular/common';
import { FormsModule } from '@angular/forms';
import { Ui5TrainingComponentsModule } from '../../shared/ui5-training-components.module';
import { takeUntilDestroyed } from '@angular/core/rxjs-interop';
import {
  PersonalKnowledgeBase,
  PersonalKnowledgeQueryResult,
  PersonalKnowledgeService,
  PersonalWikiPage,
} from '../../services/personal-knowledge.service';
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
        <ui5-title slot="startContent" level="H3">Personal Knowledge</ui5-title>
        <ui5-button
          slot="endContent"
          icon="refresh"
          (click)="refreshStores()"
          [disabled]="storesLoading"
          [attr.aria-label]="'Refresh knowledge bases'"
          class="hide-mobile">
          {{ storesLoading ? ('common.loading' | translate) : ('common.refresh' | translate) }}
        </ui5-button>
        <ui5-button
          *ngIf="canManage"
          slot="endContent"
          design="Emphasized"
          icon="add"
          (click)="toggleCreateForm()"
          [attr.aria-label]="'Create new knowledge base'">
          {{ showCreateForm ? 'Close' : 'New Knowledge Base' }}
        </ui5-button>
      </ui5-bar>

      <div class="rag-container" role="region" aria-label="Personal knowledge workspace">
        <div class="loading-container" *ngIf="storesLoading && vectorStores.length === 0" role="status" aria-live="polite">
          <ui5-busy-indicator active size="M"></ui5-busy-indicator>
          <span class="loading-text">Loading personal knowledge bases…</span>
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
          <ui5-card-header
            slot="header"
            titleText="Create Knowledge Base"
            subtitleText="Create a personal memory space for your documents, notes, and observations.">
          </ui5-card-header>
          <form class="form-grid" (ngSubmit)="createStore()">
            <div class="field-group">
              <label for="table-name-input" class="field-label">
                Knowledge Base Name <span class="required">*</span>
              </label>
              <ui5-input
                id="table-name-input"
                ngDefaultControl
                [(ngModel)]="draftStore.name"
                name="knowledgeBaseName"
                placeholder="Customer launch memory"
                accessible-name="Knowledge base name"
                required>
              </ui5-input>
            </div>
            <div class="field-group">
              <label for="knowledge-description-input" class="field-label">What should it remember?</label>
              <ui5-textarea
                id="knowledge-description-input"
                ngDefaultControl
                [(ngModel)]="draftStore.description"
                name="knowledgeDescription"
                [rows]="3"
                placeholder="Decisions, recurring tasks, launch notes, customer context, and working knowledge."
                accessible-name="Knowledge base description">
              </ui5-textarea>
            </div>
            <div class="field-group">
              <label for="embedding-model-input" class="field-label">Embedding Model</label>
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
                [disabled]="mutating || !draftStore.name.trim()">
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
                titleText="Knowledge Bases"
                subtitleText="Your personal memory spaces"
                [additionalText]="vectorStores.length + ''">
              </ui5-card-header>
              <ui5-list
                mode="SingleSelect"
                (item-click)="selectStore($event)"
                [attr.aria-label]="'ragStudio.selectKnowledgeBase' | translate">
                <ui5-li
                  *ngFor="let store of vectorStores; let i = index; trackBy: trackByTableName"
                  [attr.data-index]="i"
                  [description]="store.documents_added + ' documents · ' + store.wiki_pages + ' wiki pages'"
                  [attr.aria-selected]="selectedStore?.id === store.id">
                  {{ store.name }}
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
            <ui5-card *ngIf="selectedStore" role="region" [attr.aria-label]="'Knowledge base ' + selectedStore.name">
              <ui5-card-header
                slot="header"
                [titleText]="selectedStore.name"
                [subtitleText]="selectedStore.documents_added + ' documents indexed · ' + selectedStore.wiki_pages + ' wiki pages'">
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

              <div class="store-description" *ngIf="selectedStore.description">
                {{ selectedStore.description }}
              </div>

              <div *ngIf="showDocumentForm && canManage" class="form-grid bordered-section">
                <div class="field-group">
                  <label for="documents-input" class="field-label">
                    Add notes or documents <span class="required">*</span>
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
                  <label for="query-input" class="field-label">Ask your knowledge base</label>
                  <ui5-textarea
                    id="query-input"
                    ngDefaultControl
                    [(ngModel)]="queryText"
                    name="query"
                    placeholder="What does this person, project, or topic matter for?"
                    [rows]="3"
                    accessible-name="Knowledge base query input">
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

              <div class="wiki-area">
                <div class="wiki-list-panel">
                  <div class="wiki-panel-header">
                    <h4>Personal Wiki</h4>
                    <span class="wiki-meta">{{ wikiPages.length }} pages</span>
                  </div>
                  <ui5-list
                    mode="SingleSelect"
                    (item-click)="selectWikiPage($event)"
                    aria-label="Wiki pages">
                    <ui5-li
                      *ngFor="let page of wikiPages; let i = index; trackBy: trackByWikiPage"
                      [attr.data-index]="i"
                      [description]="page.generated ? 'Generated summary' : 'Edited page'"
                      [attr.aria-selected]="selectedWikiPage?.slug === page.slug">
                      {{ page.title }}
                    </ui5-li>
                  </ui5-list>
                </div>

                <div class="wiki-editor-panel" *ngIf="selectedWikiPage">
                  <div class="wiki-panel-header">
                    <h4>Edit Wiki Page</h4>
                    <span class="wiki-meta">{{ selectedWikiPage.generated ? 'Generated' : 'Custom' }}</span>
                  </div>
                  <div class="field-group">
                    <label for="wiki-title-input" class="field-label">Page Title</label>
                    <ui5-input
                      id="wiki-title-input"
                      ngDefaultControl
                      [(ngModel)]="wikiDraft.title"
                      name="wikiTitle"
                      accessible-name="Wiki page title">
                    </ui5-input>
                  </div>
                  <div class="field-group">
                    <label for="wiki-content-input" class="field-label">Page Content</label>
                    <ui5-textarea
                      id="wiki-content-input"
                      ngDefaultControl
                      [(ngModel)]="wikiDraft.content"
                      name="wikiContent"
                      [rows]="10"
                      growing
                      accessible-name="Wiki page content">
                    </ui5-textarea>
                  </div>
                  <div class="form-actions">
                    <ui5-button
                      design="Emphasized"
                      (click)="saveActiveWikiPage()"
                      [disabled]="mutating || !wikiDraft.title.trim() || !wikiDraft.content.trim()">
                      Save Wiki Page
                    </ui5-button>
                  </div>
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

    .store-description {
      padding: 0 1rem 1rem;
      color: var(--sapContent_LabelColor);
      line-height: 1.5;
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

    .wiki-area {
      border-top: 1px solid var(--sapList_BorderColor);
      display: grid;
      gap: 1rem;
      padding: 1rem;
    }

    .wiki-list-panel,
    .wiki-editor-panel {
      display: grid;
      gap: 0.75rem;
    }

    .wiki-panel-header {
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 0.75rem;
    }

    .wiki-panel-header h4 {
      margin: 0;
      font-size: var(--sapFontSize);
      font-weight: 600;
      color: var(--sapTextColor);
    }

    .wiki-meta {
      color: var(--sapContent_LabelColor);
      font-size: var(--sapFontSmallSize);
    }

    @media (min-width: 1100px) {
      .wiki-area {
        grid-template-columns: minmax(240px, 300px) minmax(0, 1fr);
        align-items: start;
      }
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
  private readonly knowledgeService = inject(PersonalKnowledgeService);
  private readonly destroyRef = inject(DestroyRef);

  readonly i18n = inject(I18nService);

  vectorStores: PersonalKnowledgeBase[] = [];
  selectedStore: PersonalKnowledgeBase | null = null;
  queryText = '';
  ragResult: PersonalKnowledgeQueryResult | null = null;
  wikiPages: PersonalWikiPage[] = [];
  selectedWikiPage: PersonalWikiPage | null = null;
  storesLoading = false;
  queryLoading = false;
  mutating = false;
  showCreateForm = false;
  showDocumentForm = false;
  documentDraft = '';
  error = '';
  success = '';
  draftStore = {
    name: '',
    description: '',
    embedding_model: 'default',
  };
  wikiDraft = {
    slug: '',
    title: '',
    content: '',
  };
  readonly canManage = true; // Governed by TeamGovernanceService

  ngOnInit(): void {
    this.refreshStores();
  }

  refreshStores(): void {
    this.storesLoading = true;
    this.error = '';
    this.success = '';
    this.knowledgeService.listBases()
      .pipe(takeUntilDestroyed(this.destroyRef))
      .subscribe({
        next: stores => {
          this.vectorStores = stores;
          if (this.selectedStore) {
            this.selectedStore = stores.find((store) => store.id === this.selectedStore?.id) ?? null;
            if (this.selectedStore) {
              this.loadWikiPages(this.selectedStore.id);
            }
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
      name: '',
      description: '',
      embedding_model: 'default',
    };
  }

  createStore(): void {
    const name = this.draftStore.name.trim();
    const description = this.draftStore.description.trim();
    const embeddingModel = this.draftStore.embedding_model.trim() || 'default';
    if (!name) {
      this.error = 'Knowledge base name is required.';
      return;
    }

    this.mutating = true;
    this.error = '';
    this.success = '';
    this.knowledgeService.createBase({ name, description, embeddingModel })
      .pipe(takeUntilDestroyed(this.destroyRef))
      .subscribe({
        next: store => {
          this.vectorStores = [...this.vectorStores, store].sort((left, right) => left.name.localeCompare(right.name));
          this.selectedStore = store;
          this.success = this.i18n.t('ragStudio.knowledgeBaseCreated', { name: store.name });
          this.mutating = false;
          this.resetCreateForm();
          this.loadWikiPages(store.id);
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
    this.knowledgeService.addDocuments(this.selectedStore.id, documents)
      .pipe(takeUntilDestroyed(this.destroyRef))
      .subscribe({
        next: response => {
          if (this.selectedStore) {
            this.selectedStore.documents_added += response.documents_added;
            this.selectedStore.wiki_pages = Math.max(this.selectedStore.wiki_pages, 1);
            this.vectorStores = this.vectorStores.map(store =>
              store.id === this.selectedStore?.id ? this.selectedStore! : store
            );
          }
          this.success = this.i18n.t('ragStudio.documentsIndexed', { count: response.documents_added, name: this.selectedStore?.name ?? '' });
          this.documentDraft = '';
          this.showDocumentForm = false;
          this.mutating = false;
          if (this.selectedStore) {
            this.loadWikiPages(this.selectedStore.id);
          }
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
      this.selectedWikiPage = null;
      this.wikiPages = [];
      this.wikiDraft = { slug: '', title: '', content: '' };
      if (this.selectedStore) {
        this.loadWikiPages(this.selectedStore.id);
      }
    }
  }

  runQuery(): void {
    if (!this.selectedStore || !this.queryText.trim()) {
      return;
    }

    this.queryLoading = true;
    this.error = '';
    this.success = '';
    this.knowledgeService.queryBase(this.selectedStore.id, this.queryText.trim())
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

  selectWikiPage(event: Event): void {
    const listEvent = event as CustomEvent<{ item?: HTMLElement }>;
    const indexValue = listEvent.detail.item?.dataset['index'];
    if (indexValue === undefined) {
      return;
    }
    const index = Number(indexValue);
    if (Number.isNaN(index)) {
      return;
    }
    const page = this.wikiPages[index];
    if (!page) {
      return;
    }
    this.selectedWikiPage = page;
    this.wikiDraft = {
      slug: page.slug,
      title: page.title,
      content: page.content,
    };
  }

  saveActiveWikiPage(): void {
    if (!this.selectedStore || !this.wikiDraft.slug.trim() || !this.wikiDraft.title.trim() || !this.wikiDraft.content.trim()) {
      return;
    }

    this.mutating = true;
    this.error = '';
    this.success = '';
    this.knowledgeService.saveWikiPage(this.selectedStore.id, {
      slug: this.wikiDraft.slug,
      title: this.wikiDraft.title.trim(),
      content: this.wikiDraft.content.trim(),
    })
      .pipe(takeUntilDestroyed(this.destroyRef))
      .subscribe({
        next: page => {
          this.selectedWikiPage = page;
          this.success = `Saved wiki page ${page.title}`;
          this.mutating = false;
          this.loadWikiPages(this.selectedStore!.id, page.slug);
        },
        error: err => {
          this.error = readErrorMessage(err, 'Failed to save wiki page');
          this.mutating = false;
        }
      });
  }

  trackByTableName(index: number, store: PersonalKnowledgeBase): string {
    return store.id;
  }

  trackByIndex(index: number): number {
    return index;
  }

  trackByWikiPage(index: number, page: PersonalWikiPage): string {
    return page.slug;
  }

  formatContextDoc(doc: unknown): string {
    if (typeof doc === 'string') {
      return doc;
    }
    if (doc && typeof doc === 'object') {
      const obj = doc as Record<string, unknown>;
      if (typeof obj['content'] === 'string') {
        return String(obj['content']);
      }
      if (typeof obj['text'] === 'string') {
        return String(obj['text']);
      }
      return JSON.stringify(doc);
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

  private loadWikiPages(storeId: string, preferredSlug?: string): void {
    this.knowledgeService.listWikiPages(storeId)
      .pipe(takeUntilDestroyed(this.destroyRef))
      .subscribe({
        next: pages => {
          this.wikiPages = pages;
          const selected = preferredSlug
            ? pages.find((page) => page.slug === preferredSlug)
            : this.selectedWikiPage
              ? pages.find((page) => page.slug === this.selectedWikiPage?.slug)
              : pages[0];
          this.selectedWikiPage = selected ?? pages[0] ?? null;
          if (this.selectedWikiPage) {
            this.wikiDraft = {
              slug: this.selectedWikiPage.slug,
              title: this.selectedWikiPage.title,
              content: this.selectedWikiPage.content,
            };
          }
          if (this.selectedStore) {
            this.selectedStore.wiki_pages = pages.length;
            this.vectorStores = this.vectorStores.map((store) =>
              store.id === this.selectedStore?.id ? { ...store, wiki_pages: pages.length } : store,
            );
          }
        },
        error: err => {
          this.error = readErrorMessage(err, 'Failed to load wiki pages');
        }
      });
  }
}
