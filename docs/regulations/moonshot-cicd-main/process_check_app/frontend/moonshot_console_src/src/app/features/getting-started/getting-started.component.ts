import { CommonModule } from '@angular/common';
import { Component, CUSTOM_ELEMENTS_SCHEMA, inject } from '@angular/core';
import { Router } from '@angular/router';

interface ChecklistItem {
  id: string;
  label: string;
  checked: boolean;
}

@Component({
  selector: 'app-getting-started',
  standalone: true,
  imports: [CommonModule],
  schemas: [CUSTOM_ELEMENTS_SCHEMA],
  template: `
    <section class="page">
      <ui5-card>
        <ui5-card-header slot="header" title-text="Getting Started" subtitle-text="Prerequisites and setup checks">
          <ui5-icon slot="avatar" name="activate"></ui5-icon>
        </ui5-card-header>

        <div class="content">
          <p>Confirm the baseline setup before filling process-check assessments.</p>

          <ui5-list>
            <ui5-li *ngFor="let item of checklist" class="check-item">
              <ui5-checkbox [checked]="item.checked" (change)="setChecked(item.id, checkedFromEvent($event))">
                {{ item.label }}
              </ui5-checkbox>
            </ui5-li>
          </ui5-list>

          <div class="summary">
            Completed {{ completedCount() }} / {{ checklist.length }} prerequisites
          </div>

          <div class="actions">
            <ui5-button design="Transparent" icon="navigation-left-arrow" (click)="go('/welcome')">
              Back
            </ui5-button>
            <ui5-button
              design="Emphasized"
              icon="navigation-right-arrow"
              [disabled]="completedCount() < checklist.length"
              (click)="go('/process-checks')"
            >
              Continue
            </ui5-button>
          </div>
        </div>
      </ui5-card>
    </section>
  `,
  styles: [
    `
      .page {
        display: grid;
      }

      .content {
        padding: 1rem;
        display: grid;
        gap: 1rem;
      }

      .check-item {
        padding: 0.2rem 0;
      }

      .summary {
        font-size: 0.82rem;
        color: var(--sapContent_LabelColor);
      }

      .actions {
        display: flex;
        justify-content: space-between;
      }
    `,
  ],
})
export class GettingStartedComponent {
  private readonly router = inject(Router);

  checklist: ChecklistItem[] = [
    { id: 'scope', label: 'Assessment scope and system boundaries are defined', checked: false },
    { id: 'owners', label: 'Business owner, model owner, and risk owner are identified', checked: false },
    { id: 'datasets', label: 'Data sources and governance constraints are documented', checked: false },
    { id: 'runtime', label: 'Moonshot runtime endpoint is configured in Settings', checked: false },
  ];

  setChecked(id: string, checked: boolean): void {
    this.checklist = this.checklist.map((item) => (item.id === id ? { ...item, checked } : item));
  }

  checkedFromEvent(event: Event): boolean {
    const target = event.target as { checked?: boolean };
    return !!target.checked;
  }

  completedCount(): number {
    return this.checklist.filter((item) => item.checked).length;
  }

  go(path: string): void {
    void this.router.navigateByUrl(path);
  }
}
