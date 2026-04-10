import { Component, ChangeDetectionStrategy, input, output, CUSTOM_ELEMENTS_SCHEMA } from '@angular/core';
import type { CoworkPlan } from '../../utils/mode.types';

@Component({
  selector: 'app-cowork-plan',
  standalone: true,
  schemas: [CUSTOM_ELEMENTS_SCHEMA],
  changeDetection: ChangeDetectionStrategy.OnPush,
  template: `
    <div class="cowork-plan" [class]="'cowork-plan--' + plan().status">
      <div class="plan-header">
        <span class="plan-label">
          @switch (plan().status) {
            @case ('proposed') { PROPOSED PLAN }
            @case ('executing') { EXECUTING }
            @case ('completed') { COMPLETED }
            @case ('rejected') { REJECTED }
            @default { PLAN }
          }
        </span>
      </div>

      <div class="plan-steps">
        @for (step of plan().steps; track step.label; let i = $index) {
          <div class="plan-step" [class]="'plan-step--' + step.status">
            <span class="step-indicator">
              @switch (step.status) {
                @case ('completed') { <ui5-icon name="status-positive" class="step-icon step-icon--success"></ui5-icon> }
                @case ('running') { <ui5-icon name="synchronize" class="step-icon step-icon--running"></ui5-icon> }
                @case ('failed') { <ui5-icon name="status-negative" class="step-icon step-icon--failed"></ui5-icon> }
                @default { {{ i + 1 }} }
              }
            </span>
            <div class="step-content">
              <strong>{{ step.label }}</strong>
              <span class="step-desc">{{ step.description }}</span>
            </div>
          </div>
        }
      </div>

      @if (plan().status === 'proposed') {
        <div class="plan-actions">
          <button class="plan-btn plan-btn--primary" (click)="approve(plan())">Approve</button>
          <button class="plan-btn plan-btn--ghost" (click)="edit(plan())">Edit plan</button>
          <button class="plan-btn plan-btn--ghost" (click)="reject(plan())">Reject</button>
        </div>
      }
    </div>
  `,
  styles: [`
    .cowork-plan {
      border-radius: 0.75rem;
      padding: 0.875rem;
      margin: 0.5rem 0;
    }

    .cowork-plan--proposed {
      background: var(--sapInformationBackground, rgba(10, 110, 209, 0.1));
      border: 1px solid var(--sapInformationBorderColor, rgba(10, 110, 209, 0.25));
    }

    .cowork-plan--executing {
      background: var(--sapSuccessBackground, rgba(39, 174, 96, 0.1));
      border: 1px solid var(--sapSuccessBorderColor, rgba(39, 174, 96, 0.25));
    }

    .cowork-plan--completed {
      background: var(--sapSuccessBackground, rgba(39, 174, 96, 0.08));
      border: 1px solid var(--sapSuccessBorderColor, rgba(39, 174, 96, 0.15));
    }

    .cowork-plan--rejected {
      background: var(--sapNeutralBackground, rgba(255, 255, 255, 0.04));
      border: 1px solid var(--sapNeutralBorderColor, rgba(255, 255, 255, 0.1));
      opacity: 0.6;
    }

    .plan-header { margin-bottom: 0.5rem; }

    .plan-label {
      font-size: 0.75rem;
      font-weight: 600;
      letter-spacing: 0.05em;
      color: var(--sapInformativeColor, #0a6ed1);
    }

    .cowork-plan--executing .plan-label {
      color: var(--sapPositiveColor, #27ae60);
    }

    .plan-steps {
      display: flex;
      flex-direction: column;
      gap: 0.25rem;
    }

    .plan-step {
      display: flex;
      align-items: flex-start;
      gap: 0.5rem;
      padding: 0.25rem 0 0.25rem 0.75rem;
      border-left: 2px solid var(--sapInformationBorderColor, rgba(10, 110, 209, 0.3));
    }

    .step-indicator {
      min-width: 1.25rem;
      text-align: center;
      font-size: 0.8125rem;
    }

    .step-icon { font-size: 0.875rem; }
    .step-icon--success { color: var(--sapPositiveColor, #27ae60); }
    .step-icon--running {
      color: var(--sapInformativeColor, #0a6ed1);
      animation: spin 1.2s linear infinite;
    }
    .step-icon--failed { color: var(--sapNegativeColor, #e74c3c); }
    @keyframes spin { to { transform: rotate(360deg); } }

    .step-content {
      display: flex;
      flex-direction: column;
      font-size: 0.8125rem;
      color: var(--sapTextColor, #e0e0e0);
    }

    .step-desc {
      color: var(--sapContent_LabelColor, rgba(255, 255, 255, 0.5));
      font-size: 0.75rem;
    }

    .plan-actions {
      display: flex;
      gap: 0.5rem;
      margin-top: 0.75rem;
    }

    .plan-btn {
      padding: 0.375rem 1rem;
      border-radius: 0.375rem;
      font-size: 0.75rem;
      font-weight: 600;
      cursor: pointer;
      border: none;
      transition: all 150ms ease;
    }

    .plan-btn--primary {
      background: var(--sapButton_Emphasized_Background, linear-gradient(135deg, #0a6ed1, #1a8fff));
      color: var(--sapButton_Emphasized_TextColor, white);
    }

    .plan-btn--ghost {
      background: var(--sapButton_Lite_Background, rgba(255, 255, 255, 0.08));
      color: var(--sapButton_Lite_TextColor, rgba(255, 255, 255, 0.7));
      border: 1px solid var(--sapButton_Lite_BorderColor, rgba(255, 255, 255, 0.15));
    }

    .plan-btn--ghost:hover {
      background: var(--sapButton_Lite_Hover_Background, rgba(255, 255, 255, 0.12));
    }
  `],
})
export class CoworkPlanComponent {
  plan = input.required<CoworkPlan>();

  planApproved = output<CoworkPlan>();
  planEdited = output<CoworkPlan>();
  planRejected = output<CoworkPlan>();

  approve(plan: CoworkPlan): void {
    this.planApproved.emit(plan);
  }

  edit(plan: CoworkPlan): void {
    this.planEdited.emit(plan);
  }

  reject(plan: CoworkPlan): void {
    this.planRejected.emit(plan);
  }
}
