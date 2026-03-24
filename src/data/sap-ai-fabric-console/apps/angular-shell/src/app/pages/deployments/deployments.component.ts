import { Component, DestroyRef, OnInit, inject } from '@angular/core';
import { CommonModule } from '@angular/common';
import { FormsModule } from '@angular/forms';
import { Ui5WebcomponentsModule } from '@ui5/webcomponents-ngx';
import { takeUntilDestroyed } from '@angular/core/rxjs-interop';
import { AuthService } from '../../services/auth.service';
import { Deployment, McpService } from '../../services/mcp.service';

function readErrorMessage(error: unknown, fallback: string): string {
  const detail = (error as { error?: { detail?: string } | string; message?: string })?.error;
  if (typeof detail === 'string' && detail.trim()) {
    return detail;
  }
  if (detail && typeof detail === 'object' && 'detail' in detail && typeof detail.detail === 'string') {
    return detail.detail;
  }
  const message = (error as { message?: string })?.message;
  return message?.trim() ? message : fallback;
}

@Component({
  selector: 'app-deployments',
  standalone: true,
  imports: [CommonModule, FormsModule, Ui5WebcomponentsModule],
  template: `
    <ui5-page background-design="Solid">
      <ui5-bar slot="header" design="Header">
        <ui5-title slot="startContent" level="H3">Deployments</ui5-title>
        <ui5-button
          *ngIf="canManage"
          slot="endContent"
          design="Emphasized"
          icon="add"
          (click)="toggleCreateForm()">
          {{ showCreateForm ? 'Close Form' : 'New Deployment' }}
        </ui5-button>
        <ui5-button slot="endContent" icon="refresh" (click)="refresh()" [disabled]="loading || mutating">
          Refresh
        </ui5-button>
      </ui5-bar>

      <div class="deployments-content">
        <ui5-message-strip *ngIf="error" design="Negative" [hideCloseButton]="true">
          {{ error }}
        </ui5-message-strip>
        <ui5-message-strip *ngIf="success" design="Positive" [hideCloseButton]="true">
          {{ success }}
        </ui5-message-strip>

        <ui5-card *ngIf="showCreateForm && canManage" class="create-card">
          <ui5-card-header
            slot="header"
            title-text="Create Deployment"
            subtitle-text="Track an AI Core scenario inside the console">
          </ui5-card-header>
          <div class="form-grid">
            <label class="field-label">
              Scenario ID
              <ui5-input
                ngDefaultControl
                [(ngModel)]="draftScenarioId"
                placeholder="foundation-model-scenario">
              </ui5-input>
            </label>
            <label class="field-label">
              Configuration JSON
              <ui5-textarea
                ngDefaultControl
                [(ngModel)]="draftConfigurationJson"
                [rows]="6"
                growing
                placeholder='{"resourceGroup":"default"}'>
              </ui5-textarea>
            </label>
            <div class="form-actions">
              <ui5-button design="Emphasized" (click)="createDeployment()" [disabled]="mutating">
                Create
              </ui5-button>
              <ui5-button design="Transparent" (click)="resetCreateForm()" [disabled]="mutating">
                Cancel
              </ui5-button>
            </div>
          </div>
        </ui5-card>

        <ui5-card>
          <ui5-card-header
            slot="header"
            title-text="Tracked Deployments"
            subtitle-text="Console-managed deployment inventory"
            [additionalText]="deployments.length + ''">
          </ui5-card-header>

          <ui5-table *ngIf="deployments.length > 0">
            <ui5-table-header-cell><span>Deployment</span></ui5-table-header-cell>
            <ui5-table-header-cell><span>Status</span></ui5-table-header-cell>
            <ui5-table-header-cell><span>Target</span></ui5-table-header-cell>
            <ui5-table-header-cell><span>Scenario</span></ui5-table-header-cell>
            <ui5-table-header-cell><span>Details</span></ui5-table-header-cell>
            <ui5-table-header-cell><span>Created</span></ui5-table-header-cell>
            <ui5-table-header-cell><span>Actions</span></ui5-table-header-cell>

            <ui5-table-row *ngFor="let deployment of deployments">
              <ui5-table-cell>{{ deployment.id }}</ui5-table-cell>
              <ui5-table-cell>
                <ui5-tag [design]="getStatusDesign(deployment.status)">{{ deployment.status }}</ui5-tag>
              </ui5-table-cell>
              <ui5-table-cell>{{ deployment.targetStatus || 'n/a' }}</ui5-table-cell>
              <ui5-table-cell>{{ deployment.scenarioId || 'n/a' }}</ui5-table-cell>
              <ui5-table-cell>{{ summarizeDetails(deployment.details) }}</ui5-table-cell>
              <ui5-table-cell>{{ formatDate(deployment.creationTime) }}</ui5-table-cell>
              <ui5-table-cell>
                <div class="row-actions" *ngIf="canManage; else readOnlyActions">
                  <ui5-button
                    design="Transparent"
                    (click)="setTargetStatus(deployment, nextTargetStatus(deployment))"
                    [disabled]="mutating">
                    Set {{ nextTargetStatus(deployment) }}
                  </ui5-button>
                  <ui5-button
                    design="Negative"
                    icon="delete"
                    (click)="deleteDeployment(deployment)"
                    [disabled]="mutating">
                    Delete
                  </ui5-button>
                </div>
                <ng-template #readOnlyActions>
                  <span class="read-only-label">Read only</span>
                </ng-template>
              </ui5-table-cell>
            </ui5-table-row>
          </ui5-table>

          <div *ngIf="!loading && deployments.length === 0" class="empty-state">
            No deployments are tracked in the console yet.
            <span *ngIf="canManage">Use “New Deployment” to create the first one.</span>
          </div>
        </ui5-card>
      </div>
    </ui5-page>
  `,
  styles: [`
    .deployments-content {
      padding: 1rem;
      display: flex;
      flex-direction: column;
      gap: 1rem;
    }

    ui5-message-strip {
      margin-bottom: 0;
    }

    .create-card,
    ui5-card {
      width: 100%;
    }

    .form-grid {
      padding: 1rem;
      display: grid;
      gap: 1rem;
    }

    .field-label {
      display: grid;
      gap: 0.5rem;
      color: var(--sapContent_LabelColor);
    }

    .form-actions {
      display: flex;
      gap: 0.5rem;
      justify-content: flex-end;
    }

    .row-actions {
      display: flex;
      gap: 0.5rem;
      flex-wrap: wrap;
    }

    .empty-state {
      padding: 1rem;
      color: var(--sapContent_LabelColor);
      display: flex;
      flex-direction: column;
      gap: 0.25rem;
    }

    .read-only-label {
      color: var(--sapContent_LabelColor);
      font-size: var(--sapFontSmallSize);
    }
  `]
})
export class DeploymentsComponent implements OnInit {
  private readonly mcpService = inject(McpService);
  private readonly destroyRef = inject(DestroyRef);
  private readonly authService = inject(AuthService);

  deployments: Deployment[] = [];
  loading = false;
  mutating = false;
  error = '';
  success = '';
  showCreateForm = false;
  draftScenarioId = '';
  draftConfigurationJson = '{\n  "resourceGroup": "default"\n}';
  readonly canManage = this.authService.getUser()?.role === 'admin';

  ngOnInit(): void {
    this.refresh();
  }

  refresh(): void {
    this.loading = true;
    this.error = '';
    this.success = '';

    this.mcpService.fetchDeployments()
      .pipe(takeUntilDestroyed(this.destroyRef))
      .subscribe({
        next: deployments => {
          this.deployments = deployments;
          this.loading = false;
        },
        error: err => {
          this.error = readErrorMessage(err, 'Failed to load deployment data.');
          this.loading = false;
        }
      });
  }

  toggleCreateForm(): void {
    this.showCreateForm = !this.showCreateForm;
    if (!this.showCreateForm) {
      this.resetCreateForm();
    }
  }

  resetCreateForm(): void {
    this.showCreateForm = false;
    this.draftScenarioId = '';
    this.draftConfigurationJson = '{\n  "resourceGroup": "default"\n}';
  }

  createDeployment(): void {
    const scenarioId = this.draftScenarioId.trim();
    if (!scenarioId) {
      this.error = 'Scenario ID is required.';
      return;
    }

    let configuration: Record<string, unknown> = {};
    try {
      configuration = this.draftConfigurationJson.trim()
        ? JSON.parse(this.draftConfigurationJson) as Record<string, unknown>
        : {};
    } catch {
      this.error = 'Configuration JSON is invalid.';
      return;
    }

    this.mutating = true;
    this.error = '';
    this.success = '';
    this.mcpService.createDeployment(scenarioId, configuration)
      .pipe(takeUntilDestroyed(this.destroyRef))
      .subscribe({
        next: deployment => {
          this.deployments = [deployment, ...this.deployments];
          this.success = `Deployment "${deployment.id}" created.`;
          this.mutating = false;
          this.resetCreateForm();
        },
        error: err => {
          this.error = readErrorMessage(err, 'Failed to create deployment.');
          this.mutating = false;
        }
      });
  }

  setTargetStatus(deployment: Deployment, targetStatus: string): void {
    this.mutating = true;
    this.error = '';
    this.success = '';
    this.mcpService.updateDeploymentStatus(deployment.id, targetStatus)
      .pipe(takeUntilDestroyed(this.destroyRef))
      .subscribe({
        next: response => {
          deployment.targetStatus = response.target_status;
          this.success = `Deployment "${deployment.id}" target set to ${response.target_status}.`;
          this.mutating = false;
        },
        error: err => {
          this.error = readErrorMessage(err, `Failed to update deployment "${deployment.id}".`);
          this.mutating = false;
        }
      });
  }

  deleteDeployment(deployment: Deployment): void {
    this.mutating = true;
    this.error = '';
    this.success = '';
    this.mcpService.deleteDeployment(deployment.id)
      .pipe(takeUntilDestroyed(this.destroyRef))
      .subscribe({
        next: () => {
          this.deployments = this.deployments.filter(item => item.id !== deployment.id);
          this.success = `Deployment "${deployment.id}" deleted.`;
          this.mutating = false;
        },
        error: err => {
          this.error = readErrorMessage(err, `Failed to delete deployment "${deployment.id}".`);
          this.mutating = false;
        }
      });
  }

  nextTargetStatus(deployment: Deployment): string {
    return deployment.targetStatus === 'STOPPED' ? 'RUNNING' : 'STOPPED';
  }

  summarizeDetails(details?: Record<string, unknown>): string {
    if (!details || Object.keys(details).length === 0) {
      return 'No config';
    }

    return `${Object.keys(details).length} field${Object.keys(details).length === 1 ? '' : 's'}`;
  }

  formatDate(value?: string): string {
    if (!value) {
      return 'n/a';
    }

    const date = new Date(value);
    return Number.isNaN(date.getTime()) ? value : date.toLocaleString();
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
