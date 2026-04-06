/**
 * Dashboard Component - Angular/UI5 Version
 *
 * Uses UI5 Web Components following ui5-webcomponents-ngx standards
 * Connects to real MCP backends (elasticsearch-mcp, ai-core-pal)
 * Enhanced with accessibility features and responsive design
 */

import { Component, DestroyRef, OnInit, inject } from '@angular/core';
import { CommonModule } from '@angular/common';
import { Router } from '@angular/router';
import { Ui5WebcomponentsModule } from '@ui5/webcomponents-ngx';
import { takeUntilDestroyed } from '@angular/core/rxjs-interop';
import { forkJoin } from 'rxjs';
import { McpService, DashboardStats, OperationsDashboard, ServiceHealth } from '../../services/mcp.service';

@Component({
  selector: 'app-dashboard',
  standalone: true,
  imports: [CommonModule, Ui5WebcomponentsModule],
  template: `
    <!-- Page Header -->
    <ui5-page background-design="Solid">
      <ui5-bar slot="header" design="Header">
        <ui5-title slot="startContent" level="H3">Dashboard</ui5-title>
        <ui5-button 
          slot="endContent" 
          icon="refresh" 
          (click)="refresh()"
          [disabled]="loading"
          aria-label="Refresh dashboard data">
          {{ loading ? 'Loading...' : 'Refresh' }}
        </ui5-button>
      </ui5-bar>

      <!-- Main Content -->
      <div class="dashboard-content" role="region" aria-label="Dashboard overview">
        <!-- Loading Overlay -->
        <div class="loading-overlay" *ngIf="loading && !error" role="status" aria-live="polite">
          <ui5-busy-indicator active size="L"></ui5-busy-indicator>
          <span class="loading-text">Loading dashboard data...</span>
        </div>
        
        <ui5-message-strip
          *ngIf="error"
          design="Negative"
          [hideCloseButton]="false"
          (close)="error = ''"
          role="alert">
          {{ error }}
        </ui5-message-strip>
        
        <!-- Health Status Banner -->
        <ui5-message-strip 
          *ngIf="health.overall !== 'healthy' && health.overall !== 'unknown'"
          [design]="health.overall === 'error' ? 'Negative' : 'Critical'"
          [hideCloseButton]="true"
          role="alert">
          {{ getHealthMessage() }}
        </ui5-message-strip>

        <!-- Stats Cards Row -->
        <div class="stats-grid" [class.loading]="loading">
          
          <!-- Services Health Card -->
            <ui5-card class="stat-card">
              <ui5-card-header 
                slot="header" 
                title-text="Services"
                subtitle-text="Backend MCP Services"
              [additionalText]="stats.servicesHealthy + '/' + stats.totalServices">
              <ui5-icon slot="avatar" name="overview-chart"></ui5-icon>
            </ui5-card-header>
            <div class="card-content">
              <div class="service-item">
                <ui5-icon [name]="health.elasticsearch?.status === 'healthy' ? 'status-positive' : 'status-negative'"></ui5-icon>
                <span>Elasticsearch MCP</span>
                <ui5-tag [design]="health.elasticsearch?.status === 'healthy' ? 'Positive' : 'Negative'">
                  {{ health.elasticsearch?.status || 'Unknown' }}
                </ui5-tag>
              </div>
              <div class="service-item">
                <ui5-icon [name]="health.pal?.status === 'healthy' ? 'status-positive' : 'status-negative'"></ui5-icon>
                <span>AI Core PAL</span>
                <ui5-tag [design]="health.pal?.status === 'healthy' ? 'Positive' : 'Negative'">
                  {{ health.pal?.status || 'Unknown' }}
                </ui5-tag>
              </div>
            </div>
          </ui5-card>

          <!-- Deployments Card -->
          <ui5-card class="stat-card">
            <ui5-card-header 
              slot="header" 
              title-text="Model Deployments"
              subtitle-text="AI Core Deployments"
              [additionalText]="stats.activeDeployments + '/' + stats.totalDeployments">
              <ui5-icon slot="avatar" name="machine"></ui5-icon>
            </ui5-card-header>
            <div class="card-content">
              <div class="stat-value">{{ stats.activeDeployments }}</div>
              <div class="stat-label">Active Models</div>
              <ui5-progress-indicator 
                [value]="getDeploymentPercentage()"
                [valueState]="stats.activeDeployments > 0 ? 'Positive' : 'None'">
              </ui5-progress-indicator>
            </div>
          </ui5-card>

          <!-- PAL Tools Card -->
          <ui5-card class="stat-card">
            <ui5-card-header 
              slot="header" 
              title-text="PAL Tooling"
              subtitle-text="Available analytics tools"
              [additionalText]="stats.availablePalTools + ''">
              <ui5-icon slot="avatar" name="process"></ui5-icon>
            </ui5-card-header>
            <div class="card-content">
              <div class="stat-value">{{ stats.availablePalTools }}</div>
              <div class="stat-label">Registered PAL tools</div>
              <ui5-tag design="Neutral">PAL + HANA operations</ui5-tag>
            </div>
          </ui5-card>

          <!-- Vector Stores Card -->
          <ui5-card class="stat-card">
            <ui5-card-header 
              slot="header" 
              title-text="Knowledge Bases"
              subtitle-text="Elasticsearch-backed search"
              [additionalText]="stats.totalKnowledgeBases + ''">
              <ui5-icon slot="avatar" name="database"></ui5-icon>
            </ui5-card-header>
            <div class="card-content">
              <div class="stat-value">{{ stats.documentsIndexed | number }}</div>
              <div class="stat-label">Documents Indexed</div>
              <ui5-tag design="Neutral">{{ stats.totalKnowledgeBases }} bases</ui5-tag>
            </div>
          </ui5-card>

          <!-- Operations Card -->
          <ui5-card class="stat-card" *ngIf="operations">
            <ui5-card-header
              slot="header"
              title-text="Operations"
              subtitle-text="API, auth, and store health"
              [additionalText]="getActiveAlertCount() + ' alerts'">
              <ui5-icon slot="avatar" name="activity-items"></ui5-icon>
            </ui5-card-header>
            <div class="card-content">
              <div class="service-item">
                <span>API Avg Latency</span>
                <ui5-tag design="Information">{{ operations.api.avg_latency_ms }} ms</ui5-tag>
              </div>
              <div class="service-item">
                <span>API Error Rate</span>
                <ui5-tag [design]="operations.api.error_rate > 0 ? 'Critical' : 'Positive'">
                  {{ operations.api.error_rate }}%
                </ui5-tag>
              </div>
              <div class="service-item">
                <span>Auth Failures ({{ operations.window_seconds }}s)</span>
                <ui5-tag [design]="operations.auth.recent_failures > 0 ? 'Critical' : 'Positive'">
                  {{ operations.auth.recent_failures }}
                </ui5-tag>
              </div>
              <div class="service-item">
                <span>Store Backend</span>
                <ui5-tag [design]="operations.store.store === 'ok' ? 'Positive' : 'Negative'">
                  {{ operations.store.store_backend }}
                </ui5-tag>
              </div>
            </div>
          </ui5-card>
        </div>

        <!-- Quick Actions Section -->
        <ui5-card class="actions-card">
          <ui5-card-header 
            slot="header" 
            title-text="Quick Actions"
            interactive
            (click)="toggleActions()">
          </ui5-card-header>
          <div class="quick-actions" *ngIf="showActions">
            <ui5-button design="Emphasized" icon="add" (click)="goTo('/playground')">
              PAL Workbench
            </ui5-button>
            <ui5-button design="Default" icon="documents" (click)="goTo('/rag')">
              Search Studio
            </ui5-button>
            <ui5-button design="Default" icon="database" (click)="goTo('/data')">
              Data Explorer
            </ui5-button>
            <ui5-button design="Default" icon="search" (click)="goTo('/streaming')">
              Search Ops
            </ui5-button>
            <ui5-button design="Default" icon="org-chart" (click)="goTo('/lineage')">
              Lineage View
            </ui5-button>
          </div>
        </ui5-card>

        <ui5-card class="activity-card" *ngIf="operations">
          <ui5-card-header 
            slot="header" 
            title-text="Operational Alerts"
            subtitle-text="Real-time platform state">
          </ui5-card-header>
          <ui5-table *ngIf="operations.alerts.length > 0">
            <ui5-table-header-cell><span>Alert</span></ui5-table-header-cell>
            <ui5-table-header-cell><span>Status</span></ui5-table-header-cell>
            <ui5-table-header-cell><span>Observed</span></ui5-table-header-cell>
            <ui5-table-header-cell><span>Threshold</span></ui5-table-header-cell>

            <ui5-table-row *ngFor="let alert of operations.alerts">
              <ui5-table-cell>{{ alert.name }}</ui5-table-cell>
              <ui5-table-cell>
                <ui5-tag [design]="alert.active ? 'Critical' : 'Positive'">
                  {{ alert.active ? 'Active' : 'Normal' }}
                </ui5-tag>
              </ui5-table-cell>
              <ui5-table-cell>{{ formatObserved(alert.observed) }}</ui5-table-cell>
              <ui5-table-cell>{{ alert.threshold }}</ui5-table-cell>
            </ui5-table-row>
          </ui5-table>
          <div *ngIf="operations.alerts.length === 0" class="empty-state">
            No operational alerts are active.
          </div>
        </ui5-card>
      </div>
    </ui5-page>
  `,
  styles: [`
    .dashboard-content {
      padding: 1rem;
      max-width: 1400px;
      margin: 0 auto;
      position: relative;
      min-height: 400px;
    }
    
    .loading-overlay {
      display: flex;
      flex-direction: column;
      align-items: center;
      justify-content: center;
      padding: 3rem;
      gap: 1rem;
    }
    
    .loading-text {
      color: var(--sapContent_LabelColor);
      font-size: var(--sapFontSize);
    }
    
    .stats-grid {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(280px, 1fr));
      gap: 1rem;
      margin-bottom: 1rem;
      transition: opacity 0.2s ease;
    }
    
    .stats-grid.loading {
      opacity: 0.6;
      pointer-events: none;
    }
    
    .stat-card {
      min-height: 180px;
      max-width: 400px;
    }
    
    @media (min-width: 1200px) {
      .stats-grid {
        grid-template-columns: repeat(auto-fit, minmax(280px, 380px));
        justify-content: start;
      }
    }
    
    .card-content {
      padding: 1rem;
    }
    
    .service-item {
      display: flex;
      align-items: center;
      gap: 0.5rem;
      padding: 0.5rem 0;
      border-bottom: 1px solid var(--sapList_BorderColor);
    }
    
    .service-item:last-child {
      border-bottom: none;
    }
    
    .service-item span {
      flex: 1;
    }
    
    .stat-value {
      font-size: 2.5rem;
      font-weight: bold;
      color: var(--sapBrandColor);
      line-height: 1;
    }
    
    .stat-label {
      color: var(--sapContent_LabelColor);
      margin: 0.5rem 0;
    }
    
    .quick-actions {
      display: flex;
      flex-wrap: wrap;
      gap: 0.5rem;
      padding: 1rem;
    }
    
    .actions-card {
      max-width: 800px;
    }
    
    .activity-card {
      margin-top: 1rem;
    }

    .empty-state {
      padding: 1rem;
      color: var(--sapContent_LabelColor);
      text-align: center;
    }
    
    ui5-message-strip {
      margin-bottom: 1rem;
    }
    
    /* Responsive adjustments */
    @media (max-width: 600px) {
      .dashboard-content {
        padding: 0.75rem;
      }
      
      .stat-value {
        font-size: 2rem;
      }
      
      .quick-actions {
        flex-direction: column;
      }
      
      .quick-actions ui5-button {
        width: 100%;
      }
    }
  `]
})
export class DashboardComponent implements OnInit {
  private readonly mcpService = inject(McpService);
  private readonly destroyRef = inject(DestroyRef);
  private readonly router = inject(Router);
  
  loading = true;
  showActions = true;
  error = '';
  
  stats: DashboardStats = {
    servicesHealthy: 0,
    totalServices: 2,
    activeDeployments: 0,
    totalDeployments: 0,
    availablePalTools: 0,
    totalKnowledgeBases: 0,
    documentsIndexed: 0,
    overallHealth: 'unknown'
  };
  
  health: {
    elasticsearch: ServiceHealth | null;
    pal: ServiceHealth | null;
    overall: 'healthy' | 'degraded' | 'error' | 'unknown';
  } = {
    elasticsearch: null,
    pal: null,
    overall: 'unknown'
  };
  operations: OperationsDashboard | null = null;

  ngOnInit(): void {
    this.mcpService.health$
      .pipe(takeUntilDestroyed(this.destroyRef))
      .subscribe(health => {
        this.health = health;
      });
    
    this.refresh();
  }

  refresh(): void {
    this.loading = true;
    this.error = '';
    forkJoin({
      stats: this.mcpService.getDashboardStats(),
      operations: this.mcpService.getOperationsDashboard()
    })
      .pipe(takeUntilDestroyed(this.destroyRef))
      .subscribe({
        next: ({ stats, operations }) => {
          this.stats = stats;
          this.operations = operations;
          this.loading = false;
        },
        error: () => {
          this.error = 'Failed to load dashboard data.';
          this.loading = false;
        }
      });
  }

  goTo(route: string): void {
    void this.router.navigate([route]);
  }

  getHealthMessage(): string {
    if (this.health.overall === 'error') {
      return 'All backend services are unavailable. Please check the MCP servers.';
    }
    if (this.health.overall === 'degraded') {
      const issues = [];
      if (this.health.elasticsearch?.status !== 'healthy') {
        issues.push('Elasticsearch MCP');
      }
      if (this.health.pal?.status !== 'healthy') {
        issues.push('AI Core PAL');
      }
      return `Some services are degraded: ${issues.join(', ')}`;
    }
    return '';
  }

  getDeploymentPercentage(): number {
    if (this.stats.totalDeployments === 0) return 0;
    return Math.round((this.stats.activeDeployments / this.stats.totalDeployments) * 100);
  }

  getActiveAlertCount(): number {
    return this.operations?.alerts.filter(alert => alert.active).length || 0;
  }

  formatObserved(observed: unknown): string {
    if (observed === null || observed === undefined) {
      return 'n/a';
    }

    if (typeof observed === 'string' || typeof observed === 'number' || typeof observed === 'boolean') {
      return String(observed);
    }

    return JSON.stringify(observed);
  }

  toggleActions(): void {
    this.showActions = !this.showActions;
  }
}
