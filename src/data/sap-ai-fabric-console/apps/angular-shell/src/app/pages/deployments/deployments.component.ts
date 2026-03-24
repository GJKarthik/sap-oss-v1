import { Component, DestroyRef, OnInit, inject } from '@angular/core';
import { CommonModule } from '@angular/common';
import { Ui5WebcomponentsModule } from '@ui5/webcomponents-ngx';
import { takeUntilDestroyed } from '@angular/core/rxjs-interop';
import { Observable, switchMap } from 'rxjs';
import {
  Deployment,
  DeploymentCreateRequest,
  DeploymentListResponse,
  DeploymentsService,
} from '../../services/api/deployments.service';

@Component({
  selector: 'app-deployments',
  standalone: true,
  imports: [CommonModule, Ui5WebcomponentsModule],
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
            [additionalText]="deploymentCount + ''">
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
              <ui5-table-cell>{{ deployment.target_status || 'n/a' }}</ui5-table-cell>
              <ui5-table-cell>{{ deployment.scenario_id || 'n/a' }}</ui5-table-cell>
              <ui5-table-cell>{{ deployment.creation_time || 'n/a' }}</ui5-table-cell>
            </ui5-table-row>
          </ui5-table>

          <div *ngIf="!loading && deployments.length === 0" class="empty-state">
            No deployments were returned by the backend API.
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
  private readonly deploymentsService = inject(DeploymentsService);
  private readonly destroyRef = inject(DestroyRef);

  deployments: Deployment[] = [];
  deploymentCount = 0;
  loading = false;
  error = '';

  ngOnInit(): void {
    this.refresh();
  }

  refresh(): void {
    this.loading = true;
    this.error = '';

    this.deploymentsService.listDeployments()
      .pipe(takeUntilDestroyed(this.destroyRef))
      .subscribe({
        next: response => {
          this.applyDeploymentList(response);
          this.loading = false;
        },
        error: () => {
          this.error = 'Failed to load deployment data.';
          this.loading = false;
        }
      });
  }

  createDeployment(body: DeploymentCreateRequest): void {
    this.runDeploymentMutation(
      this.deploymentsService.createDeployment(body).pipe(
        switchMap(createdDeployment => this.deploymentsService.getDeployment(createdDeployment.id))
      ),
      deployment => {
        const nextDeployments = [deployment, ...this.deployments.filter(item => item.id !== deployment.id)];
        this.deployments = nextDeployments;
        this.deploymentCount = nextDeployments.length;
      },
      'Failed to create deployment.'
    );
  }

  deleteDeployment(deploymentId: string): void {
    this.loading = true;
    this.error = '';

    this.deploymentsService.deleteDeployment(deploymentId)
      .pipe(
        switchMap(() => this.deploymentsService.listDeployments()),
        takeUntilDestroyed(this.destroyRef)
      )
      .subscribe({
        next: response => {
          this.applyDeploymentList(response);
          this.loading = false;
        },
        error: () => {
          this.error = 'Failed to delete deployment.';
          this.loading = false;
        }
      });
  }

  updateDeploymentStatus(deploymentId: string, targetStatus: string): void {
    this.runDeploymentMutation(
      this.deploymentsService.updateDeploymentStatus(deploymentId, targetStatus).pipe(
        switchMap(({ id }) => this.deploymentsService.getDeployment(id))
      ),
      deployment => {
        this.deployments = this.deployments.map(item => item.id === deployment.id ? deployment : item);
      },
      'Failed to update deployment status.'
    );
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

  private applyDeploymentList(response: DeploymentListResponse): void {
    this.deployments = response.resources;
    this.deploymentCount = response.count;
  }

  private runDeploymentMutation(
    request$: Observable<Deployment>,
    onSuccess: (deployment: Deployment) => void,
    errorMessage: string
  ): void {
    this.loading = true;
    this.error = '';

    request$
      .pipe(takeUntilDestroyed(this.destroyRef))
      .subscribe({
        next: deployment => {
          onSuccess(deployment);
          this.loading = false;
        },
        error: () => {
          this.error = errorMessage;
          this.loading = false;
        }
      });
  }
}
