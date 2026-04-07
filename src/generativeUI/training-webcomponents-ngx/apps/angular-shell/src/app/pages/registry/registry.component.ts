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

interface RegistryEntry {
  id: string;
  status: string;
  progress: number;
  config: Record<string, unknown>;
  history: { step: number; loss: number }[];
  evaluation?: { perplexity: number; eval_loss: number; runtime_sec: number };
  deployed: boolean;
  created_at: string;
  tag?: string;
}

@Component({
  selector: 'app-registry',
  standalone: true,
  imports: [CommonModule, FormsModule],
  schemas: [CUSTOM_ELEMENTS_SCHEMA],
  changeDetection: ChangeDetectionStrategy.OnPush,
  template: `
    <div class="page-content" role="main" aria-label="Model registry">
      <div class="page-header">
        <h1 class="page-title">{{ i18n.t('registry.title') }}</h1>
        <ui5-button design="Default" (click)="load()" aria-label="Refresh registry">{{ i18n.t('registry.refresh') }}</ui5-button>
      </div>

      <!-- Stats -->
      <div class="stats-grid" style="margin-bottom: 1.5rem;" role="region" aria-label="Registry statistics">
        <div class="stat-card">
          <div class="stat-value">{{ models().length }}</div>
          <div class="stat-label">{{ i18n.t('registry.totalJobs') }}</div>
        </div>
        <div class="stat-card">
          <div class="stat-value" [style.color]="'var(--sapPositiveColor, #4caf50)'">{{ completedCount() }}</div>
          <div class="stat-label">{{ i18n.t('registry.completed') }}</div>
        </div>
        <div class="stat-card">
          <div class="stat-value" [style.color]="'var(--sapBrandColor, #0854a0)'">{{ deployedCount() }}</div>
          <div class="stat-label">{{ i18n.t('registry.deployed') }}</div>
        </div>
        <div class="stat-card">
          <div class="stat-value">{{ taggedCount() }}</div>
          <div class="stat-label">{{ i18n.t('registry.tagged') }}</div>
        </div>
      </div>

      @if (loading) {
        <div style="display: flex; justify-content: center; padding: 2rem;" role="status" aria-live="polite">
          <ui5-busy-indicator active size="M"></ui5-busy-indicator>
        </div>
      }

      <!-- Filter bar -->
      <div class="filter-bar" role="search" aria-label="Filter models">
        <select class="filter-select" [(ngModel)]="filterStatus" (ngModelChange)="applyFilter()" aria-label="Filter by status">
          <option value="">{{ i18n.t('registry.allStatus') }}</option>
          <option value="completed">{{ i18n.t('registry.completed') }}</option>
          <option value="running">{{ i18n.t('registry.running') }}</option>
          <option value="failed">{{ i18n.t('registry.failed') }}</option>
        </select>
        <label style="display: flex; align-items: center; gap: 0.4rem; font-size: 0.875rem;">
          <input type="checkbox" [(ngModel)]="showDeployedOnly" (ngModelChange)="applyFilter()" />
          {{ i18n.t('registry.deployedOnly') }}
        </label>
      </div>

      <!-- Registry Table -->
      @if (filtered().length) {
        <div class="table-wrapper">
          <table class="data-table" aria-label="Registered models">
            <thead>
              <tr>
                <th>{{ i18n.t('registry.tagId') }}</th>
                <th>{{ i18n.t('registry.model') }}</th>
                <th>{{ i18n.t('registry.status') }}</th>
                <th>{{ i18n.t('registry.quant') }}</th>
                <th>{{ i18n.t('registry.eval') }}</th>
                <th>{{ i18n.t('registry.lossFinal') }}</th>
                <th>{{ i18n.t('registry.created') }}</th>
                <th>{{ i18n.t('registry.actions') }}</th>
              </tr>
            </thead>
            <tbody>
              @for (m of filtered(); track m.id) {
                <tr>
                  <td>
                    @if (editingTag() === m.id) {
                      <div style="display: flex; gap: 0.3rem;">
                        <input class="tag-input" [(ngModel)]="tagDraft"
                               (keyup.enter)="saveTag(m.id)" (keyup.escape)="cancelTag()" />
                        <ui5-button design="Emphasized" (click)="saveTag(m.id)">✓</ui5-button>
                        <ui5-button design="Transparent" (click)="cancelTag()">✕</ui5-button>
                      </div>
                    } @else {
                      <div class="tag-cell" (click)="startTag(m)">
                        @if (m.tag) {
                          <span class="tag-badge">{{ m.tag }}</span>
                        } @else {
                          <span class="tag-placeholder">{{ i18n.t('registry.addTag') }}</span>
                        }
                        <code class="id-code">{{ m.id.slice(0, 8) }}</code>
                      </div>
                    }
                  </td>
                  <td class="text-small"><strong>{{ m.config['model_name'] }}</strong></td>
                  <td>
                    <span class="status-badge status-{{ m.status }}">{{ m.status }}</span>
                    @if (m.deployed) { <span class="deployed-badge">{{ i18n.t('registry.live') }}</span> }
                  </td>
                  <td><code class="text-small">{{ m.config['quant_format'] ?? '—' }}</code></td>
                  <td class="text-small">
                    @if (m.evaluation) {
                      <span class="eval-perplexity">PPL {{ m.evaluation.perplexity }}</span>
                    } @else { <span class="text-muted">—</span> }
                  </td>
                  <td class="text-small">
                    @if (m.history?.length) {
                      {{ m.history[m.history.length - 1].loss.toFixed(4) }}
                    } @else { <span class="text-muted">—</span> }
                  </td>
                  <td class="text-small text-muted">{{ m.created_at | date:'short' }}</td>
                  <td>
                    <div class="actions">
                      @if (m.deployed) {
                        <a [href]="'/training/compare'" class="btn-xs btn-compare">{{ i18n.t('registry.compare') }}</a>
                      }
                      @if (m.status === 'completed' && !m.deployed) {
                        <ui5-button design="Emphasized" (click)="deploy(m)">{{ i18n.t('registry.deploy') }}</ui5-button>
                      }
                      <ui5-button design="Negative" (click)="deleteJob(m.id)">{{ i18n.t('registry.delete') }}</ui5-button>
                    </div>
                  </td>
                </tr>
              }
            </tbody>
          </table>
        </div>
      } @else {
        <div class="empty-state">
          <p class="text-muted">{{ i18n.t('registry.noMatch') }}</p>
        </div>
      }
    </div>
  `,
  styles: [`
    .btn-refresh { padding: 0.375rem 0.875rem; background: var(--sapButton_Emphasized_Background, #0854a0); color: var(--sapButton_Emphasized_TextColor, #fff); border: none;
      border-radius: 0.25rem; cursor: pointer; font-size: 0.875rem;
      &:hover { background: var(--sapButton_Emphasized_Hover_Background, #063d75); } }
    .filter-bar { display: flex; align-items: center; gap: 1rem; margin-bottom: 1rem; }
    .filter-select { padding: 0.375rem 0.625rem; border: 1px solid var(--sapField_BorderColor, #89919a); border-radius: 0.25rem;
      font-size: 0.875rem; background: var(--sapTile_Background, #fff); }
    .table-wrapper { overflow-x: auto; }
    .data-table { width: 100%; border-collapse: collapse; background: var(--sapTile_Background, #fff);
      border: 1px solid var(--sapList_BorderColor, #e4e4e4); border-radius: 0.5rem; overflow: hidden;
      th { padding: 0.5rem 0.75rem; background: var(--sapList_HeaderBackground, #f5f5f5); text-align: start; font-weight: 600;
        font-size: 0.7rem; text-transform: uppercase; letter-spacing: 0.04em; color: var(--sapContent_LabelColor, #6a6d70);
        border-bottom: 1px solid var(--sapList_BorderColor, #e4e4e4); }
      td { padding: 0.5rem 0.75rem; border-bottom: 1px solid var(--sapList_BorderColor, #e4e4e4); vertical-align: middle; }
      tr:last-child td { border-bottom: none; }
      tr:hover td { background: var(--sapList_HeaderBackground, #f5f5f5); }
    }
    .tag-cell { display: flex; flex-direction: column; gap: 2px; cursor: pointer; }
    .tag-badge { background: var(--sapInformationBackground, #e8eaf6); color: var(--sapInformativeColor, #283593); padding: 1px 6px; border-radius: 3px;
      font-size: 0.7rem; font-weight: 600; align-self: flex-start; }
    .tag-placeholder { color: var(--sapContent_LabelColor, #bbb); font-size: 0.7rem; font-style: italic; }
    .id-code { font-size: 0.7rem; color: var(--sapContent_LabelColor, #6a6d70); }
    .tag-input { padding: 2px 6px; font-size: 0.75rem; border: 1px solid var(--sapField_BorderColor, #89919a);
      border-radius: 0.2rem; width: 90px; }
    .deployed-badge { font-size: 0.7rem; margin-inline-start: 4px; color: var(--sapPositiveColor, #2e7d32); font-weight: 600; }
    .status-badge { padding: 2px 8px; border-radius: 1rem; font-size: 0.7rem; font-weight: 600;
      &.status-completed { background: var(--sapSuccessBackground, #e8f5e9); color: var(--sapPositiveColor, #2e7d32); }
      &.status-running { background: var(--sapInformationBackground, #e3f2fd); color: var(--sapInformativeColor, #1565c0); }
      &.status-failed { background: var(--sapErrorBackground, #ffebee); color: var(--sapNegativeColor, #c62828); }
      &.status-pending { background: var(--sapWarningBackground, #fff8e1); color: var(--sapCriticalColor, #f57f17); } }
    .actions { display: flex; gap: 0.3rem; flex-wrap: wrap; }
    .btn-xs { padding: 2px 8px; border-radius: 0.2rem; font-size: 0.7rem; cursor: pointer;
      border: 1px solid transparent; background: var(--sapList_HeaderBackground, #f5f5f5); color: var(--sapTextColor, #32363a);
      &:hover { background: var(--sapButton_Hover_Background, #e0e0e0); }
      &.btn-save { background: var(--sapSuccessBackground, #e8f5e9); color: var(--sapPositiveColor, #2e7d32); border-color: var(--sapPositiveBorderColor, #a5d6a7); }
      &.btn-compare { background: var(--sapInformationBackground, #e3f2fd); color: var(--sapInformativeColor, #1565c0); text-decoration: none; display: inline-flex; align-items: center; }
      &.btn-deploy { background: var(--sapSuccessBackground, #e8f5e9); color: var(--sapPositiveColor, #2e7d32); }
      &.btn-delete { background: var(--sapErrorBackground, #ffebee); color: var(--sapNegativeColor, #c62828); } }
    .empty-state { background: var(--sapTile_Background, #fff); border: 1px dashed var(--sapList_BorderColor, #e4e4e4); border-radius: 0.5rem; padding: 2rem;
      text-align: center; }
    .eval-perplexity { color: var(--sapPositiveColor, #2e7d32); font-weight: 600; }

    @media (max-width: 768px) {
      .filter-bar { flex-direction: column; align-items: stretch; }
      .stats-grid { grid-template-columns: repeat(2, 1fr); }
    }
  `]
})
export class RegistryComponent implements OnInit {
  private readonly http = inject(HttpClient);
  private readonly toast = inject(ToastService);
  readonly i18n = inject(I18nService);

  readonly models = signal<RegistryEntry[]>([]);
  readonly filtered = signal<RegistryEntry[]>([]);
  readonly editingTag = signal<string | null>(null);

  filterStatus = '';
  showDeployedOnly = false;
  tagDraft = '';

  // Local tag store (persists in localStorage)
  private tags: Record<string, string> = JSON.parse(localStorage.getItem('model_tags') ?? '{}');

  readonly completedCount = () => this.models().filter(m => m.status === 'completed').length;
  readonly deployedCount = () => this.models().filter(m => m.deployed).length;
  readonly taggedCount = () => this.models().filter(m => m.tag).length;

  loading = true;

  ngOnInit() { this.load(); }

  load() {
    this.loading = true;
    this.http.get<RegistryEntry[]>(`${environment.apiBaseUrl}/jobs`).subscribe({
      next: (jobs) => {
        this.tags = JSON.parse(localStorage.getItem('model_tags') ?? '{}');
        const enriched = jobs.map(j => ({ ...j, tag: this.tags[j.id] }));
        this.models.set(enriched);
        this.loading = false;
        this.applyFilter();
      },
      error: () => { this.loading = false; this.toast.error(this.i18n.t('registry.loadFailed'), this.i18n.t('common.error')); }
    });
  }

  applyFilter() {
    let result = this.models();
    if (this.filterStatus) result = result.filter(m => m.status === this.filterStatus);
    if (this.showDeployedOnly) result = result.filter(m => m.deployed);
    this.filtered.set(result);
  }

  startTag(m: RegistryEntry) {
    this.tagDraft = m.tag ?? '';
    this.editingTag.set(m.id);
  }

  saveTag(id: string) {
    this.tags[id] = this.tagDraft.trim();
    localStorage.setItem('model_tags', JSON.stringify(this.tags));
    this.models.update(ms => ms.map(m => m.id === id ? { ...m, tag: this.tags[id] || undefined } : m));
    this.applyFilter();
    this.editingTag.set(null);
    this.toast.success(this.i18n.t('registry.tagSaved', { tag: this.tags[id] }), this.i18n.t('registry.title'));
  }

  cancelTag() { this.editingTag.set(null); }

  deploy(m: RegistryEntry) {
    this.http.post(`${environment.apiBaseUrl}/jobs/${m.id}/deploy`, {}).subscribe({
      next: () => {
        this.toast.success(this.i18n.t('registry.modelDeployed', { id: m.id.slice(0, 8) }), this.i18n.t('registry.deployed'));
        this.load();
      },
      error: (e: { error?: { detail?: string } }) =>
        this.toast.error(e?.error?.detail ?? this.i18n.t('registry.deployFailed'), this.i18n.t('common.error'))
    });
  }

  deleteJob(id: string) {
    this.http.delete(`${environment.apiBaseUrl}/jobs/${id}`).subscribe({
      next: () => {
        this.toast.success(this.i18n.t('registry.jobRemoved'), this.i18n.t('common.delete'));
        this.load();
      }
    });
  }
}
