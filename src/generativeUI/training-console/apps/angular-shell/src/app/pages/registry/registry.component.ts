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
        <div class="header-actions">
          <button class="btn-refresh" (click)="load()" [class.spinning]="refreshing()">
            <span class="refresh-icon">↻</span> Refresh
          </button>
        </div>
      </div>

      <!-- Stats -->
      <div class="stats-grid">
        <div class="stat-card">
          <div class="stat-icon">📦</div>
          <div class="stat-info">
            <div class="stat-value">{{ models().length }}</div>
            <div class="stat-label">Total Models</div>
          </div>
        </div>
        <div class="stat-card">
          <div class="stat-icon">✅</div>
          <div class="stat-info">
            <div class="stat-value val-completed">{{ completedCount() }}</div>
            <div class="stat-label">Completed</div>
          </div>
        </div>
        <div class="stat-card">
          <div class="stat-icon">🚀</div>
          <div class="stat-info">
            <div class="stat-value val-deployed">{{ deployedCount() }}</div>
            <div class="stat-label">Deployed</div>
          </div>
        </div>
        <div class="stat-card">
          <div class="stat-icon">🏷️</div>
          <div class="stat-info">
            <div class="stat-value">{{ taggedCount() }}</div>
            <div class="stat-label">Tagged</div>
          </div>
        </div>
      </div>

      <!-- Search & Filter bar -->
      <div class="filter-bar">
        <div class="search-wrapper">
          <span class="search-icon">🔍</span>
          <input class="search-input" [(ngModel)]="searchQuery" (ngModelChange)="applyFilter()"
                 placeholder="Search models by name or ID…" />
          @if (searchQuery) {
            <button class="search-clear" (click)="searchQuery = ''; applyFilter()">✕</button>
          }
        </div>
        <select class="filter-select" [(ngModel)]="filterStatus" (ngModelChange)="applyFilter()">
          <option value="">All Status</option>
          <option value="completed">✅ Completed</option>
          <option value="running">🔄 Running</option>
          <option value="failed">❌ Failed</option>
        </select>
        <label class="checkbox-label">
          <input type="checkbox" [(ngModel)]="showDeployedOnly" (ngModelChange)="applyFilter()" />
          Deployed only
        </label>
        @if (filterTag) {
          <span class="filter-chip" (click)="filterTag = ''; applyFilter()">
            🏷️ {{ filterTag }} <span class="chip-x">✕</span>
          </span>
        }
      </div>

      <!-- Active filters -->
      @if (searchQuery || filterStatus || showDeployedOnly || filterTag) {
        <div class="active-filters">
          <span class="filter-label">{{ filtered().length }} of {{ models().length }} models shown</span>
          <button class="clear-all" (click)="clearFilters()">Clear all filters</button>
        </div>
      }

      <!-- Registry Table -->
      @if (filtered().length) {
        <div class="table-wrapper">
          <table class="data-table">
            <thead>
              <tr>
                <th class="th-sortable" (click)="toggleSort('tag')">
                  Tag / ID
                  <span class="sort-arrow">{{ sortCol === 'tag' ? (sortAsc ? '↑' : '↓') : '' }}</span>
                </th>
                <th class="th-sortable" (click)="toggleSort('model')">
                  Model
                  <span class="sort-arrow">{{ sortCol === 'model' ? (sortAsc ? '↑' : '↓') : '' }}</span>
                </th>
                <th>Status</th>
                <th>Architecture</th>
                <th>Quant</th>
                <th class="th-sortable" (click)="toggleSort('eval')">
                  Eval
                  <span class="sort-arrow">{{ sortCol === 'eval' ? (sortAsc ? '↑' : '↓') : '' }}</span>
                </th>
                <th class="th-sortable" (click)="toggleSort('loss')">
                  Loss (final)
                  <span class="sort-arrow">{{ sortCol === 'loss' ? (sortAsc ? '↑' : '↓') : '' }}</span>
                </th>
                <th class="th-sortable" (click)="toggleSort('created')">
                  Created
                  <span class="sort-arrow">{{ sortCol === 'created' ? (sortAsc ? '↑' : '↓') : '' }}</span>
                </th>
                <th>Actions</th>
              </tr>
            </thead>
            <tbody>
              @for (m of filtered(); track m.id; let idx = $index) {
                <tr [class.row-alt]="idx % 2 === 1" [class.row-deployed]="m.deployed"
                    class="table-row">
                  <td>
                    @if (editingTag() === m.id) {
                      <div class="tag-edit-row">
                        <input class="tag-input" [(ngModel)]="tagDraft"
                               (keyup.enter)="saveTag(m.id)" (keyup.escape)="cancelTag()"
                               placeholder="e.g. production-v2" />
                        <button class="btn-xs btn-save" (click)="saveTag(m.id)">✓</button>
                        <button class="btn-xs" (click)="cancelTag()">✕</button>
                      </div>
                    } @else {
                      <div class="tag-cell" (click)="startTag(m)">
                        @if (m.tag) {
                          <span class="tag-pill" (click)="filterByTag(m.tag!); $event.stopPropagation()">{{ m.tag }}</span>
                        } @else {
                          <span class="tag-placeholder">+ Add tag</span>
                        }
                        <code class="id-code">{{ m.id.slice(0, 8) }}</code>
                      </div>
                    }
                  </td>
                  <td>
                    <div class="model-name-cell">
                      <strong>{{ m.config['model_name'] }}</strong>
                      @if (m.config['model_size']) {
                        <span class="size-badge">{{ m.config['model_size'] }}</span>
                      }
                    </div>
                  </td>
                  <td>
                    <div class="status-cell">
                      <span class="status-badge status-{{ m.status }}"
                            [class.status-pulse]="m.status === 'running'">
                        {{ statusIcon(m.status) }} {{ m.status }}
                      </span>
                      @if (m.deployed) {
                        <span class="deployed-badge">🚀 Live</span>
                      }
                    </div>
                  </td>
                  <td class="text-small">
                    <code>{{ m.config['architecture'] ?? 'transformer' }}</code>
                  </td>
                  <td><code class="text-small">{{ m.config['quant_format'] ?? '—' }}</code></td>
                  <td class="text-small">
                    @if (m.evaluation) {
                      <span class="eval-value">PPL {{ m.evaluation.perplexity }}</span>
                    } @else { <span class="text-muted">—</span> }
                  </td>
                  <td class="text-small">
                    @if (m.history?.length) {
                      <span class="loss-value">{{ m.history[m.history.length - 1].loss.toFixed(4) }}</span>
                    } @else { <span class="text-muted">—</span> }
                  </td>
                  <td class="text-small text-muted">{{ m.created_at | date:'short' }}</td>
                  <td>
                    <div class="actions">
                      @if (m.deployed) {
                        <a [href]="'/training/compare'" class="btn-action btn-compare">⚖ Compare</a>
                        <button class="btn-action btn-undeploy" (click)="undeploy(m)">Undeploy</button>
                      }
                      @if (m.status === 'completed' && !m.deployed) {
                        <button class="btn-action btn-deploy"
                                [class.deploying]="deployingId() === m.id"
                                (click)="confirmDeploy(m)">
                          @if (deployingId() === m.id) {
                            <span class="btn-spinner"></span> Deploying…
                          } @else {
                            🚀 Deploy
                          }
                        </button>
                      }
                      <button class="btn-action btn-expand" (click)="toggleExpand(m.id)"
                              title="Version history">
                        {{ expandedId() === m.id ? '▾' : '▸' }}
                      </button>
                      <button class="btn-action btn-delete" (click)="confirmDelete(m.id)">🗑</button>
                    </div>
                  </td>
                </tr>
                <!-- Expandable version history row -->
                @if (expandedId() === m.id) {
                  <tr class="expand-row">
                    <td [attr.colspan]="9">
                      <div class="version-panel">
                        <div class="version-header">📋 Training History</div>
                        <div class="version-details">
                          <div class="detail-grid">
                            <div class="detail-item">
                              <span class="detail-label">Model</span>
                              <span class="detail-value">{{ m.config['model_name'] }}</span>
                            </div>
                            <div class="detail-item">
                              <span class="detail-label">Created</span>
                              <span class="detail-value">{{ m.created_at | date:'medium' }}</span>
                            </div>
                            <div class="detail-item">
                              <span class="detail-label">Progress</span>
                              <span class="detail-value">{{ m.progress }}%</span>
                            </div>
                            @if (m.evaluation) {
                              <div class="detail-item">
                                <span class="detail-label">Eval Loss</span>
                                <span class="detail-value">{{ m.evaluation.eval_loss.toFixed(4) }}</span>
                              </div>
                              <div class="detail-item">
                                <span class="detail-label">Runtime</span>
                                <span class="detail-value">{{ (m.evaluation.runtime_sec / 60).toFixed(1) }} min</span>
                              </div>
                            }
                          </div>
                          @if (m.history?.length) {
                            <div class="loss-chart">
                              <div class="chart-label">Loss over training steps</div>
                              <div class="chart-bars">
                                @for (h of m.history.slice(-20); track h.step) {
                                  <div class="chart-bar-col" [title]="'Step ' + h.step + ': ' + h.loss.toFixed(4)">
                                    <div class="chart-bar"
                                         [style.height.%]="lossBarHeight(h.loss, m.history)"></div>
                                  </div>
                                }
                              </div>
                            </div>
                          }
                        </div>
                      </div>
                    </td>
                  </tr>
                }
              }
            </tbody>
          </table>
        </div>
      } @else {
        <div class="empty-state">
          <div class="empty-icon">📭</div>
          <p class="empty-title">No Models Found</p>
          @if (searchQuery || filterStatus || showDeployedOnly || filterTag) {
            <p class="empty-desc">No models match your current filters. Try adjusting your search criteria.</p>
            <button class="btn-clear-empty" (click)="clearFilters()">Clear Filters</button>
          } @else {
            <p class="empty-desc">Train your first model to see it appear here.</p>
          }
        </div>
      }

      <!-- Confirm deploy dialog -->
      @if (confirmDeployModel()) {
        <div class="overlay" (click)="confirmDeployModel.set(null)">
          <div class="confirm-dialog" (click)="$event.stopPropagation()">
            <div class="confirm-title">🚀 Deploy Model</div>
            <p class="confirm-text">
              Deploy <strong>{{ confirmDeployModel()!.config['model_name'] }}</strong>
              <code>({{ confirmDeployModel()!.id.slice(0, 8) }})</code> to production?
            </p>
            <div class="confirm-actions">
              <button class="btn-cancel" (click)="confirmDeployModel.set(null)">Cancel</button>
              <button class="btn-confirm" (click)="deploy(confirmDeployModel()!)">Deploy Now</button>
            </div>
          </div>
        </div>
      }

      <!-- Confirm delete dialog -->
      @if (confirmDeleteId()) {
        <div class="overlay" (click)="confirmDeleteId.set(null)">
          <div class="confirm-dialog" (click)="$event.stopPropagation()">
            <div class="confirm-title">🗑 Delete Model</div>
            <p class="confirm-text">
              Remove model <code>{{ confirmDeleteId()!.slice(0, 8) }}</code> from the registry?
              This action cannot be undone.
            </p>
            <div class="confirm-actions">
              <button class="btn-cancel" (click)="confirmDeleteId.set(null)">Cancel</button>
              <button class="btn-confirm btn-danger" (click)="deleteJob(confirmDeleteId()!)">Delete</button>
            </div>
          </div>
        </div>
      }
    </div>
  `,
  styles: [`
    /* Stats */
    .stats-grid { display: grid; grid-template-columns: repeat(4, 1fr); gap: 0.75rem; }

    /* Filter bar */
    .filter-bar { display: flex; align-items: center; gap: 0.75rem; flex-wrap: wrap; }
    .active-filters { display: flex; align-items: center; justify-content: space-between; }

    /* Tag cell */
    .tag-cell { display: flex; flex-direction: column; gap: 3px; cursor: pointer;
      padding: 2px 0; transition: opacity 0.2s; }
    .tag-cell:hover { opacity: 0.8; }
    .id-code { font-size: 0.6875rem; color: var(--sapContent_LabelColor, #6a6d70); }
    .tag-edit-row { display: flex; gap: 0.25rem; align-items: center; }
    .model-name-cell { display: flex; flex-direction: column; gap: 2px; }

    /* Status */
    .status-cell { display: flex; align-items: center; gap: 0.375rem; flex-wrap: wrap; }

    /* Actions */
    .actions { display: flex; gap: 0.25rem; flex-wrap: wrap; align-items: center; }

    /* Details panel */
    .detail-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(140px, 1fr)); gap: 0.5rem;
      padding: 0.5rem 0; }
    .detail-item { display: flex; flex-direction: column; gap: 2px; }
    .loss-chart { margin-top: 0.5rem; }
    .chart-bars { display: flex; align-items: flex-end; gap: 2px; height: 50px;
      background: var(--sapTile_Background, #fff); border-radius: 0.25rem; padding: 4px;
      border: 1px solid var(--sapTile_BorderColor, #e4e4e4); }
    .chart-bar-col { flex: 1; height: 100%; display: flex; align-items: flex-end; }
    .chart-bar { width: 100%; background: linear-gradient(to top, var(--sapBrandColor, #0854a0), #2979ff);
      border-radius: 2px 2px 0 0; min-height: 2px; transition: height 0.3s ease; }
  `]
})
export class RegistryComponent implements OnInit {
  private readonly http = inject(HttpClient);
  private readonly toast = inject(ToastService);

  readonly models = signal<RegistryEntry[]>([]);
  readonly filtered = signal<RegistryEntry[]>([]);
  readonly editingTag = signal<string | null>(null);
  readonly expandedId = signal<string | null>(null);
  readonly deployingId = signal<string | null>(null);
  readonly refreshing = signal(false);
  readonly confirmDeployModel = signal<RegistryEntry | null>(null);
  readonly confirmDeleteId = signal<string | null>(null);

  filterStatus = '';
  showDeployedOnly = false;
  searchQuery = '';
  filterTag = '';
  tagDraft = '';
  sortCol = '';
  sortAsc = true;

  private tags: Record<string, string> = JSON.parse(localStorage.getItem('model_tags') ?? '{}');

  readonly completedCount = () => this.models().filter(m => m.status === 'completed').length;
  readonly deployedCount = () => this.models().filter(m => m.deployed).length;
  readonly taggedCount = () => this.models().filter(m => m.tag).length;

  ngOnInit() { this.load(); }

  load() {
    this.refreshing.set(true);
    this.http.get<RegistryEntry[]>(`${environment.apiBaseUrl}/jobs`).subscribe({
      next: (jobs) => {
        const enriched = jobs.map(j => ({ ...j, tag: this.tags[j.id] }));
        this.models.set(enriched);
        this.applyFilter();
        this.refreshing.set(false);
      },
      error: () => {
        this.toast.error('Failed to load model registry', 'Error');
        this.refreshing.set(false);
      }
    });
  }

  applyFilter() {
    let result = this.models();
    if (this.searchQuery) {
      const q = this.searchQuery.toLowerCase();
      result = result.filter(m =>
        (m.config['model_name'] as string || '').toLowerCase().includes(q) ||
        m.id.toLowerCase().includes(q) ||
        (m.tag || '').toLowerCase().includes(q)
      );
    }
    if (this.filterStatus) result = result.filter(m => m.status === this.filterStatus);
    if (this.showDeployedOnly) result = result.filter(m => m.deployed);
    if (this.filterTag) result = result.filter(m => m.tag === this.filterTag);

    if (this.sortCol) {
      result = [...result].sort((a, b) => {
        let va: string | number = 0;
        let vb: string | number = 0;
        switch (this.sortCol) {
          case 'tag': va = a.tag ?? ''; vb = b.tag ?? ''; break;
          case 'model': va = (a.config['model_name'] as string) ?? ''; vb = (b.config['model_name'] as string) ?? ''; break;
          case 'eval': va = a.evaluation?.perplexity ?? 9999; vb = b.evaluation?.perplexity ?? 9999; break;
          case 'loss': va = a.history?.length ? a.history[a.history.length - 1].loss : 9999;
                       vb = b.history?.length ? b.history[b.history.length - 1].loss : 9999; break;
          case 'created': va = a.created_at; vb = b.created_at; break;
        }
        const cmp = va < vb ? -1 : va > vb ? 1 : 0;
        return this.sortAsc ? cmp : -cmp;
      });
    }
    this.filtered.set(result);
  }

  toggleSort(col: string) {
    if (this.sortCol === col) { this.sortAsc = !this.sortAsc; }
    else { this.sortCol = col; this.sortAsc = true; }
    this.applyFilter();
  }

  clearFilters() {
    this.searchQuery = '';
    this.filterStatus = '';
    this.showDeployedOnly = false;
    this.filterTag = '';
    this.applyFilter();
  }

  filterByTag(tag: string) {
    this.filterTag = tag;
    this.applyFilter();
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

  toggleExpand(id: string) {
    this.expandedId.set(this.expandedId() === id ? null : id);
  }

  statusIcon(status: string): string {
    switch (status) {
      case 'completed': return '✅';
      case 'running': return '🔄';
      case 'failed': return '❌';
      case 'pending': return '⏳';
      default: return '📦';
    }
  }

  statusTagDesign(status: string): string {
    switch (status) {
      case 'completed': return 'Positive';
      case 'running': return 'Critical';
      case 'failed': return 'Negative';
      case 'pending': return 'Information';
      case 'archived': return 'Set2';
      default: return 'Set2';
    }
  }

  onFilterStatusChange(event: Event) {
    this.filterStatus = (event.target as any).selectedOption?.value ?? '';
    this.applyFilter();
  }

  navigateCompare() {
    window.location.href = '/training/compare';
  }

  lossBarHeight(loss: number, history: { step: number; loss: number }[]): number {
    const maxLoss = Math.max(...history.map(h => h.loss), 0.001);
    return Math.max((loss / maxLoss) * 100, 3);
  }

  confirmDeploy(m: RegistryEntry) {
    this.confirmDeployModel.set(m);
  }

  confirmDelete(id: string) {
    this.confirmDeleteId.set(id);
  }

  deploy(m: RegistryEntry) {
    this.confirmDeployModel.set(null);
    this.deployingId.set(m.id);
    this.http.post(`${environment.apiBaseUrl}/jobs/${m.id}/deploy`, {}).subscribe({
      next: () => {
        this.toast.success(`Model ${m.id.slice(0, 8)} deployed`, 'Deployed');
        this.deployingId.set(null);
        this.load();
      },
      error: (e: { error?: { detail?: string } }) => {
        this.toast.error(e?.error?.detail ?? 'Deploy failed', 'Error');
        this.deployingId.set(null);
      }
    });
  }

  undeploy(m: RegistryEntry) {
    this.http.post(`${environment.apiBaseUrl}/jobs/${m.id}/undeploy`, {}).subscribe({
      next: () => {
        this.toast.success(`Model ${m.id.slice(0, 8)} undeployed`, 'Undeployed');
        this.load();
      },
      error: () => this.toast.error('Undeploy failed', 'Error')
    });
  }

  deleteJob(id: string) {
    this.confirmDeleteId.set(null);
    this.http.delete(`${environment.apiBaseUrl}/jobs/${id}`).subscribe({
      next: () => {
        this.toast.success('Job removed from registry', 'Deleted');
        this.load();
      }
    });
  }
}
