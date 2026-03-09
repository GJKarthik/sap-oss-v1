/**
 * SAC Button Component
 *
 * Angular button component for SAP Analytics Cloud.
 * Selector: sac-button (from mangle widget_category "Button")
 */

import {
  Component,
  Input,
  Output,
  EventEmitter,
  ChangeDetectionStrategy,
} from '@angular/core';

@Component({
  selector: 'sac-button',
  template: `
    <button
      class="sac-button"
      [class]="cssClass"
      [class.sac-button--primary]="type === 'primary'"
      [class.sac-button--secondary]="type === 'secondary'"
      [class.sac-button--ghost]="type === 'ghost'"
      [disabled]="disabled"
      [style.display]="visible ? 'inline-flex' : 'none'"
      (click)="handleClick($event)">
      <span class="sac-button__icon" *ngIf="icon">
        <i [class]="icon"></i>
      </span>
      <span class="sac-button__text">{{ text }}</span>
    </button>
  `,
  styles: [`
    .sac-button {
      display: inline-flex;
      align-items: center;
      justify-content: center;
      padding: 8px 16px;
      border: 1px solid #0854a0;
      border-radius: 4px;
      background: #0854a0;
      color: white;
      font-size: 14px;
      cursor: pointer;
      transition: all 0.2s ease;
    }
    .sac-button:hover:not(:disabled) {
      background: #074080;
    }
    .sac-button:disabled {
      opacity: 0.5;
      cursor: not-allowed;
    }
    .sac-button--secondary {
      background: transparent;
      color: #0854a0;
    }
    .sac-button--secondary:hover:not(:disabled) {
      background: rgba(8, 84, 160, 0.1);
    }
    .sac-button--ghost {
      background: transparent;
      border-color: transparent;
      color: #0854a0;
    }
    .sac-button__icon {
      margin-right: 8px;
    }
  `],
  changeDetection: ChangeDetectionStrategy.OnPush,
})
export class SacButtonComponent {
  @Input() text = '';
  @Input() type: 'primary' | 'secondary' | 'ghost' = 'primary';
  @Input() icon?: string;
  @Input() disabled = false;
  @Input() visible = true;
  @Input() cssClass = '';

  @Output() onClick = new EventEmitter<MouseEvent>();

  handleClick(event: MouseEvent): void {
    if (!this.disabled) {
      this.onClick.emit(event);
    }
  }
}