// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 SAP SE

import { CommonModule } from '@angular/common';
import {
  ChangeDetectionStrategy,
  ChangeDetectorRef,
  Component,
  OnDestroy,
  OnInit,
} from '@angular/core';
import { Subject } from 'rxjs';
import { takeUntil } from 'rxjs/operators';
import {
  GovernanceService,
  PendingAction,
  PendingActionReview,
  ActionDiffEntry,
} from '../services/governance.service';

@Component({
  selector: 'genui-governance-review-panel',
  standalone: true,
  imports: [CommonModule],
  changeDetection: ChangeDetectionStrategy.OnPush,
  template: `
    <section class="review-panel" aria-label="Operator review panel">
      <ng-container *ngIf="pendingActions.length > 0; else emptyState">
        <aside class="review-panel__list" aria-label="Pending actions">
          <button
            *ngFor="let action of pendingActions; trackBy: trackByActionId"
            type="button"
            class="review-panel__action"
            [class.review-panel__action--selected]="action.id === selectedActionId"
            (click)="selectAction(action.id)"
          >
            <span class="review-panel__action-title">{{ action.description }}</span>
            <span class="review-panel__action-tool">{{ action.toolName }}</span>
            <span class="review-panel__risk" [attr.data-risk]="action.riskLevel">{{ getRiskChipLabel(action) }}</span>
          </button>
        </aside>

        <article class="review-panel__detail" *ngIf="review as currentReview">
          <header class="review-panel__header">
            <div>
              <p class="review-panel__eyebrow">Pending review</p>
              <h2>{{ currentReview.action.description }}</h2>
              <p class="review-panel__tool">{{ currentReview.action.toolName }}</p>
            </div>
            <span class="review-panel__risk review-panel__risk--large" [attr.data-risk]="currentReview.action.riskLevel">
              {{ currentReview.riskLabel }}
            </span>
          </header>

          <section class="review-panel__section">
            <h3>Risk</h3>
            <p>{{ currentReview.riskDescription }}</p>
          </section>

          <section class="review-panel__section">
            <h3>Affected Scope</h3>
            <p class="review-panel__scope-summary">{{ currentReview.affectedScope.summary }}</p>
            <div class="review-panel__chips">
              <span class="review-panel__chip" *ngFor="let entity of currentReview.affectedScope.entities">
                {{ entity }}
              </span>
            </div>
            <div class="review-panel__chips" *ngIf="currentReview.affectedScope.fields.length > 0">
              <span class="review-panel__chip review-panel__chip--muted" *ngFor="let field of currentReview.affectedScope.fields">
                {{ field }}
              </span>
            </div>
          </section>

          <section class="review-panel__section">
            <div class="review-panel__section-header">
              <h3>Diff</h3>
              <p>Preview between current arguments and operator modifications.</p>
            </div>
            <div class="review-panel__table" role="table" aria-label="Argument diff">
              <div class="review-panel__row review-panel__row--header" role="row">
                <span role="columnheader">Path</span>
                <span role="columnheader">Before</span>
                <span role="columnheader">After</span>
                <span role="columnheader">Change</span>
              </div>
              <div
                class="review-panel__row"
                role="row"
                *ngFor="let entry of currentReview.diff; trackBy: trackByDiffPath"
                [attr.data-change]="entry.changeType"
              >
                <span role="cell">{{ entry.path }}</span>
                <code role="cell">{{ formatValue(entry.before) }}</code>
                <code role="cell">{{ formatValue(entry.after) }}</code>
                <span role="cell" class="review-panel__change">{{ entry.changeType }}</span>
              </div>
            </div>
          </section>

          <section class="review-panel__section" *ngIf="currentReview.action.allowModifications">
            <div class="review-panel__section-header">
              <h3>Operator Modifications</h3>
              <p>Enter a JSON object to override individual arguments before approval.</p>
            </div>
            <textarea
              #modificationsInput
              class="review-panel__textarea"
              rows="8"
              [value]="modificationsText"
              (input)="onModificationsInput(modificationsInput.value)"
              aria-label="Operator modifications"
            ></textarea>
            <p class="review-panel__error" *ngIf="parseError">{{ parseError }}</p>
          </section>

          <section class="review-panel__section">
            <div class="review-panel__section-header">
              <h3>Rejection Reason</h3>
              <p>Optional context sent back if the action is rejected.</p>
            </div>
            <textarea
              #reasonInput
              class="review-panel__textarea review-panel__textarea--compact"
              rows="3"
              [value]="rejectionReason"
              (input)="onRejectionReasonInput(reasonInput.value)"
              aria-label="Rejection reason"
            ></textarea>
          </section>

          <footer class="review-panel__footer">
            <p class="review-panel__error" *ngIf="submissionError" aria-live="polite">{{ submissionError }}</p>
            <button
              type="button"
              class="review-panel__button review-panel__button--secondary"
              (click)="rejectSelectedAction()"
              [disabled]="!selectedActionId || isSubmitting"
            >
              Reject
            </button>
            <button
              type="button"
              class="review-panel__button"
              (click)="confirmSelectedAction()"
              [disabled]="!selectedActionId || isSubmitting || !!parseError"
            >
              Approve
            </button>
          </footer>
        </article>
      </ng-container>
    </section>

    <ng-template #emptyState>
      <section class="review-panel review-panel--empty" aria-label="No pending actions">
        <h2>No actions waiting for review</h2>
        <p>High-impact tool calls will appear here when they need operator approval.</p>
      </section>
    </ng-template>
  `,
  styles: [`
    :host {
      display: block;
    }

    .review-panel {
      display: grid;
      grid-template-columns: minmax(240px, 320px) minmax(0, 1fr);
      gap: 24px;
      padding: 24px;
      border: 1px solid #d9dde3;
      border-radius: 20px;
      background:
        radial-gradient(circle at top right, rgba(209, 232, 255, 0.5), transparent 35%),
        linear-gradient(180deg, #ffffff 0%, #f7f9fb 100%);
      color: #12233d;
    }

    .review-panel--empty {
      display: block;
    }

    .review-panel__list {
      display: flex;
      flex-direction: column;
      gap: 12px;
    }

    .review-panel__action {
      display: grid;
      gap: 6px;
      padding: 16px;
      border: 1px solid #d9dde3;
      border-radius: 16px;
      background: rgba(255, 255, 255, 0.78);
      text-align: left;
      cursor: pointer;
      transition: border-color 0.2s ease, transform 0.2s ease, box-shadow 0.2s ease;
    }

    .review-panel__action:hover,
    .review-panel__action--selected {
      border-color: #0a6ed1;
      box-shadow: 0 12px 30px rgba(10, 110, 209, 0.12);
      transform: translateY(-1px);
    }

    .review-panel__action-title {
      font-weight: 600;
    }

    .review-panel__action-tool,
    .review-panel__tool,
    .review-panel__eyebrow,
    .review-panel__section-header p {
      color: #4c627a;
    }

    .review-panel__detail {
      display: grid;
      gap: 20px;
    }

    .review-panel__header,
    .review-panel__footer,
    .review-panel__section-header {
      display: flex;
      align-items: flex-start;
      justify-content: space-between;
      gap: 16px;
    }

    .review-panel__eyebrow {
      margin: 0 0 6px;
      text-transform: uppercase;
      letter-spacing: 0.08em;
      font-size: 11px;
      font-weight: 700;
    }

    .review-panel__header h2,
    .review-panel__section h3 {
      margin: 0;
    }

    .review-panel__header p,
    .review-panel__section p {
      margin: 6px 0 0;
    }

    .review-panel__section {
      display: grid;
      gap: 12px;
      padding: 16px;
      border-radius: 16px;
      background: rgba(255, 255, 255, 0.85);
      border: 1px solid #e2e7ee;
    }

    .review-panel__scope-summary {
      font-weight: 600;
      color: #183153;
    }

    .review-panel__chips {
      display: flex;
      flex-wrap: wrap;
      gap: 8px;
    }

    .review-panel__chip,
    .review-panel__risk {
      display: inline-flex;
      align-items: center;
      justify-content: center;
      border-radius: 999px;
      padding: 6px 10px;
      font-size: 12px;
      font-weight: 700;
      letter-spacing: 0.02em;
    }

    .review-panel__chip {
      background: #edf3ff;
      color: #174a7a;
    }

    .review-panel__chip--muted {
      background: #eef2f6;
      color: #44576c;
    }

    .review-panel__risk {
      background: #eef5ff;
      color: #17528a;
    }

    .review-panel__risk[data-risk='medium'] {
      background: #fff2dd;
      color: #8a5300;
    }

    .review-panel__risk[data-risk='high'] {
      background: #ffe7d8;
      color: #a63b00;
    }

    .review-panel__risk[data-risk='critical'] {
      background: #ffe3e3;
      color: #9b1d20;
    }

    .review-panel__risk--large {
      align-self: flex-start;
    }

    .review-panel__table {
      display: grid;
      gap: 8px;
    }

    .review-panel__row {
      display: grid;
      grid-template-columns: minmax(160px, 1.4fr) minmax(0, 1fr) minmax(0, 1fr) 120px;
      gap: 12px;
      padding: 10px 12px;
      border-radius: 12px;
      background: #f6f8fb;
      align-items: center;
    }

    .review-panel__row--header {
      background: transparent;
      padding: 0 12px 4px;
      font-size: 12px;
      font-weight: 700;
      color: #4c627a;
    }

    .review-panel__row[data-change='changed'],
    .review-panel__row[data-change='added'],
    .review-panel__row[data-change='removed'] {
      background: #eef6ff;
      border: 1px solid #cfe4ff;
    }

    .review-panel__change {
      text-transform: capitalize;
      font-weight: 600;
    }

    .review-panel__textarea {
      width: 100%;
      border: 1px solid #cfd8e3;
      border-radius: 14px;
      padding: 12px 14px;
      font: inherit;
      font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
      resize: vertical;
      background: #f9fbfd;
    }

    .review-panel__textarea--compact {
      font-family: inherit;
    }

    .review-panel__error {
      color: #b42318;
      font-weight: 600;
    }

    .review-panel__footer {
      justify-content: flex-end;
    }

    .review-panel__button {
      border: none;
      border-radius: 999px;
      padding: 10px 16px;
      font: inherit;
      font-weight: 700;
      cursor: pointer;
      background: #0a6ed1;
      color: #fff;
    }

    .review-panel__button--secondary {
      background: #edf2f7;
      color: #17324f;
    }

    .review-panel__button:disabled {
      opacity: 0.6;
      cursor: not-allowed;
    }

    @media (max-width: 900px) {
      .review-panel {
        grid-template-columns: 1fr;
      }

      .review-panel__row {
        grid-template-columns: 1fr;
      }
    }
  `],
})
export class GovernanceReviewPanelComponent implements OnInit, OnDestroy {
  pendingActions: PendingAction[] = [];
  selectedActionId: string | null = null;
  review: PendingActionReview | null = null;
  modificationsText = '{}';
  rejectionReason = '';
  parseError: string | null = null;
  submissionError: string | null = null;
  isSubmitting = false;

  private destroy$ = new Subject<void>();

  constructor(
    private governance: GovernanceService,
    private changeDetectorRef: ChangeDetectorRef,
  ) {}

  ngOnInit(): void {
    this.governance.pendingActions$
      .pipe(takeUntil(this.destroy$))
      .subscribe(actions => {
        this.pendingActions = actions;

        if (!actions.some(action => action.id === this.selectedActionId)) {
          this.selectedActionId = actions[0]?.id ?? null;
          this.resetEditorState();
        }

        this.refreshReview();
      });
  }

  ngOnDestroy(): void {
    this.destroy$.next();
    this.destroy$.complete();
  }

  trackByActionId(_index: number, action: PendingAction): string {
    return action.id;
  }

  trackByDiffPath(_index: number, entry: ActionDiffEntry): string {
    return `${entry.path}-${entry.changeType}`;
  }

  selectAction(actionId: string): void {
    if (this.selectedActionId === actionId) {
      return;
    }

    this.selectedActionId = actionId;
    this.resetEditorState();
    this.refreshReview();
  }

  onModificationsInput(value: string): void {
    this.submissionError = null;
    this.modificationsText = value;
    this.parseModifications();
    this.refreshReview();
  }

  onRejectionReasonInput(value: string): void {
    this.submissionError = null;
    this.rejectionReason = value;
  }

  async confirmSelectedAction(): Promise<void> {
    if (!this.selectedActionId) {
      return;
    }

    const modifications = this.parseModifications();
    if (modifications === null) {
      this.changeDetectorRef.markForCheck();
      return;
    }

    this.submissionError = null;
    this.isSubmitting = true;
    this.changeDetectorRef.markForCheck();

    try {
      await this.governance.confirmAction(
        this.selectedActionId,
        Object.keys(modifications).length > 0 ? modifications : undefined,
      );
      this.resetEditorState();
    } catch (error) {
      this.submissionError = this.formatSubmissionError('approve', error);
    } finally {
      this.isSubmitting = false;
      this.refreshReview();
      this.changeDetectorRef.markForCheck();
    }
  }

  async rejectSelectedAction(): Promise<void> {
    if (!this.selectedActionId) {
      return;
    }

    this.submissionError = null;
    this.isSubmitting = true;
    this.changeDetectorRef.markForCheck();

    try {
      await this.governance.rejectAction(
        this.selectedActionId,
        this.rejectionReason.trim() || undefined,
      );
      this.rejectionReason = '';
    } catch (error) {
      this.submissionError = this.formatSubmissionError('reject', error);
    } finally {
      this.isSubmitting = false;
      this.refreshReview();
      this.changeDetectorRef.markForCheck();
    }
  }

  formatValue(value: unknown): string {
    if (value === undefined) {
      return '—';
    }
    if (typeof value === 'string') {
      return value;
    }
    return JSON.stringify(value);
  }

  getRiskChipLabel(action: PendingAction): string {
    return action.riskLevel.toUpperCase();
  }

  private refreshReview(): void {
    const action = this.pendingActions.find(item => item.id === this.selectedActionId);
    if (!action) {
      this.review = null;
      this.changeDetectorRef.markForCheck();
      return;
    }

    const modifications = this.parseModifications(false);
    this.review = this.governance.buildPendingActionReview(action, modifications ?? {}) ?? null;
    this.changeDetectorRef.markForCheck();
  }

  private parseModifications(updateErrorState = true): Record<string, unknown> | null {
    const raw = this.modificationsText.trim();

    if (!raw || raw === '{}') {
      if (updateErrorState) {
        this.parseError = null;
      }
      return {};
    }

    try {
      const parsed = JSON.parse(raw);
      if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) {
        throw new Error('Operator modifications must be a JSON object.');
      }

      if (updateErrorState) {
        this.parseError = null;
      }

      return parsed as Record<string, unknown>;
    } catch (error) {
      if (updateErrorState) {
        this.parseError = error instanceof Error && error.message === 'Operator modifications must be a JSON object.'
          ? error.message
          : 'Operator modifications must be valid JSON.';
      }
      return null;
    }
  }

  private resetEditorState(): void {
    this.modificationsText = '{}';
    this.rejectionReason = '';
    this.parseError = null;
    this.submissionError = null;
  }

  private formatSubmissionError(action: 'approve' | 'reject', error: unknown): string {
    const prefix = action === 'approve' ? 'Approval failed' : 'Rejection failed';
    if (error instanceof Error && error.message) {
      return `${prefix}: ${error.message}`;
    }

    return `${prefix}. Try again.`;
  }
}
