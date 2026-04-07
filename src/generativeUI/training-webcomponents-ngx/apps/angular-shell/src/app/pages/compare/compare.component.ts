import {
  Component, CUSTOM_ELEMENTS_SCHEMA, ChangeDetectionStrategy,
  signal, inject, OnInit
} from '@angular/core';
import { CommonModule } from '@angular/common';
import { FormsModule } from '@angular/forms';
import { HttpClient } from '@angular/common/http';
import { ToastService } from '../../services/toast.service';
import { I18nService } from '../../services/i18n.service';
import { environment } from '../../../environments/environment';
import { CrossAppLinkComponent } from '../../shared';

interface DeployedModel {
  id: string;
  label: string;
  model_name: string;
}

@Component({
  selector: 'app-compare',
  standalone: true,
  imports: [CommonModule, FormsModule, CrossAppLinkComponent],
  schemas: [CUSTOM_ELEMENTS_SCHEMA],
  changeDetection: ChangeDetectionStrategy.OnPush,
  template: `
    <div class="page-content">
      <div class="page-header">
        <h1 class="page-title">{{ i18n.t('compare.title') }}</h1>
        <span class="text-muted text-small">{{ i18n.t('compare.subtitle') }}</span>
      </div>

      <app-cross-app-link
        targetApp="training"
        targetRoute="/registry"
        targetLabel="Model Registry"
        icon="database"
        relationLabel="Related:">
      </app-cross-app-link>

      <!-- Model selectors -->
      <div class="selector-row">
        <div class="model-selector">
          <label><strong>{{ i18n.t('compare.modelA') }}</strong></label>
          <select [(ngModel)]="modelA" class="sel-input">
            <option value="">{{ i18n.t('compare.select') }}</option>
            @for (m of deployedModels(); track m.id) {
              <option [value]="m.id"><bdi>{{ m.label }}</bdi></option>
            }
          </select>
          @if (modelA) {
            <span class="badge-model"><bdi>{{ modelNameFor(modelA) }}</bdi></span>
          }
        </div>
        <div class="vs-divider">{{ i18n.t('compare.vs') }}</div>
        <div class="model-selector">
          <label><strong>{{ i18n.t('compare.modelB') }}</strong></label>
          <select [(ngModel)]="modelB" class="sel-input">
            <option value="">{{ i18n.t('compare.select') }}</option>
            @for (m of deployedModels(); track m.id) {
              <option [value]="m.id"><bdi>{{ m.label }}</bdi></option>
            }
          </select>
          @if (modelB) {
            <span class="badge-model"><bdi>{{ modelNameFor(modelB) }}</bdi></span>
          }
        </div>
      </div>

      @if (!deployedModels().length) {
        <div class="empty-state">
          <div style="font-size: 2rem; margin-bottom: 0.5rem;"><ui5-icon name="machine"></ui5-icon></div>
          <p>{{ i18n.t('compare.noDeployed') }}</p>
        </div>
      }

      <!-- Screen reader loading announcement (A-12) -->
      <div role="status" aria-live="polite" class="sr-only">{{ loading() ? i18n.t('compare.loadingResults') : (resultA() !== null ? i18n.t('compare.resultsReady') : '') }}</div>

      <!-- Shared prompt input -->
      <div class="prompt-bar">
        <input class="prompt-input" [(ngModel)]="prompt"
               [placeholder]="i18n.t('compare.placeholder')"
               (keyup.enter)="runComparison()" />
        <ui5-button design="Emphasized" (click)="runComparison()"
                [disabled]="!modelA || !modelB || !prompt.trim() || loading()">
          {{ loading() ? i18n.t('compare.running') : i18n.t('compare.compare') }}
        </ui5-button>
      </div>

      <!-- Side-by-side results -->
      @if (resultA() !== null || resultB() !== null) {
        <!-- Metrics comparison bar -->
        <div class="metrics-bar" role="region" aria-label="Response metrics">
          <div class="metric-chip">
            <span class="metric-label">{{ i18n.t('compare.aLatency') }}</span>
            <span class="metric-value">{{ latencyA() }}ms</span>
          </div>
          <div class="metric-chip">
            <span class="metric-label">{{ i18n.t('compare.bLatency') }}</span>
            <span class="metric-value">{{ latencyB() }}ms</span>
          </div>
          <div class="metric-chip">
            <span class="metric-label">{{ i18n.t('compare.aTokens') }}</span>
            <span class="metric-value">~{{ tokenCount(resultA()) }}</span>
          </div>
          <div class="metric-chip">
            <span class="metric-label">{{ i18n.t('compare.bTokens') }}</span>
            <span class="metric-value">~{{ tokenCount(resultB()) }}</span>
          </div>
          <div class="metric-chip" [class.metric-match]="similarityPct() >= 80" [class.metric-diff]="similarityPct() < 50">
            <span class="metric-label">{{ i18n.t('compare.similarity') }}</span>
            <span class="metric-value">{{ similarityPct() }}%</span>
          </div>
        </div>

        <div class="results-grid">
          <div class="result-card" [class.winner]="isWinner('A')">
            <div class="result-header">
              <span>{{ i18n.t('compare.modelA') }} · <bdi>{{ modelNameFor(modelA) }}</bdi></span>
              @if (isWinner('A')) { <span class="winner-badge">{{ i18n.t('compare.bestShorter') }}</span> }
            </div>
            <pre class="result-sql"><bdi [innerHTML]="highlightDiff(resultA(), resultB())"></bdi></pre>
          </div>
          <div class="result-card" [class.winner]="isWinner('B')">
            <div class="result-header">
              <span>{{ i18n.t('compare.modelB') }} · <bdi>{{ modelNameFor(modelB) }}</bdi></span>
              @if (isWinner('B')) { <span class="winner-badge">{{ i18n.t('compare.bestShorter') }}</span> }
            </div>
            <pre class="result-sql"><bdi [innerHTML]="highlightDiff(resultB(), resultA())"></bdi></pre>
          </div>
        </div>

        <!-- History -->
        @if (history().length > 0) {
          <div class="history-section">
            <h2 class="section-title">{{ i18n.t('compare.history') }}</h2>
            @for (h of history(); track $index) {
              <div class="history-card">
                <p class="history-q"><strong>Q:</strong> {{ h.query }}</p>
                <div class="history-grid">
                  <div><strong>A:</strong><pre>{{ h.a }}</pre></div>
                  <div><strong>B:</strong><pre>{{ h.b }}</pre></div>
                </div>
              </div>
            }
          </div>
        }
      }
    </div>
  `,
  styles: [`
    .selector-row { display: flex; align-items: center; gap: 1.5rem; margin-bottom: 1.5rem; }
    .model-selector { flex: 1; display: flex; flex-direction: column; gap: 0.4rem; }
    .sel-input { padding: 0.5rem; border: 1px solid var(--sapField_BorderColor, #89919a); border-radius: 0.25rem;
      font-size: 0.875rem; background: var(--sapField_Background, #fff); color: var(--sapTextColor, #32363a); width: 100%; }
    .badge-model { font-size: 0.7rem; background: var(--sapInformationBackground, #e3f2fd); color: var(--sapInformativeColor, #1565c0); padding: 2px 8px;
      border-radius: 1rem; font-weight: 600; align-self: flex-start; }
    .vs-divider { font-size: 1.25rem; font-weight: 800; color: var(--sapContent_LabelColor, #89919a); padding-top: 1.25rem; }
    .empty-state { text-align: center; padding: 3rem; color: var(--sapContent_LabelColor, #6a6d70); background: var(--sapTile_Background, #fff);
      border: 1px dashed var(--sapTile_BorderColor, #e4e4e4); border-radius: 0.5rem; margin-bottom: 1.5rem; p { margin: 0; } }
    .prompt-bar { display: flex; gap: 0.75rem; margin-bottom: 1.5rem; }
    .prompt-input { flex: 1; padding: 0.625rem; border: 1px solid var(--sapField_BorderColor, #89919a); border-radius: 0.25rem;
      font-size: 0.875rem; background: var(--sapField_Background, #fff); color: var(--sapTextColor, #32363a); }
    .btn-run { padding: 0.625rem 1.25rem; background: var(--sapButton_Emphasized_Background, #0854a0); color: var(--sapButton_Emphasized_TextColor, #fff); border: none;
      border-radius: 0.25rem; cursor: pointer; font-weight: 600; white-space: nowrap;
      &:disabled { opacity: 0.5; cursor: not-allowed; }
      &:hover:not(:disabled) { background: var(--sapButton_Emphasized_Hover_Background, #063d75); } }
    .results-grid { display: grid; grid-template-columns: 1fr 1fr; gap: 1rem; margin-bottom: 1.5rem; }
    @media (max-width: 600px) { .results-grid { grid-template-columns: 1fr; } }
    .result-card { background: var(--sapTile_Background, #fff); border: 1px solid var(--sapTile_BorderColor, #e4e4e4); border-radius: 0.5rem; overflow: hidden;
      &.winner { border-color: var(--sapPositiveColor, #4caf50); box-shadow: 0 0 0 2px rgba(76, 175, 80, 0.2); } }
    .result-header { display: flex; justify-content: space-between; align-items: center;
      padding: 0.5rem 0.75rem; background: var(--sapList_HeaderBackground, #f5f5f5); border-bottom: 1px solid var(--sapList_BorderColor, #e4e4e4);
      font-size: 0.8125rem; font-weight: 600; color: var(--sapTextColor, #32363a); }
    .winner-badge { background: var(--sapSuccessBackground, #e8f5e9); color: var(--sapPositiveTextColor, #2e7d32); padding: 2px 8px; border-radius: 1rem;
      font-size: 0.7rem; font-weight: 600; }
    .result-sql { margin: 0; padding: 0.875rem; background: var(--sapShell_Background, #1e1e1e); color: var(--sapShell_TextColor, #9cdcfe);
      font-family: 'SFMono-Regular', Consolas, monospace; font-size: 0.8rem;
      white-space: pre-wrap; word-break: break-all; min-height: 80px; }
    .metrics-bar { display: flex; gap: 0.5rem; flex-wrap: wrap; margin-bottom: 1rem; }
    .metric-chip { display: flex; flex-direction: column; align-items: center; padding: 0.4rem 0.75rem; border-radius: 0.5rem;
      background: var(--sapTile_Background, #fff); border: 1px solid var(--sapTile_BorderColor, #e4e4e4); min-width: 60px; }
    .metric-label { font-size: 0.6rem; font-weight: 600; color: var(--sapContent_LabelColor, #6a6d70); text-transform: uppercase; }
    .metric-value { font-size: 0.875rem; font-weight: 700; color: var(--sapTextColor, #32363a); }
    .metric-match { border-color: var(--sapPositiveColor, #4caf50); }
    .metric-diff { border-color: var(--sapNegativeColor, #f44336); }
    :host ::ng-deep .diff-add { background: rgba(76, 175, 80, 0.15); border-radius: 2px; }
    .history-section { margin-top: 0.5rem; }
    .section-title { font-size: 1rem; font-weight: 600; margin: 0 0 0.75rem; color: var(--sapTextColor, #32363a); }
    .history-card { background: var(--sapTile_Background, #fff); border: 1px solid var(--sapTile_BorderColor, #e4e4e4); border-radius: 0.5rem;
      padding: 1rem; margin-bottom: 0.75rem; }
    .history-q { margin: 0 0 0.5rem; font-size: 0.875rem; }
    .history-grid { display: grid; grid-template-columns: 1fr 1fr; gap: 0.75rem;
      pre { margin: 0; background: var(--sapList_Background, #f5f5f5); padding: 0.5rem; border-radius: 0.25rem;
        font-size: 0.75rem; white-space: pre-wrap; word-break: break-all; } }

    @media (max-width: 768px) {
      .results-grid { grid-template-columns: 1fr; }
      .metrics-bar { flex-wrap: wrap; }
      .selector-row { flex-direction: column; }
    }
  `]
})
export class CompareComponent implements OnInit {
  private readonly http = inject(HttpClient);
  private readonly toast = inject(ToastService);
  readonly i18n = inject(I18nService);

  readonly deployedModels = signal<DeployedModel[]>([]);
  readonly loading = signal(false);
  readonly resultA = signal<string | null>(null);
  readonly resultB = signal<string | null>(null);
  readonly latencyA = signal(0);
  readonly latencyB = signal(0);
  readonly history = signal<{ query: string; a: string; b: string }[]>([]);

  modelA = '';
  modelB = '';
  prompt = '';

  ngOnInit() {
    this.loadDeployedModels();
  }

  loadDeployedModels() {
    this.http.get<{ id: string; status: string; config: { model_name: string }; deployed: boolean }[]>(
      `${environment.apiBaseUrl}/jobs`
    ).subscribe({
      next: (jobs) => {
        const deployed = jobs
          .filter(j => j.deployed && j.status === 'completed')
          .map(j => ({
            id: j.id,
            label: `${j.id.slice(0, 8)} · ${j.config?.model_name ?? 'Unknown'}`,
            model_name: j.config?.model_name ?? 'Unknown'
          }));
        this.deployedModels.set(deployed);
      },
      error: () => this.toast.error(this.i18n.t('compare.loadModelsFailed'))
    });
  }

  modelNameFor(id: string): string {
    return this.deployedModels().find(m => m.id === id)?.model_name ?? id.slice(0, 8);
  }

  runComparison() {
    if (!this.modelA || !this.modelB || !this.prompt.trim()) return;
    this.loading.set(true);
    this.resultA.set(null);
    this.resultB.set(null);
    this.latencyA.set(0);
    this.latencyB.set(0);

    const startA = performance.now();
    const startB = performance.now();

    const queryA = this.http.post<{ response: string }>(
      `${environment.apiBaseUrl}/inference/${this.modelA}/chat`,
      { prompt: this.prompt }
    );
    const queryB = this.http.post<{ response: string }>(
      `${environment.apiBaseUrl}/inference/${this.modelB}/chat`,
      { prompt: this.prompt }
    );

    let doneA = false, doneB = false;
    const check = () => { if (doneA && doneB) this.loading.set(false); };

    queryA.subscribe({
      next: (r) => { this.resultA.set(r.response); this.latencyA.set(Math.round(performance.now() - startA)); doneA = true; check(); },
      error: () => { this.resultA.set('[Error — model did not respond]'); this.latencyA.set(Math.round(performance.now() - startA)); doneA = true; check(); }
    });
    queryB.subscribe({
      next: (r) => {
        this.resultB.set(r.response);
        this.latencyB.set(Math.round(performance.now() - startB));
        doneB = true;
        check();
        const ra = this.resultA();
        const rb = this.resultB();
        if (ra !== null && rb !== null) {
          this.history.update(h => [{ query: this.prompt, a: ra, b: rb }, ...h.slice(0, 9)]);
        }
      },
      error: () => { this.resultB.set('[Error — model did not respond]'); this.latencyB.set(Math.round(performance.now() - startB)); doneB = true; check(); }
    });
  }

  isWinner(side: 'A' | 'B'): boolean {
    const a = this.resultA();
    const b = this.resultB();
    if (!a || !b) return false;
    return side === 'A' ? a.length <= b.length : b.length < a.length;
  }

  tokenCount(text: string | null): number {
    if (!text) return 0;
    return Math.ceil(text.length / 4); // rough estimate: ~4 chars per token
  }

  similarityPct(): number {
    const a = this.resultA();
    const b = this.resultB();
    if (!a || !b) return 0;
    const wordsA = new Set(a.toLowerCase().split(/\s+/));
    const wordsB = new Set(b.toLowerCase().split(/\s+/));
    const intersection = [...wordsA].filter(w => wordsB.has(w)).length;
    const union = new Set([...wordsA, ...wordsB]).size;
    return union === 0 ? 100 : Math.round((intersection / union) * 100);
  }

  highlightDiff(text: string | null, other: string | null): string {
    if (!text) return '';
    const escaped = text.replace(/</g, '&lt;').replace(/>/g, '&gt;');
    if (!other) return escaped;
    const otherWords = new Set(other.toLowerCase().split(/\s+/));
    return escaped.replace(/\S+/g, word => {
      const clean = word.replace(/&lt;|&gt;|&amp;/g, '').toLowerCase();
      return otherWords.has(clean) ? word : `<span class="diff-add">${word}</span>`;
    });
  }
}
