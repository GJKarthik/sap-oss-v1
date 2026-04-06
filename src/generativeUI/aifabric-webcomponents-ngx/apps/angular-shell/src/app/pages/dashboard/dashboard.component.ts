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
import { EmptyStateComponent } from '../../shared';

@Component({
  selector: 'app-dashboard',
  standalone: true,
  imports: [CommonModule, Ui5WebcomponentsModule, EmptyStateComponent],
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
        <!-- Skeleton Loading Cards -->
        <div class="stats-grid" *ngIf="loading && !error" role="status" aria-live="polite" aria-label="Loading dashboard data">
          <div class="skeleton-card" *ngFor="let i of [1,2,3,4]" aria-hidden="true" role="presentation">
            <div class="skeleton-card__header">
              <div class="skeleton-bar skeleton-bar--circle"></div>
              <div class="skeleton-bar skeleton-bar--title"></div>
            </div>
            <div class="skeleton-card__body">
              <div class="skeleton-bar skeleton-bar--lg"></div>
              <div class="skeleton-bar skeleton-bar--sm"></div>
              <div class="skeleton-bar skeleton-bar--md"></div>
            </div>
          </div>
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

        <section class="hero-panel" aria-label="AI Fabric mission and core workflows">
          <div class="hero-panel__copy">
            <span class="hero-panel__eyebrow">AI ops and governance</span>
            <ui5-title level="H2">Operate retrieval, validation, and governance from one console.</ui5-title>
            <p>
              Use this dashboard to confirm backend health, move into Search Studio or Data Quality,
              and keep expert tooling available without letting it dominate the primary workflow.
            </p>
          </div>
          <div class="hero-panel__metrics">
            <div class="hero-metric">
              <span class="hero-metric__label">Healthy services</span>
              <span class="hero-metric__value">{{ stats.servicesHealthy }}/{{ stats.totalServices }}</span>
            </div>
            <div class="hero-metric">
              <span class="hero-metric__label">Deployments</span>
              <span class="hero-metric__value">{{ stats.activeDeployments }}</span>
            </div>
            <div class="hero-metric">
              <span class="hero-metric__label">Active alerts</span>
              <span class="hero-metric__value">{{ getActiveAlertCount() }}</span>
            </div>
          </div>
          <div class="hero-panel__actions">
            <ui5-button design="Emphasized" icon="documents" (click)="goTo('/rag')">Search Studio</ui5-button>
            <ui5-button design="Default" icon="validate" (click)="goTo('/data-quality')">Data Quality</ui5-button>
            <ui5-button design="Default" icon="machine" (click)="goTo('/deployments')">Deployments</ui5-button>
            <ui5-button design="Default" icon="shield" (click)="goTo('/governance')">Governance</ui5-button>
          </div>
        </section>

        <!-- Stats Cards Row -->
        <div class="stats-grid" *ngIf="!loading">
          
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
            <div class="card-content" *ngIf="stats.activeDeployments > 0">
              <div class="stat-value">{{ stats.activeDeployments }}</div>
              <div class="stat-label">Active Models</div>
              <ui5-progress-indicator
                [value]="getDeploymentPercentage()"
                valueState="Positive">
              </ui5-progress-indicator>
            </div>
            <app-empty-state
              *ngIf="stats.activeDeployments === 0"
              icon="machine"
              title="No Active Deployments"
              description="Deploy your first model to get started."
              actionText="Go to Deployments"
              actionIcon="add"
              (actionClicked)="goTo('/deployments')">
            </app-empty-state>
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
            title-text="Expert Tools"
            subtitle-text="Secondary and specialist surfaces"
            interactive
            (click)="toggleActions()">
            <ui5-icon slot="action" [name]="showActions ? 'slim-arrow-up' : 'slim-arrow-down'"></ui5-icon>
          </ui5-card-header>
          <div class="quick-actions" *ngIf="showActions">
            <ui5-button design="Emphasized" icon="add" (click)="goTo('/playground')">
              PAL Workbench
            </ui5-button>
            <ui5-button design="Default" icon="search" (click)="goTo('/streaming')">
              Search Ops
            </ui5-button>
            <ui5-button design="Default" icon="database" (click)="goTo('/data')">
              Data Explorer
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

    .hero-panel {
      display: grid;
      gap: 1rem;
      margin-bottom: 1rem;
      padding: 1.5rem;
      border-radius: 1rem;
      background: linear-gradient(135deg, rgba(255, 255, 255, 0.96), rgba(232, 244, 253, 0.7));
      border: 1px solid color-mix(in srgb, var(--sapList_BorderColor) 88%, white);
      box-shadow: var(--sapContent_Shadow1);
    }

    .hero-panel__copy {
      display: grid;
      gap: 0.5rem;
    }

    .hero-panel__copy ui5-title,
    .hero-panel__copy p {
      margin: 0;
    }

    .hero-panel__copy p {
      color: var(--sapContent_LabelColor);
      max-width: 48rem;
      line-height: 1.5;
    }

    .hero-panel__eyebrow {
      display: inline-flex;
      width: fit-content;
      padding: 0.25rem 0.55rem;
      border-radius: 999px;
      background: color-mix(in srgb, var(--sapBrandColor) 12%, white);
      color: var(--sapBrandColor);
      font-size: 0.75rem;
      font-weight: 700;
      text-transform: uppercase;
      letter-spacing: 0.04em;
    }

    .hero-panel__metrics {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(180px, 1fr));
      gap: 0.75rem;
    }

    .hero-metric {
      display: grid;
      gap: 0.25rem;
      padding: 0.9rem 1rem;
      border-radius: 0.85rem;
      background: rgba(255, 255, 255, 0.84);
      border: 1px solid color-mix(in srgb, var(--sapList_BorderColor) 88%, white);
    }

    .hero-metric__label {
      color: var(--sapContent_LabelColor);
      font-size: var(--sapFontSmallSize);
      font-weight: 700;
      text-transform: uppercase;
      letter-spacing: 0.04em;
    }

    .hero-metric__value {
      color: var(--sapTextColor);
      font-size: 1.25rem;
      font-weight: 700;
    }

    .hero-panel__actions {
      display: flex;
      gap: 0.5rem;
      flex-wrap: wrap;
    }
    
    .stats-grid {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(280px, 1fr));
      gap: 1rem;
      margin-bottom: 1rem;
    }

    .stat-card {
      min-height: 180px;
      max-width: 400px;
      transition: box-shadow 0.2s ease, transform 0.2s ease;
      animation: cardEnter 0.3s ease-out both;
    }

    .stat-card:nth-child(1) { animation-delay: 0ms; }
    .stat-card:nth-child(2) { animation-delay: 50ms; }
    .stat-card:nth-child(3) { animation-delay: 100ms; }
    .stat-card:nth-child(4) { animation-delay: 150ms; }
    .stat-card:nth-child(5) { animation-delay: 200ms; }

    .stat-card:hover {
      transform: translateY(-2px);
      box-shadow: 0 8px 24px rgba(0, 0, 0, 0.12);
    }

    @keyframes cardEnter {
      from { opacity: 0; transform: translateY(12px); }
      to { opacity: 1; transform: translateY(0); }
    }

    /* Skeleton Cards */
    .skeleton-card {
      min-height: 180px;
      max-width: 400px;
      border-radius: 0.75rem;
      border: 1px solid var(--sapList_BorderColor);
      background: var(--sapGroup_ContentBackground, #fff);
      overflow: hidden;
      animation: cardEnter 0.3s ease-out both;
    }

    .skeleton-card:nth-child(1) { animation-delay: 0ms; }
    .skeleton-card:nth-child(2) { animation-delay: 50ms; }
    .skeleton-card:nth-child(3) { animation-delay: 100ms; }
    .skeleton-card:nth-child(4) { animation-delay: 150ms; }

    .skeleton-card__header {
      display: flex;
      align-items: center;
      gap: 0.75rem;
      padding: 1rem;
      border-bottom: 1px solid var(--sapList_BorderColor);
    }

    .skeleton-card__body {
      display: flex;
      flex-direction: column;
      gap: 0.6rem;
      padding: 1rem;
    }

    .skeleton-bar {
      border-radius: 0.375rem;
      background: linear-gradient(90deg, var(--sapList_Background, #f5f5f5) 25%, rgba(255,255,255,0.6) 50%, var(--sapList_Background, #f5f5f5) 75%);
      background-size: 200% 100%;
      animation: shimmer 1.5s ease-in-out infinite;
    }

    .skeleton-bar--circle { width: 2rem; height: 2rem; border-radius: 50%; flex-shrink: 0; }
    .skeleton-bar--title { height: 0.875rem; width: 60%; }
    .skeleton-bar--lg { height: 2rem; width: 40%; }
    .skeleton-bar--sm { height: 0.75rem; width: 55%; }
    .skeleton-bar--md { height: 0.75rem; width: 80%; }

    @keyframes shimmer {
      0% { background-position: 200% 0; }
      100% { background-position: -200% 0; }
    }

    @media (prefers-reduced-motion: reduce) {
      .skeleton-bar { animation: none; }
      .stat-card, .skeleton-card { animation: none; }
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

      .hero-panel {
        padding: 1rem;
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
  showActions = false;
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
