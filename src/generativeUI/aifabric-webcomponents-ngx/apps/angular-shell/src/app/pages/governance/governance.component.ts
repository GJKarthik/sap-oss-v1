import { Component, DestroyRef, OnInit, inject } from '@angular/core';
import { CommonModule } from '@angular/common';
import { HttpClient } from '@angular/common/http';
import { FormsModule } from '@angular/forms';
import { Ui5WebcomponentsModule } from '@ui5/webcomponents-ngx';
import { takeUntilDestroyed } from '@angular/core/rxjs-interop';
import { environment } from '../../../environments/environment';
import { AuthService } from '../../services/auth.service';
import { EmptyStateComponent, ConfirmationDialogComponent, ConfirmationDialogData, DateFormatPipe } from '../../shared';
import { TeamApprovalPanelComponent } from './team-approval-panel.component';

interface GovernanceRule {
  id: string;
  name: string;
  rule_type: string;
  active: boolean;
  description?: string;
  updated_at?: string;
}

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
  selector: 'app-governance',
  standalone: true,
  imports: [CommonModule, FormsModule, Ui5WebcomponentsModule, EmptyStateComponent, ConfirmationDialogComponent, DateFormatPipe, TeamApprovalPanelComponent],
  template: `
    <ui5-page background-design="Solid">
      <ui5-bar slot="header" design="Header">
        <ui5-title slot="startContent" level="H3">Governance Rules</ui5-title>
        <ui5-button 
          slot="endContent" 
          icon="refresh" 
          (click)="loadRules()" 
          [disabled]="loading"
          aria-label="Refresh governance rules"
          class="hide-mobile">
          {{ loading ? 'Loading...' : 'Refresh' }}
        </ui5-button>
        <ui5-button 
          *ngIf="canManage" 
          slot="endContent" 
          design="Emphasized" 
          icon="add" 
          (click)="toggleCreateForm()"
          aria-label="Add new governance rule">
          {{ showCreateForm ? 'Close Form' : 'Add Rule' }}
        </ui5-button>
      </ui5-bar>
      <div class="governance-content" role="region" aria-label="Governance rules management">
        <!-- Loading indicator -->
        <div class="loading-container" *ngIf="loading" role="status" aria-live="polite">
          <ui5-busy-indicator active size="M"></ui5-busy-indicator>
          <span class="loading-text">Loading governance rules...</span>
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
        <ui5-message-strip *ngIf="!canManage" design="Information" [hideCloseButton]="true" role="note">
          Viewer mode: governance changes are disabled.
        </ui5-message-strip>

        <!-- Team Approvals Panel -->
        <app-team-approval-panel></app-team-approval-panel>

        <ui5-card *ngIf="showCreateForm && canManage" class="create-form-card">
          <ui5-card-header slot="header" title-text="Create Governance Rule" subtitle-text="Persist a new policy in the console"></ui5-card-header>
          <form class="form-grid" (ngSubmit)="createRule()">
            <div class="field-group">
              <label for="rule-name-input" class="field-label">
                Rule Name <span class="required">*</span>
              </label>
              <ui5-input 
                id="rule-name-input"
                ngDefaultControl 
                [(ngModel)]="draftRule.name" 
                name="ruleName"
                placeholder="PII Detection"
                accessible-name="Rule name"
                required>
              </ui5-input>
            </div>
            <div class="field-group">
              <label for="rule-type-input" class="field-label">
                Rule Type <span class="required">*</span>
              </label>
              <ui5-input 
                id="rule-type-input"
                ngDefaultControl 
                [(ngModel)]="draftRule.rule_type" 
                name="ruleType"
                placeholder="content-filter"
                accessible-name="Rule type"
                required>
              </ui5-input>
            </div>
            <div class="field-group">
              <label for="rule-description-input" class="field-label">Description</label>
              <ui5-textarea 
                id="rule-description-input"
                ngDefaultControl 
                [(ngModel)]="draftRule.description" 
                name="description"
                [rows]="4" 
                growing 
                placeholder="Describe what this rule governs."
                accessible-name="Rule description">
              </ui5-textarea>
            </div>
            <div class="form-actions">
              <ui5-button 
                design="Emphasized" 
                type="Submit"
                (click)="createRule()" 
                [disabled]="mutating || !draftRule.name.trim() || !draftRule.rule_type.trim()">
                {{ mutating ? 'Creating...' : 'Create Rule' }}
              </ui5-button>
              <ui5-button design="Transparent" (click)="resetCreateForm()" [disabled]="mutating">Cancel</ui5-button>
            </div>
          </form>
        </ui5-card>

        <ui5-card [class.card-loading]="loading">
          <ui5-card-header 
            slot="header" 
            title-text="Active Rules" 
            subtitle-text="Policy enforcement configuration"
            [additionalText]="rules.length + ''">
          </ui5-card-header>
          <ui5-table 
            *ngIf="rules.length > 0" 
            aria-label="Governance rules table"
            [class.table-loading]="mutating">
            <ui5-table-header-cell><span>Rule Name</span></ui5-table-header-cell>
            <ui5-table-header-cell><span>Type</span></ui5-table-header-cell>
            <ui5-table-header-cell><span>Status</span></ui5-table-header-cell>
            <ui5-table-header-cell><span>Description</span></ui5-table-header-cell>
            <ui5-table-header-cell><span>Updated</span></ui5-table-header-cell>
            <ui5-table-header-cell><span>Actions</span></ui5-table-header-cell>
            <ui5-table-row *ngFor="let rule of rules; trackBy: trackByRuleId">
              <ui5-table-cell>
                <strong>{{ rule.name }}</strong>
              </ui5-table-cell>
              <ui5-table-cell>
                <ui5-tag design="Information">{{ rule.rule_type }}</ui5-tag>
              </ui5-table-cell>
              <ui5-table-cell>
                <ui5-tag [design]="rule.active ? 'Positive' : 'Negative'">
                  {{ rule.active ? 'Active' : 'Inactive' }}
                </ui5-tag>
              </ui5-table-cell>
              <ui5-table-cell>
                <span class="description-text">{{ rule.description || 'No description' }}</span>
              </ui5-table-cell>
              <ui5-table-cell>{{ rule.updated_at | dateFormat:'medium' }}</ui5-table-cell>
              <ui5-table-cell>
                <div class="row-actions" *ngIf="canManage; else readOnlyActions">
                  <ui5-button 
                    design="Transparent" 
                    [icon]="rule.active ? 'decline' : 'accept'" 
                    (click)="toggleRule(rule)" 
                    [disabled]="mutating"
                    [attr.aria-label]="(rule.active ? 'Disable' : 'Enable') + ' rule ' + rule.name">
                    {{ rule.active ? 'Disable' : 'Enable' }}
                  </ui5-button>
                  <ui5-button 
                    design="Negative" 
                    icon="delete" 
                    (click)="confirmDelete(rule)" 
                    [disabled]="mutating"
                    [attr.aria-label]="'Delete rule ' + rule.name">
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
            *ngIf="!loading && rules.length === 0"
            icon="shield"
            title="No Governance Rules"
            description="No governance rules have been configured yet. Add rules to enforce policies on AI operations."
            [actionText]="canManage ? 'Add Rule' : ''"
            (action)="toggleCreateForm()">
          </app-empty-state>
        </ui5-card>

        <!-- Delete Confirmation Dialog -->
        <app-confirmation-dialog
          [open]="deleteDialogOpen"
          [data]="deleteDialogData"
          (confirmed)="executeDelete()"
          (cancelled)="cancelDelete()">
        </app-confirmation-dialog>
      </div>
    </ui5-page>
  `,
  styles: [`
    .governance-content {
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

    .create-form-card {
      max-width: 600px;
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

    .form-actions,
    .row-actions {
      display: flex;
      gap: 0.5rem;
      flex-wrap: wrap;
    }

    .card-loading,
    .table-loading {
      opacity: 0.6;
      pointer-events: none;
    }

    .description-text {
      color: var(--sapContent_LabelColor);
      font-size: var(--sapFontSmallSize);
    }

    .read-only-label {
      color: var(--sapContent_LabelColor);
      font-size: var(--sapFontSmallSize);
    }

    @media (max-width: 768px) {
      .governance-content {
        padding: 0.75rem;
      }

      .hide-mobile {
        display: none;
      }
    }
  `]
})
export class GovernanceComponent implements OnInit {
  private readonly http = inject(HttpClient);
  private readonly destroyRef = inject(DestroyRef);
  private readonly authService = inject(AuthService);

  rules: GovernanceRule[] = [];
  loading = false;
  mutating = false;
  error = '';
  success = '';
  showCreateForm = false;
  draftRule = {
    name: '',
    rule_type: '',
    description: '',
  };
  readonly canManage = this.authService.getUser()?.role === 'admin';

  ngOnInit(): void {
    this.loadRules();
  }

  loadRules(): void {
    this.loading = true;
    this.error = '';
    this.success = '';
    this.http.get<{ rules: GovernanceRule[]; total: number }>(`${environment.apiBaseUrl}/governance`)
      .pipe(takeUntilDestroyed(this.destroyRef))
      .subscribe({
        next: res => {
          this.rules = res.rules;
          this.loading = false;
        },
        error: err => {
          this.error = readErrorMessage(err, 'Failed to load governance rules.');
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
    this.draftRule = {
      name: '',
      rule_type: '',
      description: '',
    };
  }

  createRule(): void {
    if (!this.draftRule.name.trim() || !this.draftRule.rule_type.trim()) {
      this.error = 'Rule name and type are required.';
      return;
    }

    this.mutating = true;
    this.error = '';
    this.success = '';
    this.http.post<GovernanceRule>(`${environment.apiBaseUrl}/governance`, {
      name: this.draftRule.name.trim(),
      rule_type: this.draftRule.rule_type.trim(),
      description: this.draftRule.description.trim() || undefined,
      active: true,
    })
      .pipe(takeUntilDestroyed(this.destroyRef))
      .subscribe({
        next: rule => {
          this.rules = [...this.rules, rule].sort((left, right) => left.name.localeCompare(right.name));
          this.success = `Governance rule "${rule.name}" created.`;
          this.mutating = false;
          this.resetCreateForm();
        },
        error: err => {
          this.error = readErrorMessage(err, 'Failed to create governance rule.');
          this.mutating = false;
        }
      });
  }

  toggleRule(rule: GovernanceRule): void {
    if (!this.canManage) {
      return;
    }

    this.mutating = true;
    this.error = '';
    this.success = '';
    this.http.patch<{ id: string; active: boolean }>(`${environment.apiBaseUrl}/governance/${rule.id}/toggle`, {})
      .pipe(takeUntilDestroyed(this.destroyRef))
      .subscribe({
        next: res => {
          rule.active = res.active;
          rule.updated_at = new Date().toISOString();
          this.success = `Rule "${rule.name}" updated.`;
          this.mutating = false;
        },
        error: err => {
          this.error = readErrorMessage(err, `Failed to toggle rule "${rule.name}".`);
          this.mutating = false;
        }
      });
  }

  // Delete confirmation
  deleteDialogOpen = false;
  deleteDialogData: ConfirmationDialogData = {
    title: 'Delete Governance Rule',
    message: '',
    confirmText: 'Delete',
    cancelText: 'Cancel',
    confirmDesign: 'Negative'
  };
  private ruleToDelete: GovernanceRule | null = null;

  confirmDelete(rule: GovernanceRule): void {
    this.ruleToDelete = rule;
    this.deleteDialogData = {
      ...this.deleteDialogData,
      message: `Are you sure you want to delete the rule "${rule.name}"? This action cannot be undone.`
    };
    this.deleteDialogOpen = true;
  }

  cancelDelete(): void {
    this.deleteDialogOpen = false;
    this.ruleToDelete = null;
  }

  executeDelete(): void {
    if (!this.ruleToDelete || !this.canManage) {
      this.deleteDialogOpen = false;
      return;
    }

    const rule = this.ruleToDelete;
    this.deleteDialogOpen = false;
    this.mutating = true;
    this.error = '';
    this.success = '';
    
    this.http.delete<void>(`${environment.apiBaseUrl}/governance/${rule.id}`)
      .pipe(takeUntilDestroyed(this.destroyRef))
      .subscribe({
        next: () => {
          this.rules = this.rules.filter(item => item.id !== rule.id);
          this.success = `Rule "${rule.name}" deleted.`;
          this.mutating = false;
          this.ruleToDelete = null;
        },
        error: err => {
          this.error = readErrorMessage(err, `Failed to delete rule "${rule.name}".`);
          this.mutating = false;
          this.ruleToDelete = null;
        }
      });
  }

  trackByRuleId(index: number, rule: GovernanceRule): string {
    return rule.id;
  }

  formatDate(value?: string): string {
    if (!value) {
      return 'n/a';
    }

    const date = new Date(value);
    return Number.isNaN(date.getTime()) ? value : date.toLocaleString();
  }
}
