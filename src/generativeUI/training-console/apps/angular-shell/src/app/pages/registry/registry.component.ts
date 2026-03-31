import {
  Component, CUSTOM_ELEMENTS_SCHEMA, ChangeDetectionStrategy,
  signal, inject, OnInit
} from '@angular/core';
import { CommonModule } from '@angular/common';
import { FormsModule } from '@angular/forms';
import { HttpClient } from '@angular/common/http';
import { ToastService } from '../../services/toast.service';
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
    <div class="page-content">
      <div class="page-header">
        <h1 class="page-title">Model Registry</h1>
        <button class="btn-refresh" (click)="load()">↻ Refresh</button>
      </div>

      <!-- Stats -->
      <div class="stats-grid" style="margin-bottom: 1.5rem;">
        <div class="stat-card">
          <div class="stat-value">{{ models().length }}</div>
          <div class="stat-label">Total Jobs</div>
        </div>
        <div class="stat-card">
          <div class="stat-value" style="color: #4caf50;">{{ completedCount() }}</div>
          <div class="stat-label">Completed</div>
        </div>
        <div class="stat-card">
          <div class="stat-value" style="color: #0854a0;">{{ deployedCount() }}</div>
          <div class="stat-label">Deployed</div>
        </div>
        <div class="stat-card">
          <div class="stat-value">{{ taggedCount() }}</div>
          <div class="stat-label">Tagged</div>
        </div>
      </div>

      <!-- Filter bar -->
      <div class="filter-bar">
        <select class="filter-select" [(ngModel)]="filterStatus" (ngModelChange)="applyFilter()">
          <option value="">All Status</option>
          <option value="completed">Completed</option>
          <option value="running">Running</option>
          <option value="failed">Failed</option>
        </select>
        <label style="display: flex; align-items: center; gap: 0.4rem; font-size: 0.875rem;">
          <input type="checkbox" [(ngModel)]="showDeployedOnly" (ngModelChange)="applyFilter()" />
          Deployed only
        </label>
      </div>

      <!-- Registry Table -->
      @if (filtered().length) {
        <div class="table-wrapper">
          <table class="data-table">
            <thead>
              <tr>
                <th>Tag / ID</th>
                <th>Model</th>
                <th>Status</th>
                <th>Quant</th>
                <th>Eval</th>
                <th>Loss (final)</th>
                <th>Created</th>
                <th>Actions</th>
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
                        <button class="btn-xs btn-save" (click)="saveTag(m.id)">✓</button>
                        <button class="btn-xs" (click)="cancelTag()">✕</button>
                      </div>
                    } @else {
                      <div class="tag-cell" (click)="startTag(m)">
                        @if (m.tag) {
                          <span class="tag-badge">{{ m.tag }}</span>
                        } @else {
                          <span class="tag-placeholder">+ tag</span>
                        }
                        <code class="id-code">{{ m.id.slice(0, 8) }}</code>
                      </div>
                    }
                  </td>
                  <td class="text-small"><strong>{{ m.config['model_name'] }}</strong></td>
                  <td>
                    <span class="status-badge status-{{ m.status }}">{{ m.status }}</span>
                    @if (m.deployed) { <span class="deployed-badge">🚀 Live</span> }
                  </td>
                  <td><code class="text-small">{{ m.config['quant_format'] ?? '—' }}</code></td>
                  <td class="text-small">
                    @if (m.evaluation) {
                      <span style="color: #2e7d32; font-weight: 600;">PPL {{ m.evaluation.perplexity }}</span>
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
                        <a [href]="'/training/compare'" class="btn-xs btn-compare">⚖ Compare</a>
                      }
                      @if (m.status === 'completed' && !m.deployed) {
                        <button class="btn-xs btn-deploy" (click)="deploy(m)">🚀 Deploy</button>
                      }
                      <button class="btn-xs btn-delete" (click)="deleteJob(m.id)">🗑</button>
                    </div>
                  </td>
                </tr>
              }
            </tbody>
          </table>
        </div>
      } @else {
        <div class="empty-state">
          <p class="text-muted">No training jobs match the current filter.</p>
        </div>
      }
    </div>
  `,
  styles: [`
    .btn-refresh { padding: 0.375rem 0.875rem; background: #0854a0; color: #fff; border: none;
      border-radius: 0.25rem; cursor: pointer; font-size: 0.875rem;
      &:hover { background: #063d75; } }
    .filter-bar { display: flex; align-items: center; gap: 1rem; margin-bottom: 1rem; }
    .filter-select { padding: 0.375rem 0.625rem; border: 1px solid #89919a; border-radius: 0.25rem;
      font-size: 0.875rem; background: #fff; }
    .table-wrapper { overflow-x: auto; }
    .data-table { width: 100%; border-collapse: collapse; background: #fff;
      border: 1px solid #e4e4e4; border-radius: 0.5rem; overflow: hidden;
      th { padding: 0.5rem 0.75rem; background: #f5f5f5; text-align: left; font-weight: 600;
        font-size: 0.7rem; text-transform: uppercase; letter-spacing: 0.04em; color: #6a6d70;
        border-bottom: 1px solid #e4e4e4; }
      td { padding: 0.5rem 0.75rem; border-bottom: 1px solid #e4e4e4; vertical-align: middle; }
      tr:last-child td { border-bottom: none; }
      tr:hover td { background: #f5f5f5; }
    }
    .tag-cell { display: flex; flex-direction: column; gap: 2px; cursor: pointer; }
    .tag-badge { background: #e8eaf6; color: #283593; padding: 1px 6px; border-radius: 3px;
      font-size: 0.7rem; font-weight: 600; align-self: flex-start; }
    .tag-placeholder { color: #bbb; font-size: 0.7rem; font-style: italic; }
    .id-code { font-size: 0.7rem; color: #6a6d70; }
    .tag-input { padding: 2px 6px; font-size: 0.75rem; border: 1px solid #89919a;
      border-radius: 0.2rem; width: 90px; }
    .deployed-badge { font-size: 0.7rem; margin-left: 4px; }
    .status-badge { padding: 2px 8px; border-radius: 1rem; font-size: 0.7rem; font-weight: 600;
      &.status-completed { background: #e8f5e9; color: #2e7d32; }
      &.status-running { background: #e3f2fd; color: #1565c0; }
      &.status-failed { background: #ffebee; color: #c62828; }
      &.status-pending { background: #fff8e1; color: #f57f17; } }
    .actions { display: flex; gap: 0.3rem; flex-wrap: wrap; }
    .btn-xs { padding: 2px 8px; border-radius: 0.2rem; font-size: 0.7rem; cursor: pointer;
      border: 1px solid transparent; background: #f5f5f5; color: #333;
      &:hover { background: #e0e0e0; }
      &.btn-save { background: #e8f5e9; color: #2e7d32; border-color: #a5d6a7; }
      &.btn-compare { background: #e3f2fd; color: #1565c0; text-decoration: none; display: inline-flex; align-items: center; }
      &.btn-deploy { background: #e8f5e9; color: #2e7d32; }
      &.btn-delete { background: #ffebee; color: #c62828; } }
    .empty-state { background: #fff; border: 1px dashed #e4e4e4; border-radius: 0.5rem; padding: 2rem;
      text-align: center; }
  `]
})
export class RegistryComponent implements OnInit {
  private readonly http = inject(HttpClient);
  private readonly toast = inject(ToastService);

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

  ngOnInit() { this.load(); }

  load() {
    this.http.get<RegistryEntry[]>(`${environment.apiBaseUrl}/jobs`).subscribe({
      next: (jobs) => {
        const enriched = jobs.map(j => ({ ...j, tag: this.tags[j.id] }));
        this.models.set(enriched);
        this.applyFilter();
      },
      error: () => this.toast.error('Failed to load model registry', 'Error')
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
    this.toast.success(`Tag saved: "${this.tags[id]}"`, 'Registry');
  }

  cancelTag() { this.editingTag.set(null); }

  deploy(m: RegistryEntry) {
    this.http.post(`${environment.apiBaseUrl}/jobs/${m.id}/deploy`, {}).subscribe({
      next: () => {
        this.toast.success(`Model ${m.id.slice(0, 8)} deployed`, 'Deployed');
        this.load();
      },
      error: (e: { error?: { detail?: string } }) =>
        this.toast.error(e?.error?.detail ?? 'Deploy failed', 'Error')
    });
  }

  deleteJob(id: string) {
    this.http.delete(`${environment.apiBaseUrl}/jobs/${id}`).subscribe({
      next: () => {
        this.toast.success('Job removed from registry', 'Deleted');
        this.load();
      }
    });
  }
}
