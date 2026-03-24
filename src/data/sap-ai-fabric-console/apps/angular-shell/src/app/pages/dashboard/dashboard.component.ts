/**
 * Dashboard Component - Angular/UI5 Version
 *
 * Uses UI5 Web Components following ui5-webcomponents-ngx standards
 * Loads dashboard and service health metrics from the backend API
 */

import { Component, DestroyRef, OnInit, inject } from '@angular/core';
import { CommonModule } from '@angular/common';
import { RouterModule } from '@angular/router';
import { FormsModule } from '@angular/forms';
import { Ui5WebcomponentsModule } from '@ui5/webcomponents-ngx';
import { takeUntilDestroyed } from '@angular/core/rxjs-interop';
import { forkJoin } from 'rxjs';

import {
  DashboardStats,
  MetricsService,
  ServiceMetrics,
  ServiceMetricsMap,
  ServiceStatus,
} from '../../services/api/metrics.service';

interface DashboardServiceHealth {
  service: string;
  status: ServiceStatus;
}

@Component({
  selector: 'app-dashboard',
  standalone: true,
  imports: [CommonModule, RouterModule, FormsModule, Ui5WebcomponentsModule],
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
          *ngIf="health.overall === 'degraded' || health.overall === 'error'"
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
              subtitle-text="Backend Service Health"
              [additionalText]="stats.services_healthy + '/' + stats.total_services">
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
              [additionalText]="stats.active_deployments + '/' + stats.total_deployments">
              <ui5-icon slot="avatar" name="machine"></ui5-icon>
            </ui5-card-header>
            <div class="card-content">
              <div class="stat-value">{{ stats.active_deployments }}</div>
              <div class="stat-label">Active Models</div>
              <ui5-progress-indicator 
                [value]="getDeploymentPercentage()"
                [valueState]="stats.active_deployments > 0 ? 'Positive' : 'None'">
              </ui5-progress-indicator>
            </div>
          </ui5-card>

          <!-- Governance Card -->
          <ui5-card class="stat-card">
            <ui5-card-header 
              slot="header" 
              title-text="Governance"
              subtitle-text="Active policy enforcement"
              [additionalText]="stats.governance_rules_active + ''">
              <ui5-icon slot="avatar" name="shield"></ui5-icon>
            </ui5-card-header>
            <div class="card-content">
              <div class="stat-value">{{ stats.governance_rules_active }}</div>
              <div class="stat-label">Rules Active</div>
              <ui5-tag design="Neutral">Policy checks enabled</ui5-tag>
            </div>
          </ui5-card>

          <!-- Vector Stores Card -->
          <ui5-card class="stat-card">
            <ui5-card-header 
              slot="header" 
              title-text="Vector Stores"
              subtitle-text="HANA Cloud Vector"
              [additionalText]="stats.vector_stores + ''">
              <ui5-icon slot="avatar" name="database"></ui5-icon>
            </ui5-card-header>
            <div class="card-content">
              <div class="stat-value">{{ stats.documents_indexed | number }}</div>
              <div class="stat-label">Documents Indexed</div>
              <ui5-tag design="Neutral">{{ stats.vector_stores }} stores</ui5-tag>
            </div>
          </ui5-card>

          <!-- Users Card -->
          <ui5-card class="stat-card">
            <ui5-card-header 
              slot="header" 
              title-text="Users"
              subtitle-text="Registered platform access"
              [additionalText]="stats.registered_users + ''">
              <ui5-icon slot="avatar" name="employee"></ui5-icon>
            </ui5-card-header>
            <div class="card-content">
              <div class="stat-value">{{ stats.registered_users }}</div>
              <div class="stat-label">Registered Users</div>
              <ui5-tag design="Neutral">Workspace access</ui5-tag>
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
export class DashboardComponent implements OnInit {
  private readonly metricsService = inject(MetricsService);
  private readonly destroyRef = inject(DestroyRef);
  
  loading = true;
  showActions = true;
  
  stats: DashboardStats = {
    services_healthy: 0,
    total_services: 0,
    active_deployments: 0,
    total_deployments: 0,
    vector_stores: 0,
    documents_indexed: 0,
    governance_rules_active: 0,
    registered_users: 0,
  };
  
  health: {
    langchain: DashboardServiceHealth | null;
    streaming: DashboardServiceHealth | null;
    overall: ServiceStatus;
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
    this.refresh();
  }

  refresh(): void {
    this.loading = true;
    forkJoin({
      stats: this.metricsService.getDashboardStats(),
      serviceMetrics: this.metricsService.getServiceMetrics(),
    })
      .pipe(takeUntilDestroyed(this.destroyRef))
      .subscribe({
        next: ({ stats, serviceMetrics }) => {
          this.stats = stats;
          this.health = this.mapHealth(serviceMetrics);
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
      return 'All backend services are unavailable. Please check the metrics API.';
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
    if (this.stats.total_deployments === 0) return 0;
    return Math.round((this.stats.active_deployments / this.stats.total_deployments) * 100);
  }

  private mapHealth(serviceMetrics: ServiceMetricsMap): {
    langchain: DashboardServiceHealth | null;
    streaming: DashboardServiceHealth | null;
    overall: ServiceStatus;
  } {
    const langchain = this.toServiceHealth(
      this.findServiceMetrics(serviceMetrics, ['langchain-hana-mcp', 'langchain-hana']),
      'langchain-hana-mcp'
    );
    const streaming = this.toServiceHealth(
      this.findServiceMetrics(serviceMetrics, ['ai-core-streaming-mcp', 'ai-core-streaming']),
      'ai-core-streaming-mcp'
    );

    return {
      langchain,
      streaming,
      overall: this.getOverallHealth([langchain, streaming]),
    };
  }

  private findServiceMetrics(
    serviceMetrics: ServiceMetricsMap,
    serviceNames: string[]
  ): ServiceMetrics | null {
    for (const serviceName of serviceNames) {
      if (serviceMetrics[serviceName]) {
        return serviceMetrics[serviceName];
      }
    }

    return null;
  }

  private toServiceHealth(
    serviceMetrics: ServiceMetrics | null,
    fallbackServiceName: string
  ): DashboardServiceHealth | null {
    if (!serviceMetrics) {
      return null;
    }

    return {
      service: serviceMetrics.service || fallbackServiceName,
      status: this.getServiceStatus(serviceMetrics),
    };
  }

  private getServiceStatus(serviceMetrics: ServiceMetrics): ServiceStatus {
    if (serviceMetrics.status) {
      return serviceMetrics.status;
    }

    if (serviceMetrics.error_rate >= 1) {
      return 'error';
    }

    if (serviceMetrics.error_rate > 0) {
      return 'degraded';
    }

    return 'healthy';
  }

  private getOverallHealth(services: Array<DashboardServiceHealth | null>): ServiceStatus {
    const statuses = services
      .map(service => service?.status)
      .filter((status): status is ServiceStatus => Boolean(status));

    if (statuses.length === 0) {
      return 'unknown';
    }

    if (statuses.every(status => status === 'healthy')) {
      return 'healthy';
    }

    if (statuses.every(status => status === 'error')) {
      return 'error';
    }

    if (statuses.every(status => status === 'unknown')) {
      return 'unknown';
    }

    return 'degraded';
  }

  toggleActions(): void {
    this.showActions = !this.showActions;
  }
}
