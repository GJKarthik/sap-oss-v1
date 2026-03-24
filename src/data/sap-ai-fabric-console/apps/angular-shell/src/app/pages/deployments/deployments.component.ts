import { Component, DestroyRef, OnInit, ViewChild, inject } from '@angular/core';
import { CommonModule } from '@angular/common';
import { FormsModule } from '@angular/forms';
import { Ui5WebcomponentsModule } from '@ui5/webcomponents-ngx';
import { takeUntilDestroyed } from '@angular/core/rxjs-interop';
import { AuthService } from '../../services/auth.service';
import { Deployment, McpService } from '../../services/mcp.service';
import { 
  ConfirmationDialogComponent, 
  ConfirmationDialogData, 
  EmptyStateComponent,
  DateFormatPipe 
} from '../../shared';

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
  imports: [CommonModule, FormsModule, Ui5WebcomponentsModule, ConfirmationDialogComponent, EmptyStateComponent, DateFormatPipe],
  template: `
    <ui5-page background-design="Solid">
      <ui5-bar slot="header" design="Header">
        <ui5-title slot="startContent" level="H3">Deployments</ui5-title>
        <ui5-button
          *ngIf="canManage"
          slot="endContent"
          design="Emphasized"
          icon="add"
          (click)="toggleCreateForm()"
          aria-label="Create new deployment">
          {{ showCreateForm ? 'Close Form' : 'New Deployment' }}
        </ui5-button>
        <ui5-button 
          slot="endContent" 
          icon="refresh" 
          (click)="refresh()" 
          [disabled]="loading || mutating"
          aria-label="Refresh deployments list">
          {{ loading ? 'Loading...' : 'Refresh' }}
        </ui5-button>
      </ui5-bar>

      <div class="deployments-content" role="region" aria-label="Deployments management">
        <!-- Loading indicator -->
        <div class="loading-container" *ngIf="loading" role="status" aria-live="polite">
          <ui5-busy-indicator active size="M"></ui5-busy-indicator>
          <span class="loading-text">Loading deployments...</span>
        </div>

        <ui5-message-strip 
          *ngIf="error" 
          design="Negative" 
          [hideCloseButton]="false"
          (close)="error = ''"
          role="alert">
          {{ error }}
        </ui5-message-strip>
        <ui5-message-strip 
          *ngIf="success" 
          design="Positive" 
          [hideCloseButton]="false"
          (close)="success = ''"
          role="status">
          {{ success }}
        </ui5-message-strip>

        <ui5-card *ngIf="showCreateForm && canManage" class="create-card">
          <ui5-card-header
            slot="header"
            title-text="Create Deployment"
            subtitle-text="Track an AI Core scenario inside the console">
          </ui5-card-header>
          <form class="form-grid" (ngSubmit)="createDeployment()">
            <div class="field-group">
              <label for="scenario-id" class="field-label">
                Scenario ID <span class="required" aria-hidden="true">*</span>
              </label>
              <ui5-input
                id="scenario-id"
                ngDefaultControl
                [(ngModel)]="draftScenarioId"
                name="scenarioId"
                placeholder="foundation-model-scenario"
                accessible-name="Scenario ID"
                required>
              </ui5-input>
            </div>
            <div class="field-group">
              <label for="config-json" class="field-label">
                Configuration JSON
              </label>
              <ui5-textarea
                id="config-json"
                ngDefaultControl
                [(ngModel)]="draftConfigurationJson"
                name="configJson"
                [rows]="6"
                growing
                placeholder='{"resourceGroup":"default"}'
                accessible-name="Configuration JSON">
              </ui5-textarea>
            </div>
            <div class="form-actions">
              <ui5-button design="Transparent" (click)="resetCreateForm()" [disabled]="mutating" type="button">
                Cancel
              </ui5-button>
              <ui5-button design="Emphasized" (click)="createDeployment()" [disabled]="mutating || !draftScenarioId.trim()" type="submit">
                <ui5-busy-indicator *ngIf="mutating" active size="S" style="margin-right: 0.5rem;"></ui5-busy-indicator>
                {{ mutating ? 'Creating...' : 'Create' }}
              </ui5-button>
            </div>
          </form>
        </ui5-card>

        <ui5-card [class.loading]="loading">
          <ui5-card-header
            slot="header"
            title-text="Tracked Deployments"
            subtitle-text="Console-managed deployment inventory"
            [additionalText]="deployments.length + ''">
          </ui5-card-header>

          <ui5-table 
            *ngIf="deployments.length > 0" 
            aria-label="Deployments table"
            [class.table-loading]="mutating">
            <ui5-table-header-cell><span>Deployment</span></ui5-table-header-cell>
            <ui5-table-header-cell><span>Status</span></ui5-table-header-cell>
            <ui5-table-header-cell><span>Target</span></ui5-table-header-cell>
            <ui5-table-header-cell><span>Scenario</span></ui5-table-header-cell>
            <ui5-table-header-cell><span>Details</span></ui5-table-header-cell>
            <ui5-table-header-cell><span>Created</span></ui5-table-header-cell>
            <ui5-table-header-cell><span>Actions</span></ui5-table-header-cell>

            <ui5-table-row *ngFor="let deployment of deployments; trackBy: trackByDeploymentId">
              <ui5-table-cell>
                <code class="deployment-id">{{ deployment.id }}</code>
              </ui5-table-cell>
              <ui5-table-cell>
                <ui5-tag [design]="getStatusDesign(deployment.status)">{{ deployment.status }}</ui5-tag>
              </ui5-table-cell>
              <ui5-table-cell>{{ deployment.targetStatus || 'n/a' }}</ui5-table-cell>
              <ui5-table-cell>{{ deployment.scenarioId || 'n/a' }}</ui5-table-cell>
              <ui5-table-cell>{{ summarizeDetails(deployment.details) }}</ui5-table-cell>
              <ui5-table-cell>{{ deployment.creationTime | appDateFormat:'datetime' }}</ui5-table-cell>
              <ui5-table-cell>
                <div class="row-actions" *ngIf="canManage; else readOnlyActions">
                  <ui5-button
                    design="Transparent"
                    (click)="setTargetStatus(deployment, nextTargetStatus(deployment))"
                    [disabled]="mutating"
                    [attr.aria-label]="'Set deployment ' + deployment.id + ' to ' + nextTargetStatus(deployment)">
                    Set {{ nextTargetStatus(deployment) }}
                  </ui5-button>
                  <ui5-button
                    design="Negative"
                    icon="delete"
                    (click)="confirmDelete(deployment)"
                    [disabled]="mutating"
                    [attr.aria-label]="'Delete deployment ' + deployment.id">
                    Delete
                  </ui5-button>
                </div>
                <ng-template #readOnlyActions>
                  <span class="read-only-label">Read only</span>
                </ng-template>
              </ui5-table-cell>
            </ui5-table-row>
          </ui5-table>

          <app-empty-state
            *ngIf="!loading && deployments.length === 0"
            icon="machine"
            title="No Deployments"
            [description]="canManage ? 'No deployments are tracked in the console yet. Create your first deployment to get started.' : 'No deployments are tracked in the console yet.'"
            [actionText]="canManage ? 'New Deployment' : ''"
            actionIcon="add"
            (actionClicked)="toggleCreateForm()">
          </app-empty-state>
        </ui5-card>
      </div>
    </ui5-page>

    <!-- Confirmation Dialog -->
    <app-confirmation-dialog
      #deleteDialog
      [data]="deleteDialogData"
      (confirmed)="executeDelete()"
      (cancelled)="cancelDelete()">
    </app-confirmation-dialog>
  `,
  styles: [`
    .deployments-content {
      padding: 1rem;
      display: flex;
      flex-direction: column;
      gap: 1rem;
      max-width: 1400px;
      margin: 0 auto;
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

    .create-card,
    ui5-card {
      width: 100%;
    }
    
    ui5-card.loading {
      opacity: 0.6;
      pointer-events: none;
    }

    .form-grid {
      padding: 1rem;
      display: grid;
      gap: 1rem;
    }

    .field-group {
      display: flex;
      flex-direction: column;
      gap: 0.5rem;
    }

    .field-label {
      color: var(--sapContent_LabelColor);
      font-weight: 500;
    }

    .required {
      color: var(--sapNegativeColor, #b00);
    }

    .form-actions {
      display: flex;
      gap: 0.5rem;
      justify-content: flex-end;
      padding-top: 0.5rem;
      border-top: 1px solid var(--sapList_BorderColor);
    }

    .table-loading {
      opacity: 0.6;
      pointer-events: none;
    }

    .deployment-id {
      font-family: monospace;
      font-size: var(--sapFontSmallSize);
      background: var(--sapList_Background);
      padding: 0.125rem 0.375rem;
      border-radius: 4px;
    }

    .row-actions {
      display: flex;
      gap: 0.5rem;
      flex-wrap: wrap;
    }

    .read-only-label {
      color: var(--sapContent_LabelColor);
      font-size: var(--sapFontSmallSize);
    }

    /* Responsive styles */
    @media (max-width: 768px) {
      .deployments-content {
        padding: 0.75rem;
      }

      .row-actions {
        flex-direction: column;
      }
    }
  `]
})
export class DeploymentsComponent implements OnInit {
  @ViewChild('deleteDialog') deleteDialog!: ConfirmationDialogComponent;
  
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

  // Delete confirmation dialog state
  deleteDialogData: ConfirmationDialogData = {
    title: 'Delete Deployment',
    message: 'Are you sure you want to delete this deployment? This action cannot be undone.',
    confirmText: 'Delete',
    cancelText: 'Cancel',
    confirmDesign: 'Negative',
    icon: 'warning'
  };
  private deploymentToDelete: Deployment | null = null;

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

  // TrackBy function for ngFor optimization
  trackByDeploymentId(index: number, deployment: Deployment): string {
    return deployment.id;
  }

  // Confirmation dialog methods
  confirmDelete(deployment: Deployment): void {
    this.deploymentToDelete = deployment;
    this.deleteDialogData = {
      ...this.deleteDialogData,
      itemName: deployment.id
    };
    this.deleteDialog.open();
  }

  executeDelete(): void {
    if (this.deploymentToDelete) {
      this.deleteDeployment(this.deploymentToDelete);
      this.deploymentToDelete = null;
    }
  }

  cancelDelete(): void {
    this.deploymentToDelete = null;
  }
}
