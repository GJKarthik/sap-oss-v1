import {
  Component, ChangeDetectionStrategy, inject, signal, OnDestroy,
  } from '@angular/core';
import { CommonModule } from '@angular/common';
import { Ui5TrainingComponentsModule } from '../../shared/ui5-training-components.module';
import { FormsModule } from '@angular/forms';
import { I18nService } from '../../services/i18n.service';
import { ApiService } from '../../services/api.service';
import { ToastService } from '../../services/toast.service';
import { GlossaryService } from '../../services/glossary.service';
import { takeUntil, Subject } from 'rxjs';
import { CrossAppLinkComponent } from '../../shared/cross-app-link.component';

export interface SearchResult {
  id: string;
  text: string;
  score: number;
  source: string;
  page?: number;
  language: 'ar' | 'en';
}

interface SearchResponse {
  results: SearchResult[];
  total: number;
  query_embedding_ms?: number;
}

@Component({
  selector: 'app-semantic-search',
  standalone: true,
  imports: [CommonModule, Ui5TrainingComponentsModule, FormsModule, CrossAppLinkComponent],
  changeDetection: ChangeDetectionStrategy.OnPush,
  template: `
    <div class="page-container" [class.rtl]="i18n.isRtl()" role="main" aria-label="Semantic search">
      <ui5-breadcrumbs>
        <ui5-breadcrumbs-item href="/dashboard" text="Home"></ui5-breadcrumbs-item>
        <ui5-breadcrumbs-item text="Semantic Search"></ui5-breadcrumbs-item>
      </ui5-breadcrumbs>
      <app-cross-app-link
        targetApp="aifabric"
        targetRoute="/rag"
        targetLabelKey="crossApp.target.aifabricRag"
        icon="documents">
      </app-cross-app-link>

      <header class="page-header">
        <ui5-title level="H3">{{ i18n.t('semanticSearch.title') }}</ui5-title>
        <p class="page-subtitle">{{ i18n.t('semanticSearch.subtitle') }}</p>
      </header>

      <div class="search-bar" role="search" aria-label="Semantic search query">
        <div class="search-input-row">
          <ui5-input
            class="search-input"
            [value]="query"
            (input)="query = $any($event).target.value"
            [placeholder]="i18n.t('semanticSearch.placeholder')"
            (keydown.enter)="search()"
            accessible-name="Search query"
          ></ui5-input>
          <ui5-select accessible-name="Vector store" (change)="onStoreChange($event)">
            @for (s of stores; track s) {
              <ui5-option [value]="s" [attr.selected]="selectedStore === s ? true : null">{{ s }}</ui5-option>
            }
          </ui5-select>
          <ui5-button design="Emphasized" [disabled]="searching() || !query.trim()" (click)="search()">
            {{ searching() ? i18n.t('semanticSearch.searching') : i18n.t('semanticSearch.search') }}
          </ui5-button>
        </div>
        @if (queryTime()) {
          <span class="text-small text-muted">{{ i18n.t('semanticSearch.queryTime', { ms: queryTime() }) }}</span>
        }
      </div>

      @if (!results().length && !searching() && hasSearched()) {
        <div class="empty-state">
          <ui5-icon name="search"></ui5-icon>
          <p>{{ i18n.t('semanticSearch.noResults') }}</p>
        </div>
      }

      @if (results().length) {
        <div class="results-list" role="region" aria-label="Search results" aria-live="polite">
          <div class="results-header">
            <span>{{ i18n.t('semanticSearch.resultsCount', { count: totalResults() }) }}</span>
            <div class="results-actions">
              <ui5-select (change)="onMinScoreChange($event)">
                <ui5-option value="0" [attr.selected]="minScoreFilter === '0' ? true : null">{{ i18n.t('semanticSearch.allScores') }}</ui5-option>
                <ui5-option value="0.5" [attr.selected]="minScoreFilter === '0.5' ? true : null">≥ 50%</ui5-option>
                <ui5-option value="0.7" [attr.selected]="minScoreFilter === '0.7' ? true : null">≥ 70%</ui5-option>
                <ui5-option value="0.8" [attr.selected]="minScoreFilter === '0.8' ? true : null">≥ 80%</ui5-option>
              </ui5-select>
              <ui5-button design="Transparent" icon="download" (click)="exportResults()" [attr.aria-label]="i18n.t('semanticSearch.export')">{{ i18n.t('semanticSearch.export') }}</ui5-button>
            </div>
          </div>
          @for (r of filteredResults(); track r.id) {
            <div class="result-card">
              <div class="result-meta">
                <span class="result-source">{{ r.source }}</span>
                @if (r.page) {
                  <span class="result-page">{{ i18n.t('semanticSearch.page') }} {{ r.page }}</span>
                }
                <ui5-tag [attr.color-scheme]="r.score >= 0.8 ? '8' : r.score >= 0.5 ? '1' : '2'">{{ (r.score * 100).toFixed(1) }}%</ui5-tag>
                <ui5-tag [attr.color-scheme]="r.language === 'ar' ? '8' : '6'">
                  {{ r.language === 'ar' ? i18n.t('chat.languageBadge.ar') : i18n.t('chat.languageBadge.en') }}
                </ui5-tag>
              </div>
              <div class="result-text"><bdi>{{ r.text }}</bdi></div>
            </div>
          }
        </div>
      }

      <!-- Search History -->
      @if (searchHistory.length > 0) {
        <div class="search-history">
          <ui5-title level="H5">{{ i18n.t('semanticSearch.recentSearches') }}</ui5-title>
          <div class="history-chips">
            @for (h of searchHistory; track h) {
              <ui5-button design="Default" (click)="rerunSearch(h)">{{ h }}</ui5-button>
            }
          </div>
        </div>
      }
    </div>
  `,
  styles: [`
    :host { display: block; height: 100%; overflow-y: auto; }

    .page-container { padding: 1.5rem; max-width: 960px; margin: 0 auto; }

    .page-header { margin-bottom: 1.5rem; }
    .page-title {
      font-size: 1.25rem; font-weight: 600; margin: 0;
      color: var(--sapTextColor, #32363a);
    }
    .page-subtitle {
      font-size: 0.8125rem; margin: 0.25rem 0 0;
      color: var(--sapContent_LabelColor, #6a6d70);
    }

    .search-bar { margin-bottom: 1.5rem; }
    .search-input-row { display: flex; gap: 0.5rem; }

    .search-input {
      flex: 1; padding: 0.5rem 0.75rem;
      border: 1px solid var(--sapField_BorderColor, #89919a);
      border-radius: 0.375rem; font-size: 0.875rem;
      background: var(--sapField_Background, #fff);
      color: var(--sapTextColor, #32363a);
    }

    .store-select {
      padding: 0.5rem; border: 1px solid var(--sapField_BorderColor, #89919a);
      border-radius: 0.375rem; font-size: 0.8125rem;
      background: var(--sapField_Background, #fff);
      color: var(--sapTextColor, #32363a);
    }

    .btn-search {
      padding: 0.5rem 1rem;
      background: var(--sapBrandColor, #0854a0); color: #fff;
      border: none; border-radius: 0.375rem; cursor: pointer; font-size: 0.875rem;
      &:disabled { opacity: 0.5; cursor: default; }
      &:hover:not(:disabled) { background: var(--sapButton_Hover_Background, #0a6ed1); }
    }

    .empty-state {
      display: flex; flex-direction: column; align-items: center;
      padding: 3rem; gap: 0.75rem;
      color: var(--sapContent_LabelColor, #6a6d70);
    }

    .results-header {
      font-size: 0.8125rem; font-weight: 600;
      color: var(--sapContent_LabelColor, #6a6d70);
      margin-bottom: 0.75rem;
    }

    .results-list { display: flex; flex-direction: column; gap: 0.75rem; }

    .result-card {
      padding: 0.75rem 1rem;
      background: var(--sapBaseColor, #fff);
      border: 1px solid var(--sapTile_BorderColor, #e4e4e4);
      border-radius: 0.5rem;
    }

    .result-meta {
      display: flex; gap: 0.5rem; align-items: center;
      font-size: 0.75rem; margin-bottom: 0.5rem;
    }

    .result-source { font-weight: 600; color: var(--sapBrandColor, #0854a0); }
    .result-page { color: var(--sapContent_LabelColor, #6a6d70); }
    .result-score {
      padding: 0.1rem 0.35rem; border-radius: 0.2rem;
      font-weight: 700; font-size: 0.65rem;
      background: var(--sapNegativeBackground, #ffebee);
      color: var(--sapNegativeColor, #b00);
      &.high { background: var(--sapSuccessBackground, #e6f4ea); color: var(--sapPositiveColor, #107e3e); }
      &.medium { background: var(--sapWarningBackground, #fef7e0); color: var(--sapCriticalColor, #e76500); }
    }

    .lang-badge {
      font-size: 0.6rem; font-weight: 700;
      padding: 0.1rem 0.35rem; border-radius: 0.2rem;
      background: var(--sapInformationBackground, #e0f0ff);
      color: var(--sapInformationColor, #0854a0);
    }
    .lang-badge--ar {
      background: var(--sapSuccessBackground, #e6f4ea);
      color: var(--sapPositiveColor, #107e3e);
    }

    .result-text {
      font-size: 0.8125rem; line-height: 1.6;
      white-space: pre-wrap; word-break: break-word;
      color: var(--sapTextColor, #32363a);
    }

    .results-actions { display: flex; gap: 0.5rem; align-items: center; }

    .search-history { margin-top: 1.5rem; }
    .history-title { font-size: 0.8125rem; font-weight: 600; color: var(--sapContent_LabelColor); margin: 0 0 0.5rem; }
    .history-chips { display: flex; flex-wrap: wrap; gap: 0.35rem; }
    .history-chip {
      padding: 0.2rem 0.6rem; border-radius: 999px; font-size: 0.75rem; cursor: pointer;
      border: 1px solid var(--sapField_BorderColor, #89919a); background: var(--sapField_Background, #fff);
      color: var(--sapTextColor, #32363a);
      &:hover { background: var(--sapList_Hover_Background, #f5f5f5); }
    }

    .results-header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 0.75rem; }

    .text-small { font-size: 0.75rem; }
    .text-muted { color: var(--sapContent_LabelColor, #6a6d70); }

    @media (max-width: 768px) {
      .search-input-row { flex-direction: column; }
      .results-actions { flex-direction: column; }
    }
  `],
})
export class SemanticSearchComponent implements OnDestroy {
  readonly i18n = inject(I18nService);
  private readonly api = inject(ApiService);
  private readonly toast = inject(ToastService);
  private readonly glossary = inject(GlossaryService);
  private readonly destroy$ = new Subject<void>();

  readonly searching = signal(false);
  readonly results = signal<SearchResult[]>([]);
  readonly totalResults = signal(0);
  readonly queryTime = signal(0);
  readonly hasSearched = signal(false);

  query = '';
  selectedStore = 'default';
  stores = ['default', 'financial_reports', 'regulatory_docs'];
  minScoreFilter = '0';
  searchHistory: string[] = [];

  onStoreChange(event: any): void {
    this.selectedStore = event.detail?.selectedOption?.value ?? 'default';
  }

  onMinScoreChange(event: any): void {
    this.minScoreFilter = event.detail?.selectedOption?.value ?? '0';
    this.applyFilter();
  }

  filteredResults(): SearchResult[] {
    const minScore = parseFloat(this.minScoreFilter) || 0;
    return this.results().filter(r => r.score >= minScore);
  }

  applyFilter(): void { /* signal-based, filteredResults() recomputes automatically */ }

  search(): void {
    const q = this.query.trim();
    if (!q || this.searching()) return;

    this.searching.set(true);
    this.hasSearched.set(true);
    if (!this.searchHistory.includes(q)) {
      this.searchHistory = [q, ...this.searchHistory.slice(0, 9)];
    }

    this.api.post<SearchResponse>('/rag/search', {
      query: q,
      store: this.selectedStore,
      top_k: 20,
      glossary_context: this.glossary.getSystemPromptSnippet(),
    })
    .pipe(takeUntil(this.destroy$))
    .subscribe({
      next: (resp) => {
        this.results.set(resp.results ?? []);
        this.totalResults.set(resp.total ?? 0);
        this.queryTime.set(resp.query_embedding_ms ?? 0);
        this.searching.set(false);
      },
      error: () => {
        this.toast.error(this.i18n.t('semanticSearch.error'));
        this.searching.set(false);
      },
    });
  }

  rerunSearch(q: string): void {
    this.query = q;
    this.search();
  }

  exportResults(): void {
    const rows = [['ID', 'Source', 'Score', 'Language', 'Page', 'Text']];
    this.filteredResults().forEach(r =>
      rows.push([r.id, r.source, String(r.score), r.language, String(r.page ?? ''), r.text])
    );
    const csv = rows.map(r => r.map(c => `"${c.replace(/"/g, '""')}"`).join(',')).join('\n');
    const blob = new Blob([csv], { type: 'text/csv' });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = 'semantic-search-results.csv';
    a.click();
    URL.revokeObjectURL(url);
  }

  ngOnDestroy(): void {
    this.destroy$.next();
    this.destroy$.complete();
  }
}
