import { Component, DestroyRef, OnInit, inject } from '@angular/core';
import { CommonModule } from '@angular/common';
import { FormsModule } from '@angular/forms';
import { Ui5WebcomponentsModule } from '@ui5/webcomponents-ngx';
import { takeUntilDestroyed } from '@angular/core/rxjs-interop';

import {
  GovernanceRule,
  GovernanceRuleCreateRequest,
  GovernanceService,
} from '../../services/api/governance.service';

interface GovernanceRuleForm {
  name: string;
  rule_type: string;
  description: string;
}

@Component({
  selector: 'app-governance',
  standalone: true,
  imports: [CommonModule, FormsModule, Ui5WebcomponentsModule],
  template: `
    <ui5-page background-design="Solid">
      <ui5-bar slot="header" design="Header">
        <ui5-title slot="startContent" level="H3">Governance Rules</ui5-title>
        <ui5-button slot="endContent" design="Emphasized" icon="add" (click)="showCreateForm = !showCreateForm">
          {{ showCreateForm ? 'Hide Create Form' : 'Add Rule' }}
        </ui5-button>
      </ui5-bar>

      <div class="governance-content">
        <ui5-message-strip *ngIf="error" design="Negative" [hideCloseButton]="true">
          {{ error }}
        </ui5-message-strip>

        <div class="governance-grid">
          <ui5-card>
            <ui5-card-header slot="header" title-text="Active Rules" [additionalText]="rules.length + ''"></ui5-card-header>
            <ui5-table *ngIf="rules.length > 0">
              <ui5-table-header-cell><span>Rule Name</span></ui5-table-header-cell>
              <ui5-table-header-cell><span>Type</span></ui5-table-header-cell>
              <ui5-table-header-cell><span>Status</span></ui5-table-header-cell>
              <ui5-table-header-cell><span>Actions</span></ui5-table-header-cell>
              <ui5-table-row *ngFor="let rule of rules">
                <ui5-table-cell>{{ rule.name }}</ui5-table-cell>
                <ui5-table-cell>{{ rule.rule_type }}</ui5-table-cell>
                <ui5-table-cell>
                  <ui5-tag [design]="rule.active ? 'Positive' : 'Negative'">
                    {{ rule.active ? 'Active' : 'Inactive' }}
                  </ui5-tag>
                </ui5-table-cell>
                <ui5-table-cell>
                  <div class="actions-row">
                    <ui5-button design="Transparent" icon="detail-view" (click)="loadRule(rule.id)">
                      View
                    </ui5-button>
                    <ui5-button design="Transparent" icon="action-settings" (click)="toggleRule(rule)">
                      {{ rule.active ? 'Disable' : 'Enable' }}
                    </ui5-button>
                    <ui5-button design="Transparent" icon="delete" (click)="deleteRule(rule)">
                      Delete
                    </ui5-button>
                  </div>
                </ui5-table-cell>
              </ui5-table-row>
            </ui5-table>

            <div *ngIf="!loading && rules.length === 0" class="empty-state">
              No governance rules configured.
            </div>
          </ui5-card>

          <div class="side-panel">
            <ui5-card *ngIf="showCreateForm">
              <ui5-card-header slot="header" title-text="Create Rule"></ui5-card-header>
              <div class="card-body form-stack">
                <ui5-input [(ngModel)]="newRule.name" placeholder="Rule name"></ui5-input>
                <ui5-input [(ngModel)]="newRule.rule_type" placeholder="Rule type"></ui5-input>
                <ui5-textarea [(ngModel)]="newRule.description" placeholder="Rule description" [rows]="5"></ui5-textarea>
                <ui5-button design="Emphasized" (click)="createRule()" [disabled]="createLoading || !newRule.name.trim() || !newRule.rule_type.trim()">
                  {{ createLoading ? 'Creating...' : 'Create Rule' }}
                </ui5-button>
              </div>
            </ui5-card>

            <ui5-card *ngIf="selectedRule || detailLoading">
              <ui5-card-header slot="header" title-text="Rule Details"></ui5-card-header>
              <div class="card-body" *ngIf="selectedRule; else loadingRule">
                <div class="detail-row"><strong>ID:</strong> {{ selectedRule.id }}</div>
                <div class="detail-row"><strong>Name:</strong> {{ selectedRule.name }}</div>
                <div class="detail-row"><strong>Type:</strong> {{ selectedRule.rule_type }}</div>
                <div class="detail-row">
                  <strong>Status:</strong>
                  <ui5-tag [design]="selectedRule.active ? 'Positive' : 'Negative'">
                    {{ selectedRule.active ? 'Active' : 'Inactive' }}
                  </ui5-tag>
                </div>
                <div class="detail-row"><strong>Description:</strong> {{ selectedRule.description || 'No description provided.' }}</div>
              </div>
              <ng-template #loadingRule>
                <div class="card-body empty-state">Loading rule details...</div>
              </ng-template>
            </ui5-card>
          </div>
        </div>
      </div>
    </ui5-page>
  `,
  styles: [`
    .governance-content { padding: 1rem; }
    .governance-grid { display: grid; grid-template-columns: minmax(0, 2fr) minmax(280px, 1fr); gap: 1rem; }
    .side-panel { display: flex; flex-direction: column; gap: 1rem; }
    .card-body { padding: 1rem; }
    .form-stack { display: flex; flex-direction: column; gap: 0.75rem; }
    .actions-row { display: flex; flex-wrap: wrap; gap: 0.5rem; }
    .detail-row { margin-bottom: 0.75rem; display: flex; flex-wrap: wrap; gap: 0.5rem; align-items: center; }
    ui5-message-strip { margin-bottom: 1rem; }
    .empty-state { padding: 1rem; color: var(--sapContent_LabelColor); }
    @media (max-width: 1023px) {
      .governance-grid { grid-template-columns: 1fr; }
    }
  `]
})
export class GovernanceComponent implements OnInit {
  private readonly governanceService = inject(GovernanceService);
  private readonly destroyRef = inject(DestroyRef);

  rules: GovernanceRule[] = [];
  selectedRule: GovernanceRule | null = null;
  loading = false;
  createLoading = false;
  detailLoading = false;
  showCreateForm = false;
  error = '';
  newRule: GovernanceRuleForm = {
    name: '',
    rule_type: 'content-filter',
    description: '',
  };

  ngOnInit(): void {
    this.loadRules();
  }

  loadRules(selectedRuleId = this.selectedRule?.id): void {
    this.loading = true;
    this.error = '';

    this.governanceService.listRules()
      .pipe(takeUntilDestroyed(this.destroyRef))
      .subscribe({
        next: response => {
          this.rules = response.rules;
          this.selectedRule = selectedRuleId
            ? response.rules.find(rule => rule.id === selectedRuleId) ?? this.selectedRule
            : this.selectedRule;
          this.loading = false;
        },
        error: error => {
          this.error = this.getErrorMessage(error, 'Failed to load governance rules.');
          this.loading = false;
        }
      });
  }

  createRule(): void {
    const body: GovernanceRuleCreateRequest = {
      name: this.newRule.name.trim(),
      rule_type: this.newRule.rule_type.trim(),
      description: this.newRule.description.trim() || null,
      active: true,
    };

    if (!body.name || !body.rule_type) {
      return;
    }

    this.createLoading = true;
    this.error = '';

    this.governanceService.createRule(body)
      .pipe(takeUntilDestroyed(this.destroyRef))
      .subscribe({
        next: rule => {
          this.newRule = { name: '', rule_type: 'content-filter', description: '' };
          this.showCreateForm = false;
          this.createLoading = false;
          this.loadRules(rule.id);
          this.loadRule(rule.id);
        },
        error: error => {
          this.error = this.getErrorMessage(error, 'Failed to create governance rule.');
          this.createLoading = false;
        }
      });
  }

  loadRule(ruleId: string): void {
    this.detailLoading = true;
    this.error = '';

    this.governanceService.getRule(ruleId)
      .pipe(takeUntilDestroyed(this.destroyRef))
      .subscribe({
        next: rule => {
          this.selectedRule = rule;
          this.detailLoading = false;
        },
        error: error => {
          this.error = this.getErrorMessage(error, 'Failed to load governance rule details.');
          this.detailLoading = false;
        }
      });
  }

  toggleRule(rule: GovernanceRule): void {
    this.error = '';

    this.governanceService.toggleRule(rule.id)
      .pipe(takeUntilDestroyed(this.destroyRef))
      .subscribe({
        next: response => {
          this.rules = this.rules.map(existingRule =>
            existingRule.id === rule.id
              ? { ...existingRule, active: response.active }
              : existingRule
          );
          if (this.selectedRule?.id === rule.id) {
            this.loadRule(rule.id);
          }
        },
        error: error => {
          this.error = this.getErrorMessage(error, `Failed to toggle rule "${rule.name}".`);
        }
      });
  }

  deleteRule(rule: GovernanceRule): void {
    if (!window.confirm(`Delete governance rule "${rule.name}"?`)) {
      return;
    }

    this.error = '';

    this.governanceService.deleteRule(rule.id)
      .pipe(takeUntilDestroyed(this.destroyRef))
      .subscribe({
        next: () => {
          if (this.selectedRule?.id === rule.id) {
            this.selectedRule = null;
          }
          this.loadRules();
        },
        error: error => {
          this.error = this.getErrorMessage(error, `Failed to delete rule "${rule.name}".`);
        }
      });
  }

  private getErrorMessage(error: unknown, fallback: string): string {
    if (typeof error === 'object' && error !== null) {
      const apiError = error as { error?: { detail?: string }; message?: string };
      if (typeof apiError.error?.detail === 'string') {
        return apiError.error.detail;
      }
      if (typeof apiError.message === 'string') {
        return apiError.message;
      }
    }

    return fallback;
  }
}
