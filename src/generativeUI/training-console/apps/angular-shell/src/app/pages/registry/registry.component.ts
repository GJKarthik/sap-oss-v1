import {
  Component, CUSTOM_ELEMENTS_SCHEMA, ChangeDetectionStrategy,
  signal, inject, OnInit
} from '@angular/core';
import { CommonModule } from '@angular/common';
import { FormsModule } from '@angular/forms';
import { HttpClient } from '@angular/common/http';
import { Ui5WebcomponentsModule } from '@ui5/webcomponents-ngx';
import '@ui5/webcomponents-icons/dist/AllIcons.js';
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
  imports: [CommonModule, FormsModule, Ui5WebcomponentsModule],
  schemas: [CUSTOM_ELEMENTS_SCHEMA],
  changeDetection: ChangeDetectionStrategy.OnPush,
  template: `
    <div class="page-content">
      <div class="page-header">
        <h1 class="page-title">Model Registry</h1>
        <div class="header-actions">
          <ui5-button icon="refresh" design="Transparent" (click)="load()">
            Refresh
          </ui5-button>
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
        <ui5-input placeholder="Search models by name or ID…"
                   [value]="searchQuery"
                   (input)="onSearchInput($event)"
                   show-clear-icon
                   style="flex: 1; min-width: 200px;">
          <ui5-icon slot="icon" name="search"></ui5-icon>
        </ui5-input>
        <ui5-select (change)="onFilterStatusChange($event)" style="min-width: 140px;">
          <ui5-option value="" [selected]="!filterStatus">All Status</ui5-option>
          <ui5-option value="completed" [selected]="filterStatus === 'completed'">✅ Completed</ui5-option>
          <ui5-option value="running" [selected]="filterStatus === 'running'">🔄 Running</ui5-option>
          <ui5-option value="failed" [selected]="filterStatus === 'failed'">❌ Failed</ui5-option>
        </ui5-select>
        <ui5-checkbox text="Deployed only" [checked]="showDeployedOnly"
                      (change)="showDeployedOnly = !showDeployedOnly; applyFilter()"></ui5-checkbox>
        @if (filterTag) {
          <ui5-tag design="Set2" (click)="filterTag = ''; applyFilter()" interactive>
            🏷️ {{ filterTag }} ✕
          </ui5-tag>
        }
      </div>

      <!-- Active filters -->
      @if (searchQuery || filterStatus || showDeployedOnly || filterTag) {
        <div class="active-filters">
          <span class="filter-label">{{ filtered().length }} of {{ models().length }} models shown</span>
          <ui5-button design="Transparent" (click)="clearFilters()">Clear all filters</ui5-button>
        </div>
      }

      <!-- Registry Table -->
      @if (filtered().length) {
        <div class="table-wrapper">
          <ui5-table>
            <ui5-table-header-row slot="headerRow">
              <ui5-table-header-cell><span (click)="toggleSort('tag')" style="cursor:pointer">Tag / ID {{ sortCol === 'tag' ? (sortAsc ? '↑' : '↓') : '' }}</span></ui5-table-header-cell>
              <ui5-table-header-cell><span (click)="toggleSort('model')" style="cursor:pointer">Model {{ sortCol === 'model' ? (sortAsc ? '↑' : '↓') : '' }}</span></ui5-table-header-cell>
              <ui5-table-header-cell>Status</ui5-table-header-cell>
              <ui5-table-header-cell>Architecture</ui5-table-header-cell>
              <ui5-table-header-cell>Quant</ui5-table-header-cell>
              <ui5-table-header-cell><span (click)="toggleSort('eval')" style="cursor:pointer">Eval {{ sortCol === 'eval' ? (sortAsc ? '↑' : '↓') : '' }}</span></ui5-table-header-cell>
              <ui5-table-header-cell><span (click)="toggleSort('loss')" style="cursor:pointer">Loss (final) {{ sortCol === 'loss' ? (sortAsc ? '↑' : '↓') : '' }}</span></ui5-table-header-cell>
              <ui5-table-header-cell><span (click)="toggleSort('created')" style="cursor:pointer">Created {{ sortCol === 'created' ? (sortAsc ? '↑' : '↓') : '' }}</span></ui5-table-header-cell>
              <ui5-table-header-cell>Actions</ui5-table-header-cell>
            </ui5-table-header-row>
            @for (m of filtered(); track m.id) {
              <ui5-table-row>
                <ui5-table-cell>
                  @if (editingTag() === m.id) {
                    <div class="tag-edit-row">
                      <input class="tag-input" [(ngModel)]="tagDraft"
                             (keyup.enter)="saveTag(m.id)" (keyup.escape)="cancelTag()"
                             placeholder="e.g. production-v2" />
                      <ui5-button design="Positive" (click)="saveTag(m.id)">✓</ui5-button>
                      <ui5-button design="Transparent" (click)="cancelTag()">✕</ui5-button>
                    </div>
                  } @else {
                    <div class="tag-cell" (click)="startTag(m)">
                      @if (m.tag) {
                        <ui5-tag design="Set2" interactive (click)="filterByTag(m.tag!); $event.stopPropagation()">{{ m.tag }}</ui5-tag>
                      } @else {
                        <span class="tag-placeholder">+ Add tag</span>
                      }
                      <code class="id-code">{{ m.id.slice(0, 8) }}</code>
                    </div>
                  }
                </ui5-table-cell>
                <ui5-table-cell>
                  <div class="model-name-cell">
                    <strong>{{ m.config['model_name'] }}</strong>
                    @if (m.config['model_size']) {
                      <ui5-tag design="Set2">{{ m.config['model_size'] }}</ui5-tag>
                    }
                  </div>
                </ui5-table-cell>
                <ui5-table-cell>
                  <div class="status-cell">
                    <ui5-tag [design]="statusTagDesign(m.status)">
                      {{ statusIcon(m.status) }} {{ m.status }}
                    </ui5-tag>
                    @if (m.deployed) {
                      <ui5-tag design="Positive">🚀 Live</ui5-tag>
                    }
                  </div>
                </ui5-table-cell>
                <ui5-table-cell><code>{{ m.config['architecture'] ?? 'transformer' }}</code></ui5-table-cell>
                <ui5-table-cell><code>{{ m.config['quant_format'] ?? '—' }}</code></ui5-table-cell>
                <ui5-table-cell>
                  @if (m.evaluation) {
                    <span class="eval-value">PPL {{ m.evaluation.perplexity }}</span>
                  } @else { <span class="text-muted">—</span> }
                </ui5-table-cell>
                <ui5-table-cell>
                  @if (m.history?.length) {
                    <span class="loss-value">{{ m.history[m.history.length - 1].loss.toFixed(4) }}</span>
                  } @else { <span class="text-muted">—</span> }
                </ui5-table-cell>
                <ui5-table-cell>{{ m.created_at | date:'short' }}</ui5-table-cell>
                <ui5-table-cell>
                  <div class="actions">
                    @if (m.deployed) {
                      <ui5-button design="Transparent" icon="compare" (click)="navigateCompare()">Compare</ui5-button>
                      <ui5-button design="Negative" (click)="undeploy(m)">Undeploy</ui5-button>
                    }
                    @if (m.status === 'completed' && !m.deployed) {
                      <ui5-button design="Emphasized" icon="shipping-status"
                                  [disabled]="deployingId() === m.id"
                                  (click)="confirmDeploy(m)">
                        {{ deployingId() === m.id ? 'Deploying…' : 'Deploy' }}
                      </ui5-button>
                    }
                    <ui5-button design="Transparent" icon="detail-more" (click)="toggleExpand(m.id)"
                                title="Version history"></ui5-button>
                    <ui5-button design="Negative" icon="delete" (click)="confirmDelete(m.id)"></ui5-button>
                  </div>
                </ui5-table-cell>
              </ui5-table-row>
            }
          </ui5-table>
          <!-- Expandable version history panel -->
          @if (getExpandedModel(); as em) {
            <ui5-panel header-text="📋 Training History">
              <div style="padding: 1rem;">
                <div class="detail-grid">
                  <div class="detail-item">
                    <span class="detail-label">Model</span>
                    <span class="detail-value">{{ em.config['model_name'] }}</span>
                  </div>
                  <div class="detail-item">
                    <span class="detail-label">Created</span>
                    <span class="detail-value">{{ em.created_at | date:'medium' }}</span>
                  </div>
                  <div class="detail-item">
                    <span class="detail-label">Progress</span>
                    <span class="detail-value">{{ em.progress }}%</span>
                  </div>
                  @if (em.evaluation) {
                    <div class="detail-item">
                      <span class="detail-label">Eval Loss</span>
                      <span class="detail-value">{{ em.evaluation.eval_loss.toFixed(4) }}</span>
                    </div>
                    <div class="detail-item">
                      <span class="detail-label">Runtime</span>
                      <span class="detail-value">{{ (em.evaluation.runtime_sec / 60).toFixed(1) }} min</span>
                    </div>
                  }
                </div>
                @if (em.history?.length) {
                  <div class="loss-chart">
                    <div class="chart-label">Loss over training steps</div>
                    <div class="chart-bars">
                      @for (h of em.history.slice(-20); track h.step) {
                        <div class="chart-bar-col" [title]="'Step ' + h.step + ': ' + h.loss.toFixed(4)">
                          <div class="chart-bar"
                               [style.height.%]="lossBarHeight(h.loss, em.history)"></div>
                        </div>
                      }
                    </div>
                  </div>
                }
              </div>
            </ui5-panel>
          }
        </div>
      } @else {
        <div class="empty-state">
          <div class="empty-icon">📭</div>
          <p class="empty-title">No Models Found</p>
          @if (searchQuery || filterStatus || showDeployedOnly || filterTag) {
            <p class="empty-desc">No models match your current filters. Try adjusting your search criteria.</p>
            <ui5-button design="Transparent" (click)="clearFilters()">Clear Filters</ui5-button>
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
              <ui5-button design="Transparent" (click)="confirmDeployModel.set(null)">Cancel</ui5-button>
              <ui5-button design="Emphasized" icon="shipping-status" (click)="deploy(confirmDeployModel()!)">Deploy Now</ui5-button>
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
              <ui5-button design="Transparent" (click)="confirmDeleteId.set(null)">Cancel</ui5-button>
              <ui5-button design="Negative" icon="delete" (click)="deleteJob(confirmDeleteId()!)">Delete</ui5-button>
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

  onFilterStatusChange(event: any) {
    this.filterStatus = event.detail?.selectedOption?.getAttribute('value') ?? '';
    this.applyFilter();
  }

  onSearchInput(event: any): void {
    this.searchQuery = event.target?.value ?? '';
    this.applyFilter();
  }

  getExpandedModel(): RegistryEntry | null {
    const eid = this.expandedId();
    if (!eid) return null;
    return this.filtered().find(m => m.id === eid) ?? null;
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
