import {
  Component, ChangeDetectionStrategy,
  signal, inject, OnInit
} from '@angular/core';
import { CommonModule } from '@angular/common';
import { Ui5TrainingComponentsModule } from '../../shared/ui5-training-components.module';
import { FormsModule } from '@angular/forms';
import { HttpClient } from '@angular/common/http';
import { RouterLink } from '@angular/router';
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
  imports: [CommonModule, Ui5TrainingComponentsModule, FormsModule, RouterLink],
  changeDetection: ChangeDetectionStrategy.OnPush,
  template: `
    <div class="page-content" role="main" aria-label="Model registry">
      <ui5-breadcrumbs>
        <ui5-breadcrumbs-item href="/dashboard" text="Home"></ui5-breadcrumbs-item>
        <ui5-breadcrumbs-item text="Registry"></ui5-breadcrumbs-item>
      </ui5-breadcrumbs>
      <div class="page-header">
        <ui5-title level="H3">{{ i18n.t('registry.title') }}</ui5-title>
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
        <ui5-select accessible-name="Filter by status" (change)="onFilterStatusChange($event)">
          <ui5-option value="" [attr.selected]="!filterStatus ? true : null">{{ i18n.t('registry.allStatus') }}</ui5-option>
          <ui5-option value="completed" [attr.selected]="filterStatus === 'completed' ? true : null">{{ i18n.t('registry.completed') }}</ui5-option>
          <ui5-option value="running" [attr.selected]="filterStatus === 'running' ? true : null">{{ i18n.t('registry.running') }}</ui5-option>
          <ui5-option value="failed" [attr.selected]="filterStatus === 'failed' ? true : null">{{ i18n.t('registry.failed') }}</ui5-option>
        </ui5-select>
        <ui5-checkbox [text]="i18n.t('registry.deployedOnly')" [checked]="showDeployedOnly" (change)="showDeployedOnly = !showDeployedOnly; applyFilter()"></ui5-checkbox>
      </div>

      <!-- Registry Table -->
      @if (filtered().length) {
        <ui5-table accessible-name="Registered models">
          <ui5-table-header-row slot="headerRow">
            <ui5-table-header-cell>{{ i18n.t('registry.tagId') }}</ui5-table-header-cell>
            <ui5-table-header-cell>{{ i18n.t('registry.model') }}</ui5-table-header-cell>
            <ui5-table-header-cell>{{ i18n.t('registry.status') }}</ui5-table-header-cell>
            <ui5-table-header-cell>{{ i18n.t('registry.quant') }}</ui5-table-header-cell>
            <ui5-table-header-cell>{{ i18n.t('registry.eval') }}</ui5-table-header-cell>
            <ui5-table-header-cell>{{ i18n.t('registry.lossFinal') }}</ui5-table-header-cell>
            <ui5-table-header-cell>{{ i18n.t('registry.created') }}</ui5-table-header-cell>
            <ui5-table-header-cell>{{ i18n.t('registry.actions') }}</ui5-table-header-cell>
          </ui5-table-header-row>
          @for (m of filtered(); track m.id) {
            <ui5-table-row>
              <ui5-table-cell>
                @if (editingTag() === m.id) {
                  <div style="display: flex; gap: 0.3rem;">
                    <ui5-input [value]="tagDraft" (input)="tagDraft = $any($event).target.value"
                               (keydown.enter)="saveTag(m.id)" (keydown.escape)="cancelTag()"></ui5-input>
                    <ui5-button design="Emphasized" (click)="saveTag(m.id)">✓</ui5-button>
                    <ui5-button design="Transparent" (click)="cancelTag()">✕</ui5-button>
                  </div>
                } @else {
                  <div class="tag-cell" (click)="startTag(m)">
                    @if (m.tag) {
                      <ui5-tag design="Set2" color-scheme="6">{{ m.tag }}</ui5-tag>
                    } @else {
                      <span class="tag-placeholder">{{ i18n.t('registry.addTag') }}</span>
                    }
                    <code class="id-code">{{ m.id.slice(0, 8) }}</code>
                  </div>
                }
              </ui5-table-cell>
              <ui5-table-cell><strong>{{ m.config['model_name'] }}</strong></ui5-table-cell>
              <ui5-table-cell>
                <ui5-tag [attr.color-scheme]="m.status === 'completed' ? '8' : m.status === 'running' ? '6' : m.status === 'failed' ? '2' : '1'">{{ m.status }}</ui5-tag>
                @if (m.deployed) { <ui5-tag color-scheme="8">{{ i18n.t('registry.live') }}</ui5-tag> }
              </ui5-table-cell>
              <ui5-table-cell><code>{{ m.config['quant_format'] ?? '—' }}</code></ui5-table-cell>
              <ui5-table-cell>
                @if (m.evaluation) {
                  <ui5-tag color-scheme="8">PPL {{ m.evaluation.perplexity }}</ui5-tag>
                } @else { <span class="text-muted">—</span> }
              </ui5-table-cell>
              <ui5-table-cell>
                @if (m.history?.length) {
                  {{ m.history[m.history.length - 1].loss.toFixed(4) }}
                } @else { <span class="text-muted">—</span> }
              </ui5-table-cell>
              <ui5-table-cell>{{ m.created_at | date:'short' }}</ui5-table-cell>
              <ui5-table-cell>
                <div class="actions">
                  @if (m.deployed) {
                    <a [routerLink]="['/compare']" class="btn-xs btn-compare">{{ i18n.t('registry.compare') }}</a>
                  }
                  @if (m.status === 'completed' && !m.deployed) {
                    <ui5-button design="Emphasized" (click)="deploy(m)">{{ i18n.t('registry.deploy') }}</ui5-button>
                  }
                  <ui5-button design="Negative" (click)="deleteJob(m.id)">{{ i18n.t('registry.delete') }}</ui5-button>
                </div>
              </ui5-table-cell>
            </ui5-table-row>
          }
        </ui5-table>
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

  onFilterStatusChange(event: any): void {
    this.filterStatus = event.detail?.selectedOption?.value ?? '';
    this.applyFilter();
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
