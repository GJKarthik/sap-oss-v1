import {
  Component,
  Input,
  Output,
  EventEmitter,
  ChangeDetectionStrategy,
} from '@angular/core';

@Component({
  selector: 'sac-planning-panel',
  changeDetection: ChangeDetectionStrategy.OnPush,
  template: `
    <div class="sac-planning-panel"
         [class]="cssClass"
         [style.display]="visible ? 'block' : 'none'">
      <div class="sac-planning-panel__header" *ngIf="title">
        <h3>{{ title }}</h3>
        <span class="sac-planning-panel__status" *ngIf="status">{{ status }}</span>
      </div>
      <div class="sac-planning-panel__content">
        <ng-content></ng-content>
      </div>
    </div>
  `,
  styles: [`
    .sac-planning-panel { border: 1px solid #d9d9d9; border-radius: 4px; overflow: hidden; }
    .sac-planning-panel__header { display: flex; justify-content: space-between; align-items: center; padding: 8px 12px; background: #f5f6f7; border-bottom: 1px solid #d9d9d9; }
    .sac-planning-panel__header h3 { margin: 0; font-size: 14px; font-weight: 600; }
    .sac-planning-panel__status { font-size: 12px; color: #6a6d70; }
    .sac-planning-panel__content { padding: 12px; }
  `],
})
export class SacPlanningPanelComponent {
  @Input() title = '';
  @Input() status = '';
  @Input() visible = true;
  @Input() cssClass = '';

  @Output() statusChange = new EventEmitter<string>();
}
