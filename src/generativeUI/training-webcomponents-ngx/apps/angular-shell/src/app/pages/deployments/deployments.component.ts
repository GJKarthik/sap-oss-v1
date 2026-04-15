import { Component, DestroyRef, OnInit, ViewChild, inject } from '@angular/core';
import { CommonModule } from '@angular/common';
import { FormsModule } from '@angular/forms';
import { forkJoin } from 'rxjs';
import { takeUntilDestroyed } from '@angular/core/rxjs-interop';
import { Ui5TrainingComponentsModule } from '../../shared/ui5-training-components.module';
import { I18nService } from '../../services/i18n.service';
import {
  ConfirmationDialogComponent,
  ConfirmationDialogData,
  EmptyStateComponent,
  DateFormatPipe,
  CrossAppLinkComponent
} from '../../shared';
import { TranslatePipe } from '../../shared/pipes/translate.pipe';
import {
  TrainingGovernanceService,
  type TrainingJobResponse,
  type TrainingRun,
} from '../../services/training-governance.service';

interface DeploymentRow {
  id: string;
  status: string;
  details?: Record<string, unknown>;
  targetStatus?: string;
  scenarioId?: string;
  creationTime?: string;
  gateStatus: string;
  approvalStatus: string;
  jobId?: string | null;
  run: TrainingRun;
}

function readBlockingMessage(error: unknown, fallback: string): string {
  const detail = (error as { error?: { detail?: { blocking_checks?: Array<{ detail: string }>; message?: string } | string } })?.error?.detail;
  if (typeof detail === 'string' && detail.trim()) {
    return detail;
  }
  if (detail && typeof detail === 'object' && Array.isArray(detail.blocking_checks) && detail.blocking_checks.length) {
    return detail.blocking_checks.map((check) => check.detail).join(' | ');
  }
  return fallback;
}

@Component({
  selector: 'app-deployments',
  standalone: true,
  imports: [CommonModule, FormsModule, Ui5TrainingComponentsModule, ConfirmationDialogComponent, EmptyStateComponent, DateFormatPipe, CrossAppLinkComponent, TranslatePipe],
  template: `
    <ui5-page background-design="Solid">
      <ui5-bar slot="header" design="Header">
        <ui5-title slot="startContent" level="H3">{{ 'deployments.title' | translate }}</ui5-title>
        <ui5-button
          *ngIf="canManage"
          slot="endContent"
          design="Emphasized"
          icon="add"
          (click)="toggleCreateForm()"
          [attr.aria-label]="i18n.t('deployments.createNewDeployment')">
          {{ showCreateForm ? ('deployments.closeForm' | translate) : ('deployments.newDeployment' | translate) }}
        </ui5-button>
        <ui5-button
          slot="endContent"
          icon="refresh"
          (click)="refresh()"
          [disabled]="loading || mutating"
          [attr.aria-label]="i18n.t('deployments.refreshDeployments')">
          {{ loading ? ('common.loading' | translate) : ('common.refresh' | translate) }}
        </ui5-button>
      </ui5-bar>

      <app-cross-app-link
        targetApp="training"
        targetRoute="/registry"
        targetLabelKey="nav.registry"
        icon="database">
      </app-cross-app-link>

      <div class="deployments-content" role="region" [attr.aria-label]="i18n.t('deployments.deploymentsManagement')">
        <div class="loading-container" *ngIf="loading" role="status" aria-live="polite">
          <ui5-busy-indicator active size="M"></ui5-busy-indicator>
          <span class="loading-text">Loading governed deployment runs…</span>
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
            title-text="Create governed deployment"
            subtitle-text="Select a completed optimization job and submit it through deployment governance">
          </ui5-card-header>
          <form class="form-grid" (ngSubmit)="createDeployment()">
            <div class="field-group">
              <label for="job-id" class="field-label">Completed job <span class="required" aria-hidden="true">*</span></label>
              <select id="job-id" [(ngModel)]="selectedJobId" name="jobId" class="native-select" required>
                <option value="">Select a completed job</option>
                <option *ngFor="let job of deploymentCandidates" [value]="job.id">
                  {{ job.config['model_name'] || job.id }} · {{ job.id }}
                </option>
              </select>
            </div>
            <div class="field-group">
              <label for="scenario-id" class="field-label">Scenario / release label</label>
              <ui5-input
                id="scenario-id"
                ngDefaultControl
                [(ngModel)]="draftScenarioId"
                name="scenarioId"
                placeholder="production-release"
                accessibleName="Scenario or release label">
              </ui5-input>
            </div>
            <div class="field-group">
              <label for="config-json" class="field-label">Deployment configuration JSON</label>
              <ui5-textarea
                id="config-json"
                ngDefaultControl
                [(ngModel)]="draftConfigurationJson"
                name="configJson"
                [rows]="6"
                growing
                placeholder='{"resourceGroup":"default"}'
                accessibleName="Deployment configuration">
              </ui5-textarea>
            </div>
            <div class="form-actions">
              <ui5-button design="Transparent" (click)="resetCreateForm()" [disabled]="mutating" type="Button">
                {{ 'common.cancel' | translate }}
              </ui5-button>
              <ui5-button design="Emphasized" (click)="createDeployment()" [disabled]="mutating || !selectedJobId" type="Submit">
                <ui5-busy-indicator *ngIf="mutating" active size="S" style="margin-right: 0.5rem;"></ui5-busy-indicator>
                Submit deployment run
              </ui5-button>
            </div>
          </form>
        </ui5-card>

        <ui5-card [class.loading]="loading">
          <ui5-card-header
            slot="header"
            title-text="Governed deployments"
            subtitle-text="Release runs, approvals, and gate outcomes"
            [additionalText]="deployments.length + ''">
          </ui5-card-header>

          <ui5-table
            *ngIf="deployments.length > 0"
            [attr.aria-label]="'deployments.deploymentsTable' | translate"
            [class.table-loading]="mutating">
            <ui5-table-header-cell><span>Deployment run</span></ui5-table-header-cell>
            <ui5-table-header-cell><span>Status</span></ui5-table-header-cell>
            <ui5-table-header-cell><span>Gate</span></ui5-table-header-cell>
            <ui5-table-header-cell><span>Approval</span></ui5-table-header-cell>
            <ui5-table-header-cell><span>Source job</span></ui5-table-header-cell>
            <ui5-table-header-cell><span>Scenario</span></ui5-table-header-cell>
            <ui5-table-header-cell><span>Created</span></ui5-table-header-cell>
            <ui5-table-header-cell><span>Actions</span></ui5-table-header-cell>

            <ui5-table-row *ngFor="let deployment of deployments; trackBy: trackByDeploymentId">
              <ui5-table-cell>
                <code class="deployment-id">{{ deployment.id }}</code>
              </ui5-table-cell>
              <ui5-table-cell>
                <ui5-tag [design]="getStatusDesign(deployment.status)">{{ deployment.status }}</ui5-tag>
              </ui5-table-cell>
              <ui5-table-cell>
                <ui5-tag [design]="getStatusDesign(deployment.gateStatus)">{{ deployment.gateStatus }}</ui5-tag>
              </ui5-table-cell>
              <ui5-table-cell>
                <ui5-tag [design]="getStatusDesign(deployment.approvalStatus)">{{ deployment.approvalStatus }}</ui5-tag>
              </ui5-table-cell>
              <ui5-table-cell>{{ deployment.jobId || 'n/a' }}</ui5-table-cell>
              <ui5-table-cell>{{ deployment.scenarioId || 'n/a' }}</ui5-table-cell>
              <ui5-table-cell>{{ deployment.creationTime | dateFormat:'datetime' }}</ui5-table-cell>
              <ui5-table-cell>
                <div class="row-actions" *ngIf="canManage; else readOnlyActions">
                  <ui5-button
                    design="Emphasized"
                    (click)="setTargetStatus(deployment, nextTargetStatus(deployment))"
                    [disabled]="mutating || deployment.status === 'completed'"
                    [attr.aria-label]="'Launch deployment run ' + deployment.id">
                    {{ deployment.status === 'completed' ? 'Released' : 'Launch' }}
                  </ui5-button>
                  <ui5-button
                    design="Negative"
                    icon="delete"
                    (click)="confirmDelete(deployment)"
                    [disabled]="mutating"
                    [attr.aria-label]="'Delete deployment run ' + deployment.id">
                    {{ 'common.delete' | translate }}
                  </ui5-button>
                </div>
                <ng-template #readOnlyActions>
                  <span class="read-only-label">{{ 'deployments.readOnly' | translate }}</span>
                </ng-template>
              </ui5-table-cell>
            </ui5-table-row>
          </ui5-table>

          <app-empty-state
            *ngIf="!loading && deployments.length === 0"
            icon="machine"
            title="No governed deployments"
            description="Create a deployment run from a completed optimization job to start the governed release workflow."
            [actionText]="canManage ? ('deployments.newDeployment' | translate) : ''"
            actionIcon="add"
            (actionClicked)="toggleCreateForm()">
          </app-empty-state>
        </ui5-card>
      </div>
    </ui5-page>

    <app-confirmation-dialog
      #deleteDialog
      [data]="deleteDialogData"
      (confirmed)="executeDelete()"
      (cancelled)="cancelDelete()">
    </app-confirmation-dialog>
  `,
  styles: [`
    .deployments-content { padding: 1rem; display: flex; flex-direction: column; gap: 1rem; max-width: 1400px; margin: 0 auto; }
    .loading-container { display: flex; align-items: center; justify-content: center; padding: 2rem; gap: 1rem; }
    .loading-text, .read-only-label { color: var(--sapContent_LabelColor); }
    .create-card, ui5-card { width: 100%; }
    ui5-card.loading, .table-loading { opacity: 0.6; pointer-events: none; }
    .form-grid { padding: 1rem; display: grid; gap: 1rem; }
    .field-group { display: flex; flex-direction: column; gap: 0.5rem; }
    .field-label { color: var(--sapContent_LabelColor); font-weight: 500; }
    .required { color: var(--sapNegativeColor, #b00); }
    .form-actions, .row-actions { display: flex; gap: 0.5rem; flex-wrap: wrap; }
    .form-actions { justify-content: flex-end; padding-top: 0.5rem; border-top: 1px solid var(--sapList_BorderColor); }
    .deployment-id { font-family: monospace; font-size: var(--sapFontSmallSize); background: var(--sapList_Background); padding: 0.125rem 0.375rem; border-radius: 4px; }
    .native-select { padding: 0.45rem 0.6rem; border: 1px solid var(--sapField_BorderColor); border-radius: 0.35rem; background: #fff; }
    @media (max-width: 768px) {
      .deployments-content { padding: 0.75rem; }
      .row-actions { flex-direction: column; }
    }
  `]
})
export class DeploymentsComponent implements OnInit {
  @ViewChild('deleteDialog') deleteDialog!: ConfirmationDialogComponent;

  private readonly governance = inject(TrainingGovernanceService);
  private readonly destroyRef = inject(DestroyRef);
  readonly i18n = inject(I18nService);

  deployments: DeploymentRow[] = [];
  deploymentCandidates: TrainingJobResponse[] = [];
  loading = false;
  mutating = false;
  error = '';
  success = '';
  showCreateForm = false;
  selectedJobId = '';
  draftScenarioId = '';
  draftConfigurationJson = '{\n  "resourceGroup": "default"\n}';
  readonly canManage = true;

  deleteDialogData: ConfirmationDialogData = {
    title: this.i18n.t('deployments.deleteDeploymentTitle'),
    message: this.i18n.t('deployments.deleteDeploymentMessage'),
    confirmText: this.i18n.t('common.delete'),
    cancelText: this.i18n.t('common.cancel'),
    confirmDesign: 'Negative',
    icon: 'warning'
  };
  private deploymentToDelete: DeploymentRow | null = null;

  ngOnInit(): void {
    this.refresh();
  }

  refresh(): void {
    this.loading = true;
    this.error = '';
    this.success = '';

    forkJoin({
      runs: this.governance.listRuns({ workflow_type: 'deployment' }),
      jobs: this.governance.listJobs(),
    })
      .pipe(takeUntilDestroyed(this.destroyRef))
      .subscribe({
        next: ({ runs, jobs }) => {
          this.deployments = runs.runs.map((run) => ({
            id: run.id,
            status: run.status,
            details: run.config_json,
            targetStatus: run.status === 'completed' ? 'RUNNING' : 'PENDING',
            scenarioId: String(run.config_json?.['scenario_id'] || run.run_name || ''),
            creationTime: run.created_at,
            gateStatus: run.gate_status,
            approvalStatus: run.approval_status,
            jobId: run.job_id,
            run,
          }));
          this.deploymentCandidates = jobs.filter((job) => job.status === 'completed');
          this.loading = false;
        },
        error: () => {
          this.error = 'Failed to load governed deployments.';
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
    this.selectedJobId = '';
    this.draftScenarioId = '';
    this.draftConfigurationJson = '{\n  "resourceGroup": "default"\n}';
  }

  createDeployment(): void {
    if (!this.selectedJobId) {
      this.error = 'A completed source job is required.';
      return;
    }

    let configuration: Record<string, unknown> = {};
    try {
      configuration = this.draftConfigurationJson.trim()
        ? JSON.parse(this.draftConfigurationJson) as Record<string, unknown>
        : {};
    } catch {
      this.error = this.i18n.t('deployments.configJsonInvalid');
      return;
    }

    const job = this.deploymentCandidates.find((candidate) => candidate.id === this.selectedJobId);
    this.mutating = true;
    this.error = '';
    this.success = '';
    this.governance.createRun({
      workflow_type: 'deployment',
      use_case_family: 'model_release',
      requested_by: 'training-user',
      team: 'training-console',
      run_name: this.draftScenarioId.trim() || `Deploy ${job?.config['model_name'] || this.selectedJobId}`,
      model_name: String(job?.config['model_name'] || ''),
      config_json: {
        job_id: this.selectedJobId,
        source_job_id: this.selectedJobId,
        scenario_id: this.draftScenarioId.trim(),
        configuration,
      },
    })
      .pipe(takeUntilDestroyed(this.destroyRef))
      .subscribe({
        next: (run) => {
          this.governance.submitRun(run.id)
            .pipe(takeUntilDestroyed(this.destroyRef))
            .subscribe({
              next: () => {
                this.governance.launchRun(run.id)
                  .pipe(takeUntilDestroyed(this.destroyRef))
                  .subscribe({
                    next: () => {
                      this.success = `Deployment run ${run.id} submitted and launched.`;
                      this.mutating = false;
                      this.resetCreateForm();
                      this.refresh();
                    },
                    error: (err) => {
                      this.error = readBlockingMessage(err, 'Deployment run created but launch is blocked.');
                      this.mutating = false;
                      this.refresh();
                    }
                  });
              },
              error: (err) => {
                this.error = readBlockingMessage(err, 'Deployment run submission failed.');
                this.mutating = false;
              }
            });
        },
        error: (err) => {
          this.error = readBlockingMessage(err, 'Failed to create deployment run.');
          this.mutating = false;
        }
      });
  }

  setTargetStatus(deployment: DeploymentRow, _targetStatus: string): void {
    this.mutating = true;
    this.error = '';
    this.success = '';
    this.governance.launchRun(deployment.id)
      .pipe(takeUntilDestroyed(this.destroyRef))
      .subscribe({
        next: () => {
          this.success = `Deployment run ${deployment.id} launched.`;
          this.mutating = false;
          this.refresh();
        },
        error: (err) => {
          this.error = readBlockingMessage(err, `Failed to launch deployment run ${deployment.id}.`);
          this.mutating = false;
          this.refresh();
        }
      });
  }

  deleteDeployment(deployment: DeploymentRow): void {
    if (!deployment.jobId) {
      this.error = 'This deployment run cannot be deleted because it is not linked to a job.';
      return;
    }
    this.mutating = true;
    this.error = '';
    this.success = '';
    this.governance.deleteJob(deployment.jobId)
      .pipe(takeUntilDestroyed(this.destroyRef))
      .subscribe({
        next: () => {
          this.deployments = this.deployments.filter(item => item.id !== deployment.id);
          this.success = `Deleted deployment source job ${deployment.jobId}.`;
          this.mutating = false;
        },
        error: () => {
          this.error = `Failed to delete deployment source job ${deployment.jobId}.`;
          this.mutating = false;
        }
      });
  }

  nextTargetStatus(_deployment: DeploymentRow): string {
    return 'RUNNING';
  }

  getStatusDesign(status: string): 'Positive' | 'Critical' | 'Negative' | 'Neutral' {
    const normalizedStatus = status.toLowerCase();
    if (normalizedStatus === 'running' || normalizedStatus === 'completed' || normalizedStatus === 'approved' || normalizedStatus === 'passed') {
      return 'Positive';
    }
    if (normalizedStatus === 'failed' || normalizedStatus === 'error' || normalizedStatus === 'blocked' || normalizedStatus === 'rejected') {
      return 'Negative';
    }
    if (normalizedStatus === 'pending' || normalizedStatus === 'pending_approval' || normalizedStatus === 'submitted') {
      return 'Critical';
    }
    return 'Neutral';
  }

  trackByDeploymentId(index: number, deployment: DeploymentRow): string {
    return deployment.id;
  }

  confirmDelete(deployment: DeploymentRow): void {
    this.deploymentToDelete = deployment;
    this.deleteDialogData = {
      ...this.deleteDialogData,
      title: this.i18n.t('deployments.deleteDeploymentTitle'),
      message: 'Delete the linked source job for this deployment run?',
      confirmText: this.i18n.t('common.delete'),
      cancelText: this.i18n.t('common.cancel'),
      itemName: deployment.id
    };
    this.deleteDialog.show();
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
