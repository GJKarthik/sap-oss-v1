import { Component, DestroyRef, OnInit, inject } from '@angular/core';
import { CommonModule } from '@angular/common';
import { FormsModule } from '@angular/forms';
import { Ui5WebcomponentsModule } from '@ui5/webcomponents-ngx';
import { takeUntilDestroyed } from '@angular/core/rxjs-interop';
import { McpService, VectorStore } from '../../services/mcp.service';
import { EmptyStateComponent, CrossAppLinkComponent } from '../../shared';
import { TranslatePipe, I18nService } from '../../shared/services/i18n.service';

@Component({
  selector: 'app-data-explorer',
  standalone: true,
  imports: [CommonModule, FormsModule, Ui5WebcomponentsModule, EmptyStateComponent, CrossAppLinkComponent, TranslatePipe],
  template: `
    <ui5-page background-design="Solid">
      <ui5-bar slot="header" design="Header">
        <ui5-title slot="startContent" level="H3">{{ 'dataExplorer.title' | translate }}</ui5-title>
        <ui5-button
          slot="endContent"
          icon="refresh"
          (click)="refresh()"
          [disabled]="loading"
          [attr.aria-label]="i18n.t('dataExplorer.refreshStores')">
          {{ loading ? ('common.loading' | translate) : ('common.refresh' | translate) }}
        </ui5-button>
      </ui5-bar>
      <app-cross-app-link
        targetApp="training"
        targetRoute="/data-explorer"
        targetLabel="Training Data Explorer"
        icon="database"
        relationLabel="Related — browse training datasets:">
      </app-cross-app-link>

      <div class="data-content" role="region" [attr.aria-label]="i18n.t('dataExplorer.storesExplorer')">
        <!-- Loading indicator -->
        <div class="loading-container" *ngIf="loading" role="status" aria-live="polite">
          <ui5-busy-indicator active size="M"></ui5-busy-indicator>
          <span class="loading-text">{{ 'dataExplorer.loadingStores' | translate }}</span>
        </div>

        <ui5-message-strip
          *ngIf="error"
          design="Negative"
          [hideCloseButton]="false"
          (close)="error = ''"
          role="alert">
          {{ error }}
        </ui5-message-strip>

        <!-- Search and filter bar -->
        <div class="filter-bar" *ngIf="stores.length > 0">
          <ui5-input
            [placeholder]="'dataExplorer.filterPlaceholder' | translate"
            [value]="filterQuery"
            (input)="filterQuery = $any($event.target).value"
            class="filter-input"
            show-clear-icon>
          </ui5-input>
          <span class="filter-count">{{ filteredStores().length }} of {{ stores.length }} {{ 'dataExplorer.stores' | translate }}</span>
        </div>

        <ui5-card [class.card-loading]="loading">
          <ui5-card-header
            slot="header"
            [titleText]="'dataExplorer.vectorStores' | translate"
            [subtitleText]="'dataExplorer.hanaCollections' | translate"
            [additionalText]="filteredStores().length + ''">
          </ui5-card-header>
          <ui5-table
            *ngIf="filteredStores().length > 0"
            [attr.aria-label]="'dataExplorer.vectorStoresTable' | translate">
            <ui5-table-header-cell><span class="sortable" (click)="toggleSort('table_name')">{{ 'dataExplorer.tableName' | translate }} {{ getSortIcon('table_name') }}</span></ui5-table-header-cell>
            <ui5-table-header-cell><span class="sortable" (click)="toggleSort('embedding_model')">{{ 'dataExplorer.embeddingModel' | translate }} {{ getSortIcon('embedding_model') }}</span></ui5-table-header-cell>
            <ui5-table-header-cell><span class="sortable" (click)="toggleSort('documents_added')">{{ 'dataExplorer.documents' | translate }} {{ getSortIcon('documents_added') }}</span></ui5-table-header-cell>
            <ui5-table-header-cell><span>{{ 'dataExplorer.status' | translate }}</span></ui5-table-header-cell>
            <ui5-table-row *ngFor="let store of paginatedStores(); trackBy: trackByTableName">
              <ui5-table-cell>
                <code class="table-name">{{ store.table_name }}</code>
              </ui5-table-cell>
              <ui5-table-cell>
                <ui5-tag design="Information">{{ store.embedding_model }}</ui5-tag>
              </ui5-table-cell>
              <ui5-table-cell>
                <span class="document-count">{{ store.documents_added | number }}</span>
              </ui5-table-cell>
              <ui5-table-cell>
                <ui5-tag [design]="getStoreStatusDesign(store)">
                  {{ store.status || ('dataExplorer.active' | translate) }}
                </ui5-tag>
              </ui5-table-cell>
            </ui5-table-row>
          </ui5-table>

          <app-empty-state
            *ngIf="!loading && stores.length === 0"
            icon="database"
            [title]="'dataExplorer.noStores' | translate"
            [description]="'dataExplorer.noStoresDescription' | translate">
          </app-empty-state>
          <div *ngIf="filteredStores().length === 0 && stores.length > 0" class="empty-filter">
            {{ 'dataExplorer.noMatchingStores' | translate }} "{{ filterQuery }}".
          </div>
        </ui5-card>

        <!-- Pagination -->
        <div class="pagination-bar" *ngIf="filteredStores().length > pageSize">
          <ui5-button design="Transparent" [disabled]="currentPage === 0" (click)="currentPage = currentPage - 1">{{ 'common.previous' | translate }}</ui5-button>
          <span class="page-info">{{ 'dataExplorer.pageInfo' | translate }} {{ currentPage + 1 }} / {{ totalPages() }}</span>
          <ui5-button design="Transparent" [disabled]="currentPage >= totalPages() - 1" (click)="currentPage = currentPage + 1">{{ 'common.next' | translate }}</ui5-button>
        </div>

        <!-- Statistics summary -->
        <ui5-card class="stats-card" *ngIf="stores.length > 0">
          <ui5-card-header
            slot="header"
            [titleText]="'dataExplorer.summary' | translate"
            [subtitleText]="'dataExplorer.statistics' | translate">
          </ui5-card-header>
          <div class="stats-content">
            <div class="stat-item">
              <span class="stat-label">{{ 'dataExplorer.totalStores' | translate }}</span>
              <span class="stat-value">{{ stores.length }}</span>
            </div>
            <div class="stat-item">
              <span class="stat-label">{{ 'dataExplorer.totalDocuments' | translate }}</span>
              <span class="stat-value">{{ getTotalDocuments() | number }}</span>
            </div>
            <div class="stat-item">
              <span class="stat-label">{{ 'dataExplorer.embeddingModels' | translate }}</span>
              <span class="stat-value">{{ getUniqueModels() }}</span>
            </div>
          </div>
        </ui5-card>
      </div>
    </ui5-page>
  `,
  styles: [`
    .data-content {
      padding: 1rem;
      max-width: 1200px;
      margin: 0 auto;
      display: flex;
      flex-direction: column;
      gap: 1rem;
    }

    .loading-container {
      display: flex;
      align-items: center;
      justify-content: center;
      padding: 2rem;
      gap: 1rem;
    }

    .loading-text {
      color: var(--sapContent_LabelColor);
    }

    ui5-message-strip {
      margin-bottom: 0;
    }

    .filter-bar {
      display: flex;
      align-items: center;
      gap: 1rem;
    }

    .filter-input {
      flex: 1;
      max-width: 400px;
    }

    .filter-count {
      font-size: var(--sapFontSmallSize);
      color: var(--sapContent_LabelColor);
      white-space: nowrap;
    }

    .sortable {
      cursor: pointer;
      user-select: none;
    }

    .sortable:hover {
      color: var(--sapBrandColor);
    }

    .empty-filter {
      padding: 2rem;
      text-align: center;
      color: var(--sapContent_LabelColor);
    }

    .pagination-bar {
      display: flex;
      align-items: center;
      justify-content: center;
      gap: 1rem;
    }

    .page-info {
      font-size: var(--sapFontSmallSize);
      color: var(--sapContent_LabelColor);
    }

    .card-loading {
      opacity: 0.6;
      pointer-events: none;
    }

    .table-name {
      font-family: monospace;
      font-size: var(--sapFontSmallSize);
      background: var(--sapList_Background);
      padding: 0.125rem 0.375rem;
      border-radius: 4px;
    }

    .document-count {
      font-weight: 600;
      color: var(--sapBrandColor);
    }

    .stats-card {
      max-width: 600px;
    }

    .stats-content {
      display: flex;
      gap: 2rem;
      padding: 1rem;
      flex-wrap: wrap;
    }

    .stat-item {
      display: flex;
      flex-direction: column;
      gap: 0.25rem;
    }

    .stat-label {
      font-size: var(--sapFontSmallSize);
      color: var(--sapContent_LabelColor);
    }

    .stat-value {
      font-size: 1.5rem;
      font-weight: 600;
      color: var(--sapBrandColor);
    }

    @media (max-width: 768px) {
      .data-content {
        padding: 0.75rem;
      }

      .stats-content {
        gap: 1rem;
      }

      .stat-value {
        font-size: 1.25rem;
      }
    }
  `]
})
export class DataExplorerComponent implements OnInit {
  private readonly mcpService = inject(McpService);
  private readonly destroyRef = inject(DestroyRef);
  readonly i18n = inject(I18nService);

  stores: VectorStore[] = [];
  loading = false;
  error = '';
  filterQuery = '';
  sortColumn: keyof VectorStore | '' = '';
  sortDirection: 'asc' | 'desc' = 'asc';
  currentPage = 0;
  pageSize = 10;

  ngOnInit(): void {
    this.refresh();
  }

  refresh(): void {
    this.loading = true;
    this.error = '';
    this.mcpService.fetchVectorStores()
      .pipe(takeUntilDestroyed(this.destroyRef))
      .subscribe({
        next: stores => {
          this.stores = stores;
          this.loading = false;
        },
        error: () => {
          this.error = this.i18n.t('dataExplorer.loadFailed');
          this.loading = false;
        }
      });
  }

  filteredStores(): VectorStore[] {
    let result = this.stores;
    if (this.filterQuery) {
      const q = this.filterQuery.toLowerCase();
      result = result.filter(s =>
        s.table_name.toLowerCase().includes(q) ||
        s.embedding_model.toLowerCase().includes(q)
      );
    }
    if (this.sortColumn) {
      const col = this.sortColumn;
      const dir = this.sortDirection === 'asc' ? 1 : -1;
      result = [...result].sort((a, b) => {
        const va = a[col]; const vb = b[col];
        if (typeof va === 'number' && typeof vb === 'number') return (va - vb) * dir;
        return String(va ?? '').localeCompare(String(vb ?? '')) * dir;
      });
    }
    return result;
  }

  paginatedStores(): VectorStore[] {
    const start = this.currentPage * this.pageSize;
    return this.filteredStores().slice(start, start + this.pageSize);
  }

  totalPages(): number {
    return Math.max(1, Math.ceil(this.filteredStores().length / this.pageSize));
  }

  toggleSort(column: keyof VectorStore): void {
    if (this.sortColumn === column) {
      this.sortDirection = this.sortDirection === 'asc' ? 'desc' : 'asc';
    } else {
      this.sortColumn = column;
      this.sortDirection = 'asc';
    }
    this.currentPage = 0;
  }

  getSortIcon(column: string): string {
    if (this.sortColumn !== column) return '';
    return this.sortDirection === 'asc' ? '↑' : '↓';
  }

  trackByTableName(index: number, store: VectorStore): string {
    return store.table_name;
  }

  getStoreStatusDesign(store: VectorStore): 'Positive' | 'Negative' | 'Neutral' {
    const status = store.status?.toLowerCase();
    if (!status || status === 'active' || status === 'ready') return 'Positive';
    if (status === 'error' || status === 'failed') return 'Negative';
    return 'Neutral';
  }

  getTotalDocuments(): number {
    return this.stores.reduce((total, store) => total + store.documents_added, 0);
  }

  getUniqueModels(): number {
    return new Set(this.stores.map(store => store.embedding_model)).size;
  }
}
