import {
  Component, CUSTOM_ELEMENTS_SCHEMA, ChangeDetectionStrategy,
  signal, computed, inject, OnInit
} from '@angular/core';
import { CommonModule } from '@angular/common';
import { FormsModule } from '@angular/forms';
import { HttpClient } from '@angular/common/http';
import { ToastService } from '../../services/toast.service';
import { environment } from '../../../environments/environment';

interface DeployedModel {
  id: string;
  label: string;
  model_name: string;
}

@Component({
  selector: 'app-compare',
  standalone: true,
  imports: [CommonModule, FormsModule],
  schemas: [CUSTOM_ELEMENTS_SCHEMA],
  changeDetection: ChangeDetectionStrategy.OnPush,
  template: `
    <div class="page-content">
      <div class="page-header">
        <h1 class="page-title">A/B Model Comparison</h1>
        <span class="subtitle">Test the same prompt against two deployed models side-by-side</span>
      </div>

      <!-- Model selectors -->
      <div class="selector-row">
        <div class="model-selector-card">
          <div class="selector-label">
            <span class="label-dot dot-a"></span>
            Model A
          </div>
          <select [(ngModel)]="modelA" class="sel-input">
            <option value="">— Choose a model —</option>
            @for (m of deployedModels(); track m.id) {
              <option [value]="m.id">{{ m.label }}</option>
            }
          </select>
          @if (modelA) {
            <div class="model-meta">
              <span class="badge-model">{{ modelNameFor(modelA) }}</span>
              <span class="badge-id">{{ modelA.slice(0, 8) }}</span>
            </div>
          }
        </div>

        <button class="swap-btn" (click)="swapModels()" [class.spinning]="swapAnim()"
                [disabled]="!modelA && !modelB" title="Swap models">
          <span class="swap-icon">⇄</span>
        </button>

        <div class="model-selector-card">
          <div class="selector-label">
            <span class="label-dot dot-b"></span>
            Model B
          </div>
          <select [(ngModel)]="modelB" class="sel-input">
            <option value="">— Choose a model —</option>
            @for (m of deployedModels(); track m.id) {
              <option [value]="m.id">{{ m.label }}</option>
            }
          </select>
          @if (modelB) {
            <div class="model-meta">
              <span class="badge-model">{{ modelNameFor(modelB) }}</span>
              <span class="badge-id">{{ modelB.slice(0, 8) }}</span>
            </div>
          }
        </div>
      </div>

      @if (!deployedModels().length) {
        <div class="empty-state">
          <div class="empty-icon">🚀</div>
          <p class="empty-title">No Deployed Models</p>
          <p class="empty-desc">Train a model and click <strong>Deploy Model</strong> in the Model Optimizer to get started.</p>
        </div>
      }

      <!-- Shared prompt input -->
      <div class="prompt-bar">
        <div class="prompt-wrapper">
          <span class="prompt-icon">💬</span>
          <input class="prompt-input" [(ngModel)]="prompt"
                 placeholder="Enter a natural language question (e.g. 'What is the total balance for active accounts?')"
                 (keyup.enter)="runComparison()" />
        </div>
        <button class="btn-run" (click)="runComparison()"
                [disabled]="!modelA || !modelB || !prompt.trim() || loading()">
          @if (loading()) {
            <span class="spinner"></span> Running…
          } @else {
            ▶ Compare
          }
        </button>
      </div>

      <!-- Summary verdict -->
      @if (resultA() !== null && resultB() !== null) {
        <div class="verdict-card" [class.fade-in]="true">
          <div class="verdict-header">Comparison Summary</div>
          <div class="verdict-body">
            <div class="verdict-metric">
              <span class="verdict-label">Response Length</span>
              <div class="verdict-bars">
                <div class="verdict-bar-row">
                  <span class="bar-label">A</span>
                  <div class="bar-track">
                    <div class="bar-fill bar-a" [style.width.%]="barWidth('A')"></div>
                  </div>
                  <span class="bar-value" [class.bar-winner]="isWinner('A')">{{ resultA()!.length }} chars</span>
                </div>
                <div class="verdict-bar-row">
                  <span class="bar-label">B</span>
                  <div class="bar-track">
                    <div class="bar-fill bar-b" [style.width.%]="barWidth('B')"></div>
                  </div>
                  <span class="bar-value" [class.bar-winner]="isWinner('B')">{{ resultB()!.length }} chars</span>
                </div>
              </div>
            </div>
            <div class="verdict-metric">
              <span class="verdict-label">Line Count</span>
              <div class="verdict-bars">
                <div class="verdict-bar-row">
                  <span class="bar-label">A</span>
                  <div class="bar-track">
                    <div class="bar-fill bar-a" [style.width.%]="lineBarWidth('A')"></div>
                  </div>
                  <span class="bar-value" [class.bar-winner]="lineCount(resultA()!) <= lineCount(resultB()!)">{{ lineCount(resultA()!) }} lines</span>
                </div>
                <div class="verdict-bar-row">
                  <span class="bar-label">B</span>
                  <div class="bar-track">
                    <div class="bar-fill bar-b" [style.width.%]="lineBarWidth('B')"></div>
                  </div>
                  <span class="bar-value" [class.bar-winner]="lineCount(resultB()!) <= lineCount(resultA()!)">{{ lineCount(resultB()!) }} lines</span>
                </div>
              </div>
            </div>
            <div class="verdict-winner">
              @if (resultA()!.length === resultB()!.length) {
                <span class="verdict-tie">🤝 It's a tie — both responses are equal length</span>
              } @else if (isWinner('A')) {
                <span class="verdict-win">🏆 <strong>Model A</strong> produced a more concise response</span>
              } @else {
                <span class="verdict-win">🏆 <strong>Model B</strong> produced a more concise response</span>
              }
            </div>
          </div>
        </div>
      }

      <!-- Side-by-side results -->
      @if (resultA() !== null || resultB() !== null) {
        <div class="results-grid">
          <div class="result-card" [class.winner]="isWinner('A')" [class.fade-in]="true">
            <div class="result-header header-a">
              <div class="result-header-left">
                <span class="label-dot dot-a"></span>
                <span>Model A · {{ modelNameFor(modelA) }}</span>
              </div>
              @if (isWinner('A')) { <span class="winner-badge">🏆 Winner</span> }
            </div>
            <div class="result-stats">
              <span>{{ resultA()?.length ?? 0 }} chars</span>
              <span>{{ lineCount(resultA() ?? '') }} lines</span>
            </div>
            <pre class="result-sql">{{ resultA() ?? 'Error or no response' }}</pre>
          </div>
          <div class="result-card" [class.winner]="isWinner('B')" [class.fade-in]="true">
            <div class="result-header header-b">
              <div class="result-header-left">
                <span class="label-dot dot-b"></span>
                <span>Model B · {{ modelNameFor(modelB) }}</span>
              </div>
              @if (isWinner('B')) { <span class="winner-badge">🏆 Winner</span> }
            </div>
            <div class="result-stats">
              <span>{{ resultB()?.length ?? 0 }} chars</span>
              <span>{{ lineCount(resultB() ?? '') }} lines</span>
            </div>
            <pre class="result-sql">{{ resultB() ?? 'Error or no response' }}</pre>
          </div>
        </div>

        <!-- Diff view -->
        @if (resultA() && resultB() && resultA() !== resultB()) {
          <div class="diff-section">
            <div class="diff-header" (click)="showDiff.set(!showDiff())">
              <span>{{ showDiff() ? '▾' : '▸' }} Output Diff</span>
              <span class="diff-toggle">{{ showDiff() ? 'Hide' : 'Show' }}</span>
            </div>
            @if (showDiff()) {
              <div class="diff-body">
                @for (line of diffLines(); track $index) {
                  <div class="diff-line" [class.diff-add]="line.type === 'add'"
                       [class.diff-remove]="line.type === 'remove'"
                       [class.diff-same]="line.type === 'same'">
                    <span class="diff-indicator">{{ line.type === 'add' ? '+' : line.type === 'remove' ? '−' : ' ' }}</span>
                    <span class="diff-text">{{ line.text }}</span>
                  </div>
                }
              </div>
            }
          </div>
        }

        <!-- History -->
        @if (history().length > 0) {
          <div class="history-section">
            <h2 class="section-title">
              <span>📋 Comparison History</span>
              <span class="history-count">{{ history().length }}</span>
            </h2>
            @for (h of history(); track $index) {
              <div class="history-card">
                <div class="history-q">
                  <span class="history-num">#{{ history().length - $index }}</span>
                  {{ h.query }}
                </div>
                <div class="history-grid">
                  <div class="history-col">
                    <div class="history-col-label">
                      <span class="label-dot dot-a"></span> Model A
                      @if (h.a.length <= h.b.length) { <span class="mini-winner">✓</span> }
                    </div>
                    <pre>{{ h.a }}</pre>
                  </div>
                  <div class="history-col">
                    <div class="history-col-label">
                      <span class="label-dot dot-b"></span> Model B
                      @if (h.b.length <= h.a.length) { <span class="mini-winner">✓</span> }
                    </div>
                    <pre>{{ h.b }}</pre>
                  </div>
                </div>
              </div>
            }
          </div>
        }
      }
    </div>
  `,
  styles: [`
    .subtitle { color: var(--sapContent_LabelColor, #6a6d70); font-size: 0.875rem; }

    /* Selector row */
    .selector-row { display: flex; align-items: stretch; gap: 0.75rem; margin-bottom: 1.5rem; }
    .model-selector-card { flex: 1; background: var(--sapTile_Background, #fff);
      border: 1px solid var(--sapTile_BorderColor, #e4e4e4); border-radius: 0.5rem;
      padding: 1rem; display: flex; flex-direction: column; gap: 0.5rem;
      transition: box-shadow 0.2s; }
    .model-selector-card:hover { box-shadow: 0 2px 8px rgba(0,0,0,0.06); }
    .selector-label { font-weight: 700; font-size: 0.8125rem; display: flex; align-items: center; gap: 0.5rem;
      color: var(--sapTextColor, #32363a); }
    .label-dot { width: 8px; height: 8px; border-radius: 50%; display: inline-block; }
    .dot-a { background: var(--sapBrandColor, #0854a0); }
    .dot-b { background: #e57300; }
    .sel-input { padding: 0.5rem 0.625rem; border: 1px solid var(--sapTile_BorderColor, #e4e4e4);
      border-radius: 0.375rem; font-size: 0.875rem; background: var(--sapBaseColor, #fff);
      width: 100%; transition: border-color 0.2s; outline: none; }
    .sel-input:focus { border-color: var(--sapBrandColor, #0854a0); box-shadow: 0 0 0 2px rgba(8,84,160,0.12); }
    .model-meta { display: flex; gap: 0.375rem; align-items: center; }
    .badge-model { font-size: 0.6875rem; background: #e8f2ff; color: var(--sapBrandColor, #0854a0);
      padding: 2px 8px; border-radius: 1rem; font-weight: 600; }
    .badge-id { font-size: 0.625rem; color: var(--sapContent_LabelColor, #6a6d70); font-family: monospace; }

    /* Swap button */
    .swap-btn { align-self: center; width: 40px; height: 40px; border-radius: 50%;
      background: var(--sapTile_Background, #fff); border: 1px solid var(--sapTile_BorderColor, #e4e4e4);
      cursor: pointer; display: flex; align-items: center; justify-content: center;
      transition: all 0.3s ease; margin-top: 1rem; flex-shrink: 0; }
    .swap-btn:hover:not(:disabled) { background: var(--sapBrandColor, #0854a0); border-color: var(--sapBrandColor, #0854a0); }
    .swap-btn:hover:not(:disabled) .swap-icon { color: #fff; }
    .swap-btn:disabled { opacity: 0.4; cursor: not-allowed; }
    .swap-icon { font-size: 1.125rem; color: var(--sapTextColor, #32363a); transition: transform 0.4s ease, color 0.2s; }
    .swap-btn.spinning .swap-icon { transform: rotate(180deg); }

    /* Empty state */
    .empty-state { text-align: center; padding: 3rem 2rem; background: var(--sapTile_Background, #fff);
      border: 2px dashed var(--sapTile_BorderColor, #e4e4e4); border-radius: 0.75rem;
      margin-bottom: 1.5rem; }
    .empty-icon { font-size: 2.5rem; margin-bottom: 0.75rem; }
    .empty-title { margin: 0 0 0.375rem; font-size: 1rem; font-weight: 700; color: var(--sapTextColor, #32363a); }
    .empty-desc { margin: 0; color: var(--sapContent_LabelColor, #6a6d70); font-size: 0.875rem; }

    /* Prompt bar */
    .prompt-bar { display: flex; gap: 0.75rem; margin-bottom: 1.5rem; }
    .prompt-wrapper { flex: 1; position: relative; display: flex; align-items: center; }
    .prompt-icon { position: absolute; left: 0.75rem; font-size: 1rem; z-index: 1; }
    .prompt-input { width: 100%; padding: 0.75rem 0.75rem 0.75rem 2.25rem;
      border: 1px solid var(--sapTile_BorderColor, #e4e4e4); border-radius: 0.5rem;
      font-size: 0.875rem; transition: border-color 0.2s, box-shadow 0.2s; outline: none; }
    .prompt-input:focus { border-color: var(--sapBrandColor, #0854a0);
      box-shadow: 0 0 0 3px rgba(8,84,160,0.1); }
    .btn-run { padding: 0.75rem 1.5rem; background: var(--sapBrandColor, #0854a0); color: #fff;
      border: none; border-radius: 0.5rem; cursor: pointer; font-weight: 700; font-size: 0.875rem;
      white-space: nowrap; display: flex; align-items: center; gap: 0.5rem;
      transition: background 0.2s, transform 0.1s; }
    .btn-run:hover:not(:disabled) { background: #063d75; transform: translateY(-1px); }
    .btn-run:active:not(:disabled) { transform: translateY(0); }
    .btn-run:disabled { opacity: 0.5; cursor: not-allowed; }
    .spinner { width: 14px; height: 14px; border: 2px solid rgba(255,255,255,0.3);
      border-top-color: #fff; border-radius: 50%; display: inline-block;
      animation: spin 0.8s linear infinite; }
    @keyframes spin { to { transform: rotate(360deg); } }

    /* Verdict card */
    .verdict-card { background: var(--sapTile_Background, #fff); border: 1px solid var(--sapTile_BorderColor, #e4e4e4);
      border-radius: 0.5rem; margin-bottom: 1.5rem; overflow: hidden; }
    .verdict-header { padding: 0.625rem 1rem; background: var(--sapShellColor, #354a5e); color: #fff;
      font-weight: 700; font-size: 0.8125rem; letter-spacing: 0.02em; }
    .verdict-body { padding: 1rem; display: flex; flex-direction: column; gap: 1rem; }
    .verdict-metric { display: flex; flex-direction: column; gap: 0.375rem; }
    .verdict-label { font-size: 0.75rem; font-weight: 600; text-transform: uppercase;
      letter-spacing: 0.04em; color: var(--sapContent_LabelColor, #6a6d70); }
    .verdict-bars { display: flex; flex-direction: column; gap: 0.25rem; }
    .verdict-bar-row { display: flex; align-items: center; gap: 0.5rem; }
    .bar-label { font-size: 0.75rem; font-weight: 700; width: 14px; color: var(--sapTextColor, #32363a); }
    .bar-track { flex: 1; height: 20px; background: var(--sapBackgroundColor, #f5f5f5);
      border-radius: 4px; overflow: hidden; }
    .bar-fill { height: 100%; border-radius: 4px; transition: width 0.6s ease; min-width: 4px; }
    .bar-a { background: linear-gradient(90deg, var(--sapBrandColor, #0854a0), #2979ff); }
    .bar-b { background: linear-gradient(90deg, #e57300, #ff9800); }
    .bar-value { font-size: 0.75rem; font-weight: 600; color: var(--sapContent_LabelColor, #6a6d70);
      min-width: 70px; text-align: right; }
    .bar-winner { color: #2e7d32; }
    .verdict-winner { padding-top: 0.5rem; border-top: 1px solid var(--sapTile_BorderColor, #e4e4e4);
      text-align: center; }
    .verdict-win { font-size: 0.875rem; color: #2e7d32; }
    .verdict-tie { font-size: 0.875rem; color: var(--sapContent_LabelColor, #6a6d70); }

    /* Results */
    .results-grid { display: grid; grid-template-columns: 1fr 1fr; gap: 1rem; margin-bottom: 1.5rem; }
    .result-card { background: var(--sapTile_Background, #fff); border: 1px solid var(--sapTile_BorderColor, #e4e4e4);
      border-radius: 0.5rem; overflow: hidden; transition: border-color 0.3s, box-shadow 0.3s; }
    .result-card.winner { border-color: #4caf50; box-shadow: 0 0 0 2px rgba(76,175,80,0.15); }
    .result-header { display: flex; justify-content: space-between; align-items: center;
      padding: 0.625rem 0.875rem; border-bottom: 1px solid var(--sapTile_BorderColor, #e4e4e4);
      font-size: 0.8125rem; font-weight: 700; }
    .result-header-left { display: flex; align-items: center; gap: 0.5rem; }
    .header-a { background: rgba(8,84,160,0.04); }
    .header-b { background: rgba(229,115,0,0.04); }
    .winner-badge { background: #e8f5e9; color: #2e7d32; padding: 3px 10px; border-radius: 1rem;
      font-size: 0.6875rem; font-weight: 700; animation: fadeScale 0.3s ease; }
    @keyframes fadeScale { from { opacity: 0; transform: scale(0.8); } to { opacity: 1; transform: scale(1); } }
    .result-stats { display: flex; gap: 1rem; padding: 0.375rem 0.875rem;
      background: var(--sapBackgroundColor, #f5f5f5); font-size: 0.6875rem;
      color: var(--sapContent_LabelColor, #6a6d70); border-bottom: 1px solid var(--sapTile_BorderColor, #e4e4e4); }
    .result-sql { margin: 0; padding: 1rem; background: #1e1e2e; color: #a9dc76;
      font-family: 'SFMono-Regular', 'Cascadia Code', Consolas, monospace; font-size: 0.8rem;
      white-space: pre-wrap; word-break: break-all; min-height: 80px; line-height: 1.5; }

    /* Diff section */
    .diff-section { background: var(--sapTile_Background, #fff); border: 1px solid var(--sapTile_BorderColor, #e4e4e4);
      border-radius: 0.5rem; margin-bottom: 1.5rem; overflow: hidden; }
    .diff-header { display: flex; justify-content: space-between; align-items: center;
      padding: 0.625rem 0.875rem; cursor: pointer; font-size: 0.8125rem; font-weight: 700;
      background: var(--sapBackgroundColor, #f5f5f5); user-select: none; }
    .diff-header:hover { background: #ebebeb; }
    .diff-toggle { font-size: 0.6875rem; color: var(--sapBrandColor, #0854a0); font-weight: 600; }
    .diff-body { font-family: 'SFMono-Regular', Consolas, monospace; font-size: 0.75rem;
      max-height: 300px; overflow-y: auto; }
    .diff-line { display: flex; padding: 1px 0.75rem; line-height: 1.6; }
    .diff-add { background: #e6ffed; }
    .diff-remove { background: #ffeef0; }
    .diff-same { background: transparent; }
    .diff-indicator { width: 16px; flex-shrink: 0; color: var(--sapContent_LabelColor, #6a6d70); font-weight: 700; }
    .diff-add .diff-indicator { color: #22863a; }
    .diff-remove .diff-indicator { color: #cb2431; }
    .diff-text { white-space: pre-wrap; word-break: break-all; }

    /* History */
    .history-section { margin-top: 0.5rem; }
    .section-title { font-size: 0.9375rem; font-weight: 700; margin: 0 0 0.75rem;
      display: flex; align-items: center; gap: 0.5rem; }
    .history-count { background: var(--sapBrandColor, #0854a0); color: #fff; font-size: 0.625rem;
      padding: 2px 7px; border-radius: 1rem; font-weight: 700; }
    .history-card { background: var(--sapTile_Background, #fff); border: 1px solid var(--sapTile_BorderColor, #e4e4e4);
      border-radius: 0.5rem; padding: 0.875rem; margin-bottom: 0.625rem;
      transition: box-shadow 0.2s; }
    .history-card:hover { box-shadow: 0 2px 8px rgba(0,0,0,0.05); }
    .history-q { margin: 0 0 0.625rem; font-size: 0.8125rem; font-weight: 600;
      display: flex; align-items: center; gap: 0.5rem; }
    .history-num { background: var(--sapBackgroundColor, #f5f5f5); color: var(--sapContent_LabelColor, #6a6d70);
      font-size: 0.625rem; padding: 2px 6px; border-radius: 3px; font-weight: 700; }
    .history-grid { display: grid; grid-template-columns: 1fr 1fr; gap: 0.75rem; }
    .history-col { display: flex; flex-direction: column; gap: 0.25rem; }
    .history-col-label { font-size: 0.6875rem; font-weight: 700; display: flex; align-items: center; gap: 0.375rem;
      color: var(--sapContent_LabelColor, #6a6d70); }
    .mini-winner { color: #2e7d32; font-weight: 700; font-size: 0.75rem; }
    .history-col pre { margin: 0; background: var(--sapBackgroundColor, #f5f5f5); padding: 0.5rem;
      border-radius: 0.375rem; font-size: 0.75rem; white-space: pre-wrap;
      word-break: break-all; line-height: 1.4; border: 1px solid var(--sapTile_BorderColor, #e4e4e4); }

    /* Animation */
    .fade-in { animation: fadeIn 0.4s ease; }
    @keyframes fadeIn { from { opacity: 0; transform: translateY(8px); } to { opacity: 1; transform: translateY(0); } }
  `]
})
export class CompareComponent implements OnInit {
  private readonly http = inject(HttpClient);
  private readonly toast = inject(ToastService);

  readonly deployedModels = signal<DeployedModel[]>([]);
  readonly loading = signal(false);
  readonly resultA = signal<string | null>(null);
  readonly resultB = signal<string | null>(null);
  readonly history = signal<{ query: string; a: string; b: string }[]>([]);
  readonly showDiff = signal(false);
  readonly swapAnim = signal(false);

  readonly diffLines = computed(() => {
    const a = this.resultA();
    const b = this.resultB();
    if (!a || !b) return [];
    const linesA = a.split('\n');
    const linesB = b.split('\n');
    const result: { type: 'add' | 'remove' | 'same'; text: string }[] = [];
    const max = Math.max(linesA.length, linesB.length);
    for (let i = 0; i < max; i++) {
      const la = i < linesA.length ? linesA[i] : undefined;
      const lb = i < linesB.length ? linesB[i] : undefined;
      if (la === lb) {
        result.push({ type: 'same', text: la ?? '' });
      } else {
        if (la !== undefined) result.push({ type: 'remove', text: la });
        if (lb !== undefined) result.push({ type: 'add', text: lb });
      }
    }
    return result;
  });

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
      }
    });
  }

  modelNameFor(id: string): string {
    return this.deployedModels().find(m => m.id === id)?.model_name ?? id.slice(0, 8);
  }

  swapModels() {
    const tmp = this.modelA;
    this.modelA = this.modelB;
    this.modelB = tmp;
    this.swapAnim.set(true);
    setTimeout(() => this.swapAnim.set(false), 400);
    // Also swap results if present
    const ra = this.resultA();
    const rb = this.resultB();
    if (ra !== null || rb !== null) {
      this.resultA.set(rb);
      this.resultB.set(ra);
    }
  }

  lineCount(text: string): number {
    return text ? text.split('\n').length : 0;
  }

  barWidth(side: 'A' | 'B'): number {
    const a = this.resultA();
    const b = this.resultB();
    if (!a || !b) return 0;
    const max = Math.max(a.length, b.length, 1);
    return side === 'A' ? (a.length / max) * 100 : (b.length / max) * 100;
  }

  lineBarWidth(side: 'A' | 'B'): number {
    const a = this.resultA();
    const b = this.resultB();
    if (!a || !b) return 0;
    const la = this.lineCount(a);
    const lb = this.lineCount(b);
    const max = Math.max(la, lb, 1);
    return side === 'A' ? (la / max) * 100 : (lb / max) * 100;
  }

  runComparison() {
    if (!this.modelA || !this.modelB || !this.prompt.trim()) return;
    this.loading.set(true);
    this.resultA.set(null);
    this.resultB.set(null);
    this.showDiff.set(false);

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
      next: (r) => { this.resultA.set(r.response); doneA = true; check(); },
      error: () => { this.resultA.set('[Error — model did not respond]'); doneA = true; check(); }
    });
    queryB.subscribe({
      next: (r) => {
        this.resultB.set(r.response);
        doneB = true;
        check();
        const ra = this.resultA();
        const rb = this.resultB();
        if (ra !== null && rb !== null) {
          this.history.update(h => [{ query: this.prompt, a: ra, b: rb }, ...h.slice(0, 9)]);
        }
      },
      error: () => { this.resultB.set('[Error — model did not respond]'); doneB = true; check(); }
    });
  }

  isWinner(side: 'A' | 'B'): boolean {
    const a = this.resultA();
    const b = this.resultB();
    if (!a || !b) return false;
    return side === 'A' ? a.length <= b.length : b.length < a.length;
  }
}
