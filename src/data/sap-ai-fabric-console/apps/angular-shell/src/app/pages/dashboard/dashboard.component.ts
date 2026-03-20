/**
 * Dashboard Component - Angular/UI5 Version
 * 
 * Uses UI5 Web Components following ui5-webcomponents-ngx standards
 * Connects to real MCP backends (langchain-hana, ai-core-streaming)
 */

import { Component, OnDestroy, OnInit, inject } from '@angular/core';
import { Subject, takeUntil } from 'rxjs';
import { McpService, DashboardStats, ServiceHealth } from '../../services/mcp.service';

@Component({
  selector: 'app-dashboard',
  standalone: false,
  template: `
    <!-- Page Header -->
    <ui5-page background-design="Solid">
      <ui5-bar slot="header" design="Header">
        <ui5-title slot="startContent" level="H3">Dashboard</ui5-title>
        <ui5-button slot="endContent" icon="refresh" (click)="refresh()">
          Refresh
        </ui5-button>
      </ui5-bar>

      <!-- Main Content -->
      <div class="dashboard-content">
        
        <!-- Health Status Banner -->
        <ui5-message-strip 
          *ngIf="health.overall !== 'healthy'"
          [design]="health.overall === 'error' ? 'Negative' : 'Critical'"
          [hideCloseButton]="true">
          {{ getHealthMessage() }}
        </ui5-message-strip>

        <!-- Stats Cards Row -->
        <div class="stats-grid">
          
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
                <ui5-icon [name]="health.langchain?.status === 'healthy' ? 'status-positive' : 'status-negative'"></ui5-icon>
                <span>LangChain HANA</span>
                <ui5-tag [design]="health.langchain?.status === 'healthy' ? 'Positive' : 'Negative'">
                  {{ health.langchain?.status || 'Unknown' }}
                </ui5-tag>
              </div>
              <div class="service-item">
                <ui5-icon [name]="health.streaming?.status === 'healthy' ? 'status-positive' : 'status-negative'"></ui5-icon>
                <span>AI Core Streaming</span>
                <ui5-tag [design]="health.streaming?.status === 'healthy' ? 'Positive' : 'Negative'">
                  {{ health.streaming?.status || 'Unknown' }}
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

          <!-- Streams Card -->
          <ui5-card class="stat-card">
            <ui5-card-header 
              slot="header" 
              title-text="Active Streams"
              subtitle-text="Streaming Sessions"
              [additionalText]="stats.activeStreams + ''">
              <ui5-icon slot="avatar" name="play"></ui5-icon>
            </ui5-card-header>
            <div class="card-content">
              <div class="stat-value">{{ stats.activeStreams }}</div>
              <div class="stat-label">Live Connections</div>
              <ui5-tag design="Neutral">{{ stats.totalStreams }} total</ui5-tag>
            </div>
          </ui5-card>

          <!-- Vector Stores Card -->
          <ui5-card class="stat-card">
            <ui5-card-header 
              slot="header" 
              title-text="Vector Stores"
              subtitle-text="HANA Cloud Vector"
              [additionalText]="stats.vectorStores + ''">
              <ui5-icon slot="avatar" name="database"></ui5-icon>
            </ui5-card-header>
            <div class="card-content">
              <div class="stat-value">{{ stats.documentsIndexed | number }}</div>
              <div class="stat-label">Documents Indexed</div>
              <ui5-tag design="Neutral">{{ stats.vectorStores }} stores</ui5-tag>
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
            <ui5-button design="Emphasized" icon="add" routerLink="/playground">
              New Chat
            </ui5-button>
            <ui5-button design="Default" icon="documents" routerLink="/rag">
              RAG Studio
            </ui5-button>
            <ui5-button design="Default" icon="database" routerLink="/data">
              Data Explorer
            </ui5-button>
            <ui5-button design="Default" icon="org-chart" routerLink="/lineage">
              Lineage View
            </ui5-button>
          </div>
        </ui5-card>

        <!-- Recent Activity Table -->
        <ui5-card class="activity-card">
          <ui5-card-header 
            slot="header" 
            title-text="Recent Activity"
            subtitle-text="Last 24 hours">
          </ui5-card-header>
          <ui5-table>
            <ui5-table-header-cell><span>Event</span></ui5-table-header-cell>
            <ui5-table-header-cell><span>Service</span></ui5-table-header-cell>
            <ui5-table-header-cell><span>Status</span></ui5-table-header-cell>
            <ui5-table-header-cell><span>Time</span></ui5-table-header-cell>
            
            <ui5-table-row *ngFor="let activity of recentActivity">
              <ui5-table-cell>{{ activity.event }}</ui5-table-cell>
              <ui5-table-cell>{{ activity.service }}</ui5-table-cell>
              <ui5-table-cell>
                <ui5-tag [design]="activity.status === 'success' ? 'Positive' : 'Negative'">
                  {{ activity.status }}
                </ui5-tag>
              </ui5-table-cell>
              <ui5-table-cell>{{ activity.time }}</ui5-table-cell>
            </ui5-table-row>
          </ui5-table>
        </ui5-card>
      </div>
    </ui5-page>
  `,
  styles: [`
    .dashboard-content {
      padding: 1rem;
      max-width: 1400px;
      margin: 0 auto;
    }
    
    .stats-grid {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(280px, 1fr));
      gap: 1rem;
      margin-bottom: 1rem;
    }
    
    .stat-card {
      min-height: 180px;
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
    
    .activity-card {
      margin-top: 1rem;
    }
    
    ui5-message-strip {
      margin-bottom: 1rem;
    }
  `]
})
export class DashboardComponent implements OnInit, OnDestroy {
  private readonly mcpService = inject(McpService);
  private destroy$ = new Subject<void>();
  
  loading = true;
  showActions = true;
  
  stats: DashboardStats = {
    servicesHealthy: 0,
    totalServices: 2,
    activeDeployments: 0,
    totalDeployments: 0,
    activeStreams: 0,
    totalStreams: 0,
    vectorStores: 0,
    documentsIndexed: 0,
    overallHealth: 'unknown'
  };
  
  health: {
    langchain: ServiceHealth | null;
    streaming: ServiceHealth | null;
    overall: 'healthy' | 'degraded' | 'error' | 'unknown';
  } = {
    langchain: null,
    streaming: null,
    overall: 'unknown'
  };
  
  recentActivity = [
    { event: 'RAG Query', service: 'langchain-hana', status: 'success', time: '2 min ago' },
    { event: 'Stream Started', service: 'ai-core-streaming', status: 'success', time: '15 min ago' },
    { event: 'Document Indexed', service: 'langchain-hana', status: 'success', time: '1 hour ago' },
  ];

  ngOnInit(): void {
    // Subscribe to health updates
    this.mcpService.health$
      .pipe(takeUntil(this.destroy$))
      .subscribe(health => {
        this.health = health;
      });
    
    // Load dashboard stats
    this.refresh();
  }

  ngOnDestroy(): void {
    this.destroy$.next();
    this.destroy$.complete();
  }

  refresh(): void {
    this.loading = true;
    this.mcpService.getDashboardStats()
      .pipe(takeUntil(this.destroy$))
      .subscribe({
        next: (stats) => {
          this.stats = stats;
          this.loading = false;
        },
        error: (err) => {
          console.error('Failed to load dashboard stats:', err);
          this.loading = false;
        }
      });
  }

  getHealthMessage(): string {
    if (this.health.overall === 'error') {
      return 'All backend services are unavailable. Please check the MCP servers.';
    }
    if (this.health.overall === 'degraded') {
      const issues = [];
      if (this.health.langchain?.status !== 'healthy') {
        issues.push('LangChain HANA');
      }
      if (this.health.streaming?.status !== 'healthy') {
        issues.push('AI Core Streaming');
      }
      return `Some services are degraded: ${issues.join(', ')}`;
    }
    return '';
  }

  getDeploymentPercentage(): number {
    if (this.stats.totalDeployments === 0) return 0;
    return Math.round((this.stats.activeDeployments / this.stats.totalDeployments) * 100);
  }

  toggleActions(): void {
    this.showActions = !this.showActions;
  }
}
