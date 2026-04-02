/**
 * SAC KPI Component — Key Performance Indicator tile
 *
 * Selector: sac-kpi (derived from mangle/sac_widget.mg)
 * Wraps KPI from sap-sac-webcomponents-ts/src/advanced.
 */

import {
  Component,
  Input,
  Output,
  EventEmitter,
  ChangeDetectionStrategy,
} from '@angular/core';

@Component({
  selector: 'sac-kpi',
  template: `
    <div class="sac-kpi"
         [class]="cssClass"
         [style.display]="visible ? 'flex' : 'none'"
         (click)="onClick.emit($event)">
      <div class="sac-kpi__title" *ngIf="title">{{ title }}</div>
      <div class="sac-kpi__value">{{ formattedValue }}</div>
      <div class="sac-kpi__target" *ngIf="target !== undefined">
        Target: {{ target }}
      </div>
      <div class="sac-kpi__trend" *ngIf="trend"
           [class.sac-kpi__trend--up]="trend === 'up'"
           [class.sac-kpi__trend--down]="trend === 'down'">
        {{ trend === 'up' ? '▲' : trend === 'down' ? '▼' : '►' }}
      </div>
    </div>
  `,
  styles: [`
    .sac-kpi {
      flex-direction: column;
      align-items: center;
      padding: 16px;
      border: 1px solid #e0e0e0;
      border-radius: 8px;
      background: #fff;
      cursor: pointer;
      transition: box-shadow 0.2s;
    }
    .sac-kpi:hover {
      box-shadow: 0 2px 8px rgba(0,0,0,0.1);
    }
    .sac-kpi__title {
      font-size: 12px;
      color: #666;
      text-transform: uppercase;
      letter-spacing: 0.5px;
      margin-bottom: 8px;
    }
    .sac-kpi__value {
      font-size: 28px;
      font-weight: 700;
      color: #333;
    }
    .sac-kpi__target {
      font-size: 12px;
      color: #999;
      margin-top: 4px;
    }
    .sac-kpi__trend {
      margin-top: 4px;
      font-size: 14px;
    }
    .sac-kpi__trend--up { color: #2b7d2b; }
    .sac-kpi__trend--down { color: #d32f2f; }
  `],
  changeDetection: ChangeDetectionStrategy.OnPush,
})
export class SacKpiComponent {
  @Input() widgetId = '';
  @Input() visible = true;
  @Input() cssClass = '';
  @Input() title = '';
  @Input() value: number | string = 0;
  @Input() target?: number;
  @Input() trend?: 'up' | 'down' | 'neutral';
  @Input() dataSource = '';

  @Output() onClick = new EventEmitter<MouseEvent>();

  get formattedValue(): string {
    if (typeof this.value === 'number') {
      return this.value.toLocaleString();
    }
    return String(this.value);
  }
}
