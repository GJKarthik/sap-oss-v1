import { Component, DestroyRef, OnInit, inject } from '@angular/core';
import { CommonModule } from '@angular/common';
import { HttpClient } from '@angular/common/http';
import { FormsModule } from '@angular/forms';
import { Ui5WebcomponentsModule } from '@ui5/webcomponents-ngx';
import { takeUntilDestroyed } from '@angular/core/rxjs-interop';
import { environment } from '../../../environments/environment';
import { AuthService } from '../../services/auth.service';

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
  imports: [CommonModule, FormsModule, Ui5WebcomponentsModule],
  template: `
    <ui5-page background-design="Solid">
      <ui5-bar slot="header" design="Header">
        <ui5-title slot="startContent" level="H3">Governance Rules</ui5-title>
        <ui5-button *ngIf="canManage" slot="endContent" design="Emphasized" icon="add" (click)="toggleCreateForm()">
          {{ showCreateForm ? 'Close Form' : 'Add Rule' }}
        </ui5-button>
      </ui5-bar>
      <div class="governance-content">
        <ui5-message-strip *ngIf="error" design="Negative" [hideCloseButton]="true">
          {{ error }}
        </ui5-message-strip>
        <ui5-message-strip *ngIf="success" design="Positive" [hideCloseButton]="true">
          {{ success }}
        </ui5-message-strip>
        <ui5-message-strip *ngIf="!canManage" design="Information" [hideCloseButton]="true">
          Viewer mode: governance changes are disabled.
        </ui5-message-strip>

        <ui5-card *ngIf="showCreateForm && canManage">
          <ui5-card-header slot="header" title-text="Create Governance Rule" subtitle-text="Persist a new policy in the console"></ui5-card-header>
          <div class="form-grid">
            <label class="field-label">
              Rule Name
              <ui5-input ngDefaultControl [(ngModel)]="draftRule.name" placeholder="PII Detection"></ui5-input>
            </label>
            <label class="field-label">
              Rule Type
              <ui5-input ngDefaultControl [(ngModel)]="draftRule.rule_type" placeholder="content-filter"></ui5-input>
            </label>
            <label class="field-label">
              Description
              <ui5-textarea ngDefaultControl [(ngModel)]="draftRule.description" [rows]="4" growing placeholder="Describe what this rule governs."></ui5-textarea>
            </label>
            <div class="form-actions">
              <ui5-button design="Emphasized" (click)="createRule()" [disabled]="mutating">Create Rule</ui5-button>
              <ui5-button design="Transparent" (click)="resetCreateForm()" [disabled]="mutating">Cancel</ui5-button>
            </div>
          </div>
        </ui5-card>

        <ui5-card>
          <ui5-card-header slot="header" title-text="Active Rules" [additionalText]="rules.length + ''"></ui5-card-header>
          <ui5-table *ngIf="rules.length > 0">
            <ui5-table-header-cell><span>Rule Name</span></ui5-table-header-cell>
            <ui5-table-header-cell><span>Type</span></ui5-table-header-cell>
            <ui5-table-header-cell><span>Status</span></ui5-table-header-cell>
            <ui5-table-header-cell><span>Description</span></ui5-table-header-cell>
            <ui5-table-header-cell><span>Updated</span></ui5-table-header-cell>
            <ui5-table-header-cell><span>Actions</span></ui5-table-header-cell>
            <ui5-table-row *ngFor="let rule of rules">
              <ui5-table-cell>{{ rule.name }}</ui5-table-cell>
              <ui5-table-cell>{{ rule.rule_type }}</ui5-table-cell>
              <ui5-table-cell><ui5-tag [design]="rule.active ? 'Positive' : 'Negative'">{{ rule.active ? 'Active' : 'Inactive' }}</ui5-tag></ui5-table-cell>
              <ui5-table-cell>{{ rule.description || 'No description' }}</ui5-table-cell>
              <ui5-table-cell>{{ formatDate(rule.updated_at) }}</ui5-table-cell>
              <ui5-table-cell>
                <div class="row-actions" *ngIf="canManage; else readOnlyActions">
                  <ui5-button design="Transparent" icon="action-settings" (click)="toggleRule(rule)" [disabled]="mutating">
                    {{ rule.active ? 'Disable' : 'Enable' }}
                  </ui5-button>
                  <ui5-button design="Negative" icon="delete" (click)="deleteRule(rule)" [disabled]="mutating">
                    Delete
                  </ui5-button>
                </div>
                <ng-template #readOnlyActions>
                  <span class="read-only-label">Read only</span>
                </ng-template>
              </ui5-table-cell>
            </ui5-table-row>
          </ui5-table>

          <div *ngIf="!loading && rules.length === 0" class="empty-state">
            No governance rules configured.
          </div>
        </ui5-card>
      </div>
    </ui5-page>
  `,
  styles: [`
    .governance-content {
      padding: 1rem;
      display: flex;
      flex-direction: column;
      gap: 1rem;
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

    .form-actions,
    .row-actions {
      display: flex;
      gap: 0.5rem;
      flex-wrap: wrap;
    }

    .empty-state {
      padding: 1rem;
      color: var(--sapContent_LabelColor);
    }

    .read-only-label {
      color: var(--sapContent_LabelColor);
      font-size: var(--sapFontSmallSize);
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

  deleteRule(rule: GovernanceRule): void {
    if (!this.canManage) {
      return;
    }

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
        },
        error: err => {
          this.error = readErrorMessage(err, `Failed to delete rule "${rule.name}".`);
          this.mutating = false;
        }
      });
  }

  formatDate(value?: string): string {
    if (!value) {
      return 'n/a';
    }

    const date = new Date(value);
    return Number.isNaN(date.getTime()) ? value : date.toLocaleString();
  }
}
