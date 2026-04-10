import {
  Component,
  ChangeDetectionStrategy,
  CUSTOM_ELEMENTS_SCHEMA,
  Input,
  Output,
  EventEmitter,
} from '@angular/core';
import { CommonModule } from '@angular/common';

export interface CoworkPlanStep {
  id: string;
  title: string;
  description: string;
  status: 'pending' | 'approved' | 'rejected';
}

export interface CoworkPlan {
  id: string;
  title: string;
  summary: string;
  steps: CoworkPlanStep[];
  status: 'proposed' | 'approved' | 'executing' | 'completed' | 'rejected';
}

@Component({
  selector: 'app-cowork-plan',
  standalone: true,
  imports: [CommonModule],
  schemas: [CUSTOM_ELEMENTS_SCHEMA],
  changeDetection: ChangeDetectionStrategy.OnPush,
  template: `
    <ui5-card class="cowork-plan" [class.cowork-plan--approved]="plan.status === 'approved'"
              [class.cowork-plan--executing]="plan.status === 'executing'">
      <ui5-card-header
        slot="header"
        [attr.title-text]="plan.title"
        [attr.subtitle-text]="plan.summary"
        [attr.status]="statusBadgeText">
      </ui5-card-header>

      <div class="cowork-plan__steps">
        @for (step of plan.steps; track step.id; let i = $index) {
          <div class="cowork-plan__step" [class.cowork-plan__step--approved]="step.status === 'approved'">
            <div class="cowork-plan__step-number">{{ i + 1 }}</div>
            <div class="cowork-plan__step-content">
              <ui5-text class="cowork-plan__step-title">{{ step.title }}</ui5-text>
              <ui5-text class="cowork-plan__step-desc">{{ step.description }}</ui5-text>
            </div>
            @if (plan.status === 'proposed') {
              <ui5-icon
                [name]="step.status === 'approved' ? 'accept' : 'pending'"
                class="cowork-plan__step-icon"
                [class.cowork-plan__step-icon--approved]="step.status === 'approved'">
              </ui5-icon>
            }
          </div>
        }
      </div>

      @if (plan.status === 'proposed') {
        <div class="cowork-plan__actions">
          <ui5-button design="Emphasized" icon="accept" (click)="approve.emit(plan.id)">Approve</ui5-button>
          <ui5-button design="Transparent" icon="edit" (click)="edit.emit(plan.id)">Edit</ui5-button>
          <ui5-button design="Negative" icon="decline" (click)="reject.emit(plan.id)">Reject</ui5-button>
        </div>
      }
    </ui5-card>
  `,
  styles: [`
    .cowork-plan {
      margin: 0.75rem 0;
      border-left: 3px solid var(--sapInformativeColor, #0070f2);
      transition: border-color 0.3s ease;
    }
    .cowork-plan--approved { border-left-color: var(--sapPositiveColor, #2b7c2b); }
    .cowork-plan--executing { border-left-color: var(--sapCriticalColor, #e78c07); }

    .cowork-plan__steps {
      display: flex;
      flex-direction: column;
      gap: 0.5rem;
      padding: 0.75rem 1rem;
    }
    .cowork-plan__step {
      display: flex;
      align-items: flex-start;
      gap: 0.75rem;
      padding: 0.5rem;
      border-radius: 0.5rem;
      background: rgba(0, 0, 0, 0.02);
      transition: background 0.2s ease;
    }
    .cowork-plan__step--approved {
      background: rgba(43, 124, 43, 0.06);
    }
    .cowork-plan__step-number {
      width: 1.5rem;
      height: 1.5rem;
      border-radius: 50%;
      background: var(--sapBrandColor, #0070f2);
      color: white;
      display: flex;
      align-items: center;
      justify-content: center;
      font-size: 0.75rem;
      font-weight: 700;
      flex-shrink: 0;
    }
    .cowork-plan__step-content {
      display: flex;
      flex-direction: column;
      gap: 0.125rem;
      flex: 1;
    }
    .cowork-plan__step-title { font-weight: 600; font-size: 0.875rem; }
    .cowork-plan__step-desc { font-size: 0.8125rem; color: var(--sapContent_LabelColor, #6a6d70); }
    .cowork-plan__step-icon { font-size: 1rem; color: var(--sapContent_LabelColor); }
    .cowork-plan__step-icon--approved { color: var(--sapPositiveColor, #2b7c2b); }

    .cowork-plan__actions {
      display: flex;
      gap: 0.5rem;
      padding: 0.75rem 1rem;
      border-top: 0.5px solid rgba(0, 0, 0, 0.08);
    }
  `],
})
export class CoworkPlanComponent {
  @Input({ required: true }) plan!: CoworkPlan;
  @Output() approve = new EventEmitter<string>();
  @Output() edit = new EventEmitter<string>();
  @Output() reject = new EventEmitter<string>();

  get statusBadgeText(): string {
    const map: Record<string, string> = {
      proposed: 'Proposed',
      approved: 'Approved',
      executing: 'Executing…',
      completed: 'Completed',
      rejected: 'Rejected',
    };
    return map[this.plan.status] || this.plan.status;
  }
}
