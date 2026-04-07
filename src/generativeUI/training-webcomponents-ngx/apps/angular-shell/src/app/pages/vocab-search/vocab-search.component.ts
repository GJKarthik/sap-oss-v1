import { Component, CUSTOM_ELEMENTS_SCHEMA, DestroyRef, OnInit, inject } from '@angular/core';
import { CommonModule } from '@angular/common';
import { FormsModule } from '@angular/forms';
import { Ui5WebcomponentsModule } from '@ui5/webcomponents-ngx';
import { takeUntilDestroyed } from '@angular/core/rxjs-interop';
import { EmptyStateComponent } from '../../shared';
import { McpService, VocabTerm, VocabSearchResult, VocabStatistics } from '../../services/mcp.service';
import { I18nService } from '../../services/i18n.service';

@Component({
  selector: 'app-vocab-search',
  standalone: true,
  imports: [CommonModule, FormsModule, Ui5WebcomponentsModule, EmptyStateComponent],
  schemas: [CUSTOM_ELEMENTS_SCHEMA],
  template: `
    <ui5-page background-design="Solid">
      <ui5-bar slot="header" design="Header">
        <ui5-title slot="startContent" level="H3">{{ i18n.t('vocabSearch.title') }}</ui5-title>
        <ui5-button slot="endContent" icon="refresh" (click)="loadStats()" [disabled]="loading">
          {{ loading ? i18n.t('common.loading') : i18n.t('common.refresh') }}
        </ui5-button>
      </ui5-bar>

      <div class="vs-content" role="main" aria-label="Vocabulary Search">
        <ui5-message-strip *ngIf="error" design="Negative" [hideCloseButton]="false" (close)="error = ''" role="alert">{{ error }}</ui5-message-strip>

        <!-- Statistics Cards -->
        @if (stats) {
          <div class="stats-row">
            <div class="stat-card">
              <span class="stat-value">{{ stats.total_vocabularies }}</span>
              <span class="stat-label">{{ i18n.t('vocabSearch.totalVocabularies') }}</span>
            </div>
            <div class="stat-card">
              <span class="stat-value">{{ stats.total_terms }}</span>
              <span class="stat-label">{{ i18n.t('vocabSearch.totalTerms') }}</span>
            </div>
          </div>
        }

        <!-- Search Form -->
        <ui5-card>
          <ui5-card-header slot="header" title-text="{{ i18n.t('vocabSearch.searchTitle') }}" subtitle-text="{{ i18n.t('vocabSearch.searchSubtitle') }}"></ui5-card-header>
          <div class="card-content">
            <div class="search-row">
              <ui5-input ngDefaultControl name="searchQuery" [(ngModel)]="searchQuery" placeholder="{{ i18n.t('vocabSearch.searchPlaceholder') }}" accessible-name="Search vocabulary terms" style="flex:1" (keyup.enter)="search()"></ui5-input>
              <ui5-select ngDefaultControl name="searchMode" [(ngModel)]="searchMode" accessible-name="Search mode">
                <ui5-option value="text">{{ i18n.t('vocabSearch.textSearch') }}</ui5-option>
                <ui5-option value="semantic">{{ i18n.t('vocabSearch.semanticSearch') }}</ui5-option>
              </ui5-select>
              <ui5-select ngDefaultControl name="vocabFilter" [(ngModel)]="vocabFilter" accessible-name="Filter by vocabulary">
                <ui5-option value="">{{ i18n.t('vocabSearch.allVocabularies') }}</ui5-option>
                <ui5-option *ngFor="let v of vocabularies" [value]="v">{{ v }}</ui5-option>
              </ui5-select>
              <ui5-button design="Emphasized" icon="search" (click)="search()" [disabled]="searching || !searchQuery.trim()">
                {{ searching ? i18n.t('vocabSearch.searching') : i18n.t('vocabSearch.search') }}
              </ui5-button>
            </div>
          </div>
        </ui5-card>

        <!-- Results -->
        @if (results.length > 0) {
          <ui5-card>
            <ui5-card-header slot="header" title-text="{{ i18n.t('vocabSearch.results') }}" [additionalText]="results.length + ''"></ui5-card-header>
            <div class="results-list">
              @for (term of results; track term.name) {
                <div class="result-item" [class.selected]="selectedTerm === term" (click)="selectedTerm = term" role="button" tabindex="0">
                  <div class="result-header">
                    <strong>{{ term.name }}</strong>
                    <ui5-badge color-scheme="6">{{ term.vocabulary }}</ui5-badge>
                    <ui5-badge *ngIf="term.experimental" color-scheme="2">Experimental</ui5-badge>
                    <ui5-badge *ngIf="term.deprecated" color-scheme="1">Deprecated</ui5-badge>
                  </div>
                  <div class="result-type">{{ term.type }}</div>
                  @if (term.description) {
                    <div class="result-desc">{{ term.description }}</div>
                  }
                  @if (term.score !== undefined) {
                    <div class="result-score">Score: {{ term.score | number:'1.2-2' }}</div>
                  }
                </div>
              }
            </div>
          </ui5-card>
        } @else if (searched && !searching) {
          <app-empty-state icon="search" [title]="i18n.t('vocabSearch.noResults')" [description]="i18n.t('vocabSearch.noResultsDesc')"></app-empty-state>
        }

        <!-- Detail Panel -->
        @if (selectedTerm) {
          <ui5-card>
            <ui5-card-header slot="header" [titleText]="selectedTerm.name" [subtitleText]="selectedTerm.vocabulary"></ui5-card-header>
            <div class="card-content detail-panel">
              <div class="detail-row"><span class="detail-label">{{ i18n.t('vocabSearch.type') }}</span><span>{{ selectedTerm.type }}</span></div>
              @if (selectedTerm.description) {
                <div class="detail-row"><span class="detail-label">{{ i18n.t('vocabSearch.description') }}</span><span>{{ selectedTerm.description }}</span></div>
              }
              @if (selectedTerm.applies_to && selectedTerm.applies_to.length > 0) {
                <div class="detail-row"><span class="detail-label">{{ i18n.t('vocabSearch.appliesTo') }}</span><span>{{ selectedTerm.applies_to.join(', ') }}</span></div>
              }
            </div>
          </ui5-card>
        }
      </div>
    </ui5-page>
  `,
  styles: [`
    .vs-content { padding: 1rem; max-width: 1400px; margin: 0 auto; display: flex; flex-direction: column; gap: 1rem; }
    .stats-row { display: grid; grid-template-columns: repeat(auto-fit, minmax(180px, 1fr)); gap: 1rem; }
    .stat-card { text-align: center; padding: 1.25rem; background: var(--sapBackgroundColor); border-radius: 0.75rem; border: 1px solid var(--sapList_BorderColor); }
    .stat-value { display: block; font-size: 2rem; font-weight: 700; color: var(--sapBrandColor); }
    .stat-label { font-size: 0.875rem; color: var(--sapContent_LabelColor); }
    .card-content { padding: 1rem; display: grid; gap: 1rem; }
    .search-row { display: flex; gap: 0.5rem; align-items: flex-end; flex-wrap: wrap; }
    .results-list { padding: 0.5rem; display: grid; gap: 0.5rem; }
    .result-item { padding: 0.75rem 1rem; border-radius: 0.5rem; border: 1px solid var(--sapList_BorderColor); cursor: pointer; transition: background 0.15s; }
    .result-item:hover, .result-item.selected { background: var(--sapList_Hover_Background); }
    .result-header { display: flex; gap: 0.5rem; align-items: center; flex-wrap: wrap; }
    .result-type { font-size: 0.8rem; color: var(--sapContent_LabelColor); margin-top: 0.25rem; }
    .result-desc { font-size: 0.875rem; margin-top: 0.25rem; line-height: 1.4; }
    .result-score { font-size: 0.75rem; color: var(--sapPositiveColor); margin-top: 0.25rem; }
    .detail-panel { display: grid; gap: 0.75rem; }
    .detail-row { display: grid; grid-template-columns: 140px 1fr; gap: 0.5rem; }
    .detail-label { font-weight: 600; color: var(--sapContent_LabelColor); }
    ui5-message-strip { margin-bottom: 0.25rem; }
  `],
})
export class VocabSearchComponent implements OnInit {
  private readonly mcpService = inject(McpService);
  private readonly destroyRef = inject(DestroyRef);
  readonly i18n = inject(I18nService);

  searchQuery = '';
  searchMode = 'text';
  vocabFilter = '';
  vocabularies: string[] = [];
  results: VocabTerm[] = [];
  selectedTerm: VocabTerm | null = null;
  stats: VocabStatistics | null = null;
  loading = false;
  searching = false;
  searched = false;
  error = '';

  ngOnInit(): void {
    this.loadStats();
    this.loadVocabularies();
  }

  loadStats(): void {
    this.loading = true;
    this.mcpService.getVocabStatistics().pipe(takeUntilDestroyed(this.destroyRef)).subscribe({
      next: stats => { this.stats = stats; this.loading = false; },
      error: () => { this.loading = false; },
    });
  }

  loadVocabularies(): void {
    this.mcpService.listVocabularies().pipe(takeUntilDestroyed(this.destroyRef)).subscribe({
      next: result => this.vocabularies = result.vocabularies || [],
      error: () => {},
    });
  }

  search(): void {
    if (!this.searchQuery.trim() || this.searching) return;
    this.searching = true;
    this.selectedTerm = null;
    this.error = '';
    const search$ = this.searchMode === 'semantic'
      ? this.mcpService.vocabSemanticSearch(this.searchQuery)
      : this.mcpService.searchVocabTerms(this.searchQuery, this.vocabFilter || undefined);
    search$.pipe(takeUntilDestroyed(this.destroyRef)).subscribe({
      next: result => { this.results = result.terms || []; this.searching = false; this.searched = true; },
      error: () => { this.error = this.i18n.t('vocabSearch.searchFailed'); this.searching = false; this.searched = true; },
    });
  }
}
