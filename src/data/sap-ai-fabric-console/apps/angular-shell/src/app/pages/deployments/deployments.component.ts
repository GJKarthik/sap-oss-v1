import { Component, OnInit, inject } from '@angular/core';
import { Deployment, McpService } from '../../services/mcp.service';

@Component({
  selector: 'app-deployments',
  standalone: false,
  template: `
    <ui5-page background-design="Solid">
      <ui5-bar slot="header" design="Header">
        <ui5-title slot="startContent" level="H3">Deployments</ui5-title>
        <ui5-button slot="endContent" icon="refresh" (click)="refresh()" [disabled]="loading">
          Refresh
        </ui5-button>
      </ui5-bar>

      <div class="deployments-content">
        <ui5-message-strip *ngIf="error" design="Negative" [hideCloseButton]="true">
          {{ error }}
        </ui5-message-strip>

        <ui5-card>
          <ui5-card-header
            slot="header"
            title-text="AI Core Deployments"
            subtitle-text="Current model deployment inventory"
            [additionalText]="deployments.length + ''">
          </ui5-card-header>

          <ui5-table *ngIf="deployments.length > 0">
            <ui5-table-header-cell><span>Deployment</span></ui5-table-header-cell>
            <ui5-table-header-cell><span>Status</span></ui5-table-header-cell>
            <ui5-table-header-cell><span>Target</span></ui5-table-header-cell>
            <ui5-table-header-cell><span>Scenario</span></ui5-table-header-cell>
            <ui5-table-header-cell><span>Created</span></ui5-table-header-cell>

            <ui5-table-row *ngFor="let deployment of deployments">
              <ui5-table-cell>{{ deployment.id }}</ui5-table-cell>
              <ui5-table-cell>
                <ui5-tag [design]="getStatusDesign(deployment.status)">{{ deployment.status }}</ui5-tag>
              </ui5-table-cell>
              <ui5-table-cell>{{ deployment.targetStatus || 'n/a' }}</ui5-table-cell>
              <ui5-table-cell>{{ deployment.scenarioId || 'n/a' }}</ui5-table-cell>
              <ui5-table-cell>{{ deployment.creationTime || 'n/a' }}</ui5-table-cell>
            </ui5-table-row>
          </ui5-table>

          <div *ngIf="!loading && deployments.length === 0" class="empty-state">
            No deployments were returned by the MCP backend.
          </div>
        </ui5-card>
      </div>
    </ui5-page>
  `,
  styles: [`
    .deployments-content {
      padding: 1rem;
    }

    ui5-message-strip {
      margin-bottom: 1rem;
    }

    .empty-state {
      padding: 1rem;
      color: var(--sapContent_LabelColor);
    }
  `]
})
export class DeploymentsComponent implements OnInit {
  private readonly mcpService = inject(McpService);

  deployments: Deployment[] = [];
  loading = false;
  error = '';

  ngOnInit(): void {
    this.refresh();
  }

  refresh(): void {
    this.loading = true;
    this.error = '';

    this.mcpService.fetchDeployments().subscribe({
      next: deployments => {
        this.deployments = deployments;
        this.loading = false;
      },
      error: () => {
        this.error = 'Failed to load deployment data.';
        this.loading = false;
      }
    });
  }

  getStatusDesign(status: string): 'Positive' | 'Critical' | 'Negative' | 'Neutral' {
    const normalizedStatus = status.toLowerCase();
    if (normalizedStatus === 'running' || normalizedStatus === 'completed') {
      return 'Positive';
    }
    if (normalizedStatus === 'failed' || normalizedStatus === 'error') {
      return 'Negative';
    }
    if (normalizedStatus === 'stopped' || normalizedStatus === 'inactive') {
      return 'Critical';
    }
    return 'Neutral';
  }
}
