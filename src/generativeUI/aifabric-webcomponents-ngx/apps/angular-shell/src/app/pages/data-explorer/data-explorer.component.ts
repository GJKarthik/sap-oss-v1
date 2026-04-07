import { Component, DestroyRef, OnInit, inject } from '@angular/core';
import { CommonModule } from '@angular/common';
import { Ui5WebcomponentsModule } from '@ui5/webcomponents-ngx';
import { takeUntilDestroyed } from '@angular/core/rxjs-interop';
import { McpService, VectorStore } from '../../services/mcp.service';
import { EmptyStateComponent, CrossAppLinkComponent } from '../../shared';

@Component({
  selector: 'app-data-explorer',
  standalone: true,
  imports: [CommonModule, Ui5WebcomponentsModule, EmptyStateComponent, CrossAppLinkComponent],
  template: `
    <ui5-page background-design="Solid">
      <ui5-bar slot="header" design="Header">
        <ui5-title slot="startContent" level="H3">Data Explorer</ui5-title>
        <ui5-button 
          slot="endContent" 
          icon="refresh" 
          (click)="refresh()" 
          [disabled]="loading"
          aria-label="Refresh vector stores">
          {{ loading ? 'Loading...' : 'Refresh' }}
        </ui5-button>
      </ui5-bar>
      <app-cross-app-link
        targetApp="training"
        targetRoute="/data-explorer"
        targetLabel="Training Data Explorer"
        icon="database"
        relationLabel="Related — browse training datasets:">
      </app-cross-app-link>

      <div class="data-content" role="region" aria-label="Vector stores explorer">
        <!-- Loading indicator -->
        <div class="loading-container" *ngIf="loading" role="status" aria-live="polite">
          <ui5-busy-indicator active size="M"></ui5-busy-indicator>
          <span class="loading-text">Loading vector stores...</span>
        </div>

        <ui5-message-strip 
          *ngIf="error" 
          design="Negative" 
          [hideCloseButton]="false"
          (close)="error = ''"
          role="alert">
          {{ error }}
        </ui5-message-strip>

        <ui5-card [class.card-loading]="loading">
          <ui5-card-header 
            slot="header" 
            title-text="HANA Vector Stores" 
            subtitle-text="SAP HANA Cloud vector database collections"
            [additionalText]="stores.length + ''">
          </ui5-card-header>
          <ui5-table 
            *ngIf="stores.length > 0" 
            aria-label="Vector stores table">
            <ui5-table-header-cell><span>Table Name</span></ui5-table-header-cell>
            <ui5-table-header-cell><span>Embedding Model</span></ui5-table-header-cell>
            <ui5-table-header-cell><span>Documents</span></ui5-table-header-cell>
            <ui5-table-header-cell><span>Status</span></ui5-table-header-cell>
            <ui5-table-row *ngFor="let store of stores; trackBy: trackByTableName">
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
                  {{ store.status || 'Active' }}
                </ui5-tag>
              </ui5-table-cell>
            </ui5-table-row>
          </ui5-table>

          <app-empty-state
            *ngIf="!loading && stores.length === 0"
            icon="database"
            title="No Vector Stores"
            description="No vector stores have been created yet. Use RAG Studio to create your first knowledge base.">
          </app-empty-state>
        </ui5-card>

        <!-- Statistics summary -->
        <ui5-card class="stats-card" *ngIf="stores.length > 0">
          <ui5-card-header 
            slot="header" 
            title-text="Summary"
            subtitle-text="Vector store statistics">
          </ui5-card-header>
          <div class="stats-content">
            <div class="stat-item">
              <span class="stat-label">Total Stores</span>
              <span class="stat-value">{{ stores.length }}</span>
            </div>
            <div class="stat-item">
              <span class="stat-label">Total Documents</span>
              <span class="stat-value">{{ getTotalDocuments() | number }}</span>
            </div>
            <div class="stat-item">
              <span class="stat-label">Embedding Models</span>
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

  stores: VectorStore[] = [];
  loading = false;
  error = '';

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
          this.error = 'Failed to load vector stores.'; 
          this.loading = false; 
        }
      });
  }

  trackByTableName(index: number, store: VectorStore): string {
    return store.table_name;
  }

  getStoreStatusDesign(store: VectorStore): 'Positive' | 'Negative' | 'Neutral' {
    const status = store.status?.toLowerCase();
    if (!status || status === 'active' || status === 'ready') {
      return 'Positive';
    }
    if (status === 'error' || status === 'failed') {
      return 'Negative';
    }
    return 'Neutral';
  }

  getTotalDocuments(): number {
    return this.stores.reduce((total, store) => total + store.documents_added, 0);
  }

  getUniqueModels(): number {
    const models = new Set(this.stores.map(store => store.embedding_model));
    return models.size;
  }
}
