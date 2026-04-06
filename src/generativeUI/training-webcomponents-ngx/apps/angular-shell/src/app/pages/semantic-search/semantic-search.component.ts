import {
  Component, ChangeDetectionStrategy, inject, signal, OnDestroy,
  CUSTOM_ELEMENTS_SCHEMA,
} from '@angular/core';
import { CommonModule } from '@angular/common';
import { FormsModule } from '@angular/forms';
import { I18nService } from '../../services/i18n.service';
import { ApiService } from '../../services/api.service';
import { ToastService } from '../../services/toast.service';
import { GlossaryService } from '../../services/glossary.service';
import { takeUntil, Subject } from 'rxjs';

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
  imports: [CommonModule, FormsModule],
  schemas: [CUSTOM_ELEMENTS_SCHEMA],
  changeDetection: ChangeDetectionStrategy.OnPush,
  template: `
    <div class="page-container" [class.rtl]="i18n.isRtl()">
      <header class="page-header">
        <h1 class="page-title">{{ i18n.t('semanticSearch.title') }}</h1>
        <p class="page-subtitle">{{ i18n.t('semanticSearch.subtitle') }}</p>
      </header>

      <div class="search-bar">
        <div class="search-input-row">
          <input
            class="search-input"
            [(ngModel)]="query"
            [placeholder]="i18n.t('semanticSearch.placeholder')"
            (keydown.enter)="search()"
          />
          <select class="store-select" [(ngModel)]="selectedStore">
            @for (s of stores; track s) {
              <option [value]="s">{{ s }}</option>
            }
          </select>
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
        <div class="results-list">
          <div class="results-header">
            <span>{{ i18n.t('semanticSearch.resultsCount', { count: totalResults() }) }}</span>
          </div>
          @for (r of results(); track r.id) {
            <div class="result-card">
              <div class="result-meta">
                <span class="result-source">{{ r.source }}</span>
                @if (r.page) {
                  <span class="result-page">{{ i18n.t('semanticSearch.page') }} {{ r.page }}</span>
                }
                <span class="result-score" [class.high]="r.score >= 0.8" [class.medium]="r.score >= 0.5 && r.score < 0.8">
                  {{ (r.score * 100).toFixed(1) }}%
                </span>
                <span class="lang-badge" [class.lang-badge--ar]="r.language === 'ar'">
                  {{ r.language === 'ar' ? i18n.t('chat.languageBadge.ar') : i18n.t('chat.languageBadge.en') }}
                </span>
              </div>
              <div class="result-text"><bdi>{{ r.text }}</bdi></div>
            </div>
          }
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

    .text-small { font-size: 0.75rem; }
    .text-muted { color: var(--sapContent_LabelColor, #6a6d70); }
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

  search(): void {
    const q = this.query.trim();
    if (!q || this.searching()) return;

    this.searching.set(true);
    this.hasSearched.set(true);

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

  ngOnDestroy(): void {
    this.destroy$.next();
    this.destroy$.complete();
  }
}
