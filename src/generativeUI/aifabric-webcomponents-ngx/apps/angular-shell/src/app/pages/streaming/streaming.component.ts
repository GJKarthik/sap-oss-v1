import { Component, DestroyRef, OnInit, inject } from '@angular/core';
import { CommonModule } from '@angular/common';
import { Ui5WebcomponentsModule } from '@ui5/webcomponents-ngx';
import { takeUntilDestroyed } from '@angular/core/rxjs-interop';
import { forkJoin } from 'rxjs';
import { EmptyStateComponent } from '../../shared';
import { ElasticsearchClusterHealth, McpService, VectorStore } from '../../services/mcp.service';

@Component({
  selector: 'app-streaming',
  standalone: true,
  imports: [CommonModule, Ui5WebcomponentsModule, EmptyStateComponent],
  template: `
    <ui5-page background-design="Solid">
      <ui5-bar slot="header" design="Header">
        <ui5-title slot="startContent" level="H3">Search Operations</ui5-title>
        <ui5-button
          slot="endContent"
          icon="refresh"
          (click)="refresh()"
          [disabled]="loading">
          {{ loading ? 'Loading...' : 'Refresh' }}
        </ui5-button>
      </ui5-bar>

      <div class="operations-content">
        <ui5-message-strip
          *ngIf="error"
          design="Negative"
          [hideCloseButton]="false"
          (close)="error = ''">
          {{ error }}
        </ui5-message-strip>

        <div class="grid">
          <ui5-card>
            <ui5-card-header
              slot="header"
              title-text="Elasticsearch Cluster"
              subtitle-text="Live cluster health and shard state">
            </ui5-card-header>
            <div class="card-content" *ngIf="clusterHealth; else clusterEmpty">
              <div class="metric-row">
                <span>Status</span>
                <ui5-tag [design]="clusterTagDesign(clusterHealth.status)">
                  {{ clusterHealth.status || 'unknown' }}
                </ui5-tag>
              </div>
              <div class="metric-row">
                <span>Cluster Name</span>
                <strong>{{ clusterHealth.cluster_name || 'n/a' }}</strong>
              </div>
              <div class="metric-row">
                <span>Nodes</span>
                <strong>{{ clusterHealth.number_of_nodes ?? 'n/a' }}</strong>
              </div>
              <div class="metric-row">
                <span>Active Shards</span>
                <strong>{{ clusterHealth.active_shards ?? 'n/a' }}</strong>
              </div>
            </div>
            <ng-template #clusterEmpty>
              <app-empty-state
                icon="search"
                title="Cluster state unavailable"
                description="Refresh the page after the Elasticsearch MCP service becomes reachable.">
              </app-empty-state>
            </ng-template>
          </ui5-card>

          <ui5-card>
            <ui5-card-header
              slot="header"
              title-text="Registered Knowledge Bases"
              subtitle-text="Search indices tracked by the console"
              [additionalText]="vectorStores.length + ''">
            </ui5-card-header>
            <ui5-table *ngIf="vectorStores.length > 0; else emptyStores">
              <ui5-table-header-cell><span>Knowledge Base</span></ui5-table-header-cell>
              <ui5-table-header-cell><span>Embedding Model</span></ui5-table-header-cell>
              <ui5-table-header-cell><span>Documents</span></ui5-table-header-cell>
              <ui5-table-header-cell><span>Status</span></ui5-table-header-cell>

              <ui5-table-row *ngFor="let store of vectorStores; trackBy: trackByStore">
                <ui5-table-cell>{{ store.table_name }}</ui5-table-cell>
                <ui5-table-cell>{{ store.embedding_model }}</ui5-table-cell>
                <ui5-table-cell>{{ store.documents_added }}</ui5-table-cell>
                <ui5-table-cell>
                  <ui5-tag [design]="store.status === 'active' ? 'Positive' : 'Neutral'">
                    {{ store.status || 'unknown' }}
                  </ui5-tag>
                </ui5-table-cell>
              </ui5-table-row>
            </ui5-table>

            <ng-template #emptyStores>
              <app-empty-state
                icon="database"
                title="No knowledge bases registered"
                description="Create a knowledge base in Search Studio to begin indexing documents.">
              </app-empty-state>
            </ng-template>
          </ui5-card>
        </div>
      </div>
    </ui5-page>
  `,
  styles: [`
    .operations-content {
      padding: 1rem;
      max-width: 1400px;
      margin: 0 auto;
      display: flex;
      flex-direction: column;
      gap: 1rem;
    }

    .grid {
      display: grid;
      gap: 1rem;
      grid-template-columns: repeat(auto-fit, minmax(320px, 1fr));
    }

    .card-content {
      padding: 1rem;
      display: grid;
      gap: 0.75rem;
    }

    .metric-row {
      display: flex;
      justify-content: space-between;
      align-items: center;
      gap: 1rem;
      padding-bottom: 0.5rem;
      border-bottom: 1px solid var(--sapList_BorderColor);
    }

    .metric-row:last-child {
      border-bottom: none;
      padding-bottom: 0;
    }

    ui5-message-strip {
      margin-bottom: 0.25rem;
    }

    @media (max-width: 768px) {
      .operations-content {
        padding: 0.75rem;
      }
    }
  `],
})
export class StreamingComponent implements OnInit {
  private readonly mcpService = inject(McpService);
  private readonly destroyRef = inject(DestroyRef);

  vectorStores: VectorStore[] = [];
  clusterHealth: ElasticsearchClusterHealth | null = null;
  loading = false;
  error = '';

  ngOnInit(): void {
    this.refresh();
  }

  refresh(): void {
    this.loading = true;
    this.error = '';
    forkJoin({
      clusterHealth: this.mcpService.getElasticsearchClusterHealth(),
      vectorStores: this.mcpService.fetchVectorStores(),
    })
      .pipe(takeUntilDestroyed(this.destroyRef))
      .subscribe({
        next: ({ clusterHealth, vectorStores }) => {
          this.clusterHealth = clusterHealth;
          this.vectorStores = vectorStores;
          this.loading = false;
        },
        error: () => {
          this.error = 'Failed to load search operations data.';
          this.loading = false;
        },
      });
  }

  trackByStore(index: number, store: VectorStore): string {
    return `${store.table_name}-${index}`;
  }

  clusterTagDesign(status: string | undefined): 'Positive' | 'Critical' | 'Negative' | 'Neutral' {
    const normalized = (status || '').toLowerCase();
    if (normalized === 'green' || normalized === 'healthy') {
      return 'Positive';
    }
    if (normalized === 'yellow' || normalized === 'degraded') {
      return 'Critical';
    }
    if (normalized === 'red' || normalized === 'error') {
      return 'Negative';
    }
    return 'Neutral';
  }
}
