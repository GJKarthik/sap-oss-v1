import { Component, DestroyRef, OnInit, OnDestroy, inject } from '@angular/core';
import { CommonModule } from '@angular/common';
import { Ui5WebcomponentsModule } from '@ui5/webcomponents-ngx';
import { takeUntilDestroyed } from '@angular/core/rxjs-interop';
import { forkJoin } from 'rxjs';
import { EmptyStateComponent } from '../../shared';
import { ElasticsearchClusterHealth, McpService, VectorStore } from '../../services/mcp.service';
import { TranslatePipe, I18nService } from '../../shared/services/i18n.service';

@Component({
  selector: 'app-streaming',
  standalone: true,
  imports: [CommonModule, Ui5WebcomponentsModule, EmptyStateComponent, TranslatePipe],
  template: `
    <ui5-page background-design="Solid">
      <ui5-bar slot="header" design="Header">
        <ui5-title slot="startContent" level="H3">{{ 'streaming.searchOperations' | translate }}</ui5-title>
        <div slot="endContent" class="header-actions">
          <span class="last-refreshed" *ngIf="lastRefreshed">{{ 'common.updated' | translate }} {{ getTimeSinceRefresh() }}</span>
          <ui5-switch
            [checked]="autoRefreshEnabled"
            (change)="toggleAutoRefresh()"
            [attr.aria-label]="'streaming.autoRefreshLabel' | translate">
          </ui5-switch>
          <ui5-button
            icon="refresh"
            (click)="refresh()"
            [disabled]="loading"
            aria-label="Refresh search operations data">
            {{ loading ? ('common.loading' | translate) : ('common.refresh' | translate) }}
          </ui5-button>
        </div>
      </ui5-bar>

      <div class="operations-content" role="main" aria-label="Search operations dashboard">
        <ui5-message-strip
          *ngIf="error"
          design="Negative"
          [hideCloseButton]="false"
          (close)="error = ''"
          role="alert">
          {{ error }}
        </ui5-message-strip>

        <div class="grid">
          <ui5-card>
            <ui5-card-header
              slot="header"
              [titleText]="'streaming.clusterHealth' | translate"
              [subtitleText]="'streaming.clusterHealthSubtitle' | translate">
            </ui5-card-header>
            <div class="card-content" *ngIf="clusterHealth; else clusterEmpty" role="region" aria-label="Cluster health metrics">
              <div class="metric-row">
                <span>{{ 'common.status' | translate }}</span>
                <ui5-tag [design]="clusterTagDesign(clusterHealth.status)">
                  {{ clusterHealth.status || 'unknown' }}
                </ui5-tag>
              </div>
              <div class="metric-row">
                <span>{{ 'streaming.clusterName' | translate }}</span>
                <strong>{{ clusterHealth.cluster_name || 'n/a' }}</strong>
              </div>
              <div class="metric-row">
                <span>{{ 'streaming.nodes' | translate }}</span>
                <strong>{{ clusterHealth.number_of_nodes ?? 'n/a' }}</strong>
              </div>
              <div class="metric-row">
                <span>{{ 'streaming.activeShards' | translate }}</span>
                <strong>{{ clusterHealth.active_shards ?? 'n/a' }}</strong>
              </div>
              <div class="metric-row" *ngIf="clusterHealth.relocating_shards !== undefined">
                <span>{{ 'streaming.relocatingShards' | translate }}</span>
                <ui5-tag [design]="$any(clusterHealth.relocating_shards) > 0 ? 'Critical' : 'Positive'">{{ clusterHealth.relocating_shards }}</ui5-tag>
              </div>
              <div class="metric-row" *ngIf="clusterHealth.unassigned_shards !== undefined">
                <span>{{ 'streaming.unassignedShards' | translate }}</span>
                <ui5-tag [design]="$any(clusterHealth.unassigned_shards) > 0 ? 'Negative' : 'Positive'">{{ clusterHealth.unassigned_shards }}</ui5-tag>
              </div>
              <div class="metric-row" *ngIf="clusterHealth.number_of_pending_tasks !== undefined">
                <span>{{ 'streaming.pendingTasks' | translate }}</span>
                <ui5-tag [design]="$any(clusterHealth.number_of_pending_tasks) > 0 ? 'Critical' : 'Neutral'">{{ clusterHealth.number_of_pending_tasks }}</ui5-tag>
              </div>
              <div class="metric-row" *ngIf="clusterHealth.active_primary_shards !== undefined">
                <span>{{ 'streaming.primaryShards' | translate }}</span>
                <strong>{{ clusterHealth.active_primary_shards }}</strong>
              </div>
            </div>
            <ng-template #clusterEmpty>
              <app-empty-state
                icon="search"
                [title]="'streaming.clusterUnavailable' | translate"
                [description]="'streaming.clusterUnavailableDesc' | translate">
              </app-empty-state>
            </ng-template>
          </ui5-card>

          <ui5-card>
            <ui5-card-header
              slot="header"
              [titleText]="'streaming.registeredKnowledgeBases' | translate"
              [subtitleText]="'streaming.searchIndices' | translate"
              [additionalText]="vectorStores.length + ''">
            </ui5-card-header>
            <ui5-table *ngIf="vectorStores.length > 0; else emptyStores" aria-label="Registered knowledge bases">
              <ui5-table-header-cell><span>{{ 'streaming.knowledgeBase' | translate }}</span></ui5-table-header-cell>
              <ui5-table-header-cell><span>{{ 'streaming.embeddingModel' | translate }}</span></ui5-table-header-cell>
              <ui5-table-header-cell><span>{{ 'streaming.documents' | translate }}</span></ui5-table-header-cell>
              <ui5-table-header-cell><span>{{ 'common.status' | translate }}</span></ui5-table-header-cell>

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
                [title]="'streaming.noKnowledgeBases' | translate"
                [description]="'streaming.noKnowledgeBasesDesc' | translate">
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

    .header-actions {
      display: flex;
      align-items: center;
      gap: 0.75rem;
    }

    .last-refreshed {
      font-size: var(--sapFontSmallSize);
      color: var(--sapContent_LabelColor);
      white-space: nowrap;
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
export class StreamingComponent implements OnInit, OnDestroy {
  private readonly mcpService = inject(McpService);
  private readonly destroyRef = inject(DestroyRef);
  readonly i18n = inject(I18nService);

  vectorStores: VectorStore[] = [];
  clusterHealth: ElasticsearchClusterHealth | null = null;
  loading = false;
  error = '';
  autoRefreshEnabled = true;
  lastRefreshed: Date | null = null;
  private autoRefreshTimer: ReturnType<typeof setInterval> | null = null;

  ngOnInit(): void {
    this.refresh();
    this.startAutoRefresh();
  }

  ngOnDestroy(): void {
    this.stopAutoRefresh();
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
          this.lastRefreshed = new Date();
        },
        error: () => {
          this.error = this.i18n.t('streaming.loadFailed');
          this.loading = false;
        },
      });
  }

  toggleAutoRefresh(): void {
    this.autoRefreshEnabled = !this.autoRefreshEnabled;
    if (this.autoRefreshEnabled) this.startAutoRefresh();
    else this.stopAutoRefresh();
  }

  getTimeSinceRefresh(): string {
    if (!this.lastRefreshed) return '';
    const seconds = Math.floor((Date.now() - this.lastRefreshed.getTime()) / 1000);
    if (seconds < 5) return 'just now';
    if (seconds < 60) return `${seconds}s ago`;
    return `${Math.floor(seconds / 60)}m ago`;
  }

  private startAutoRefresh(): void {
    this.stopAutoRefresh();
    if (this.autoRefreshEnabled) {
      this.autoRefreshTimer = setInterval(() => this.refresh(), 15_000);
    }
  }

  private stopAutoRefresh(): void {
    if (this.autoRefreshTimer) { clearInterval(this.autoRefreshTimer); this.autoRefreshTimer = null; }
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
