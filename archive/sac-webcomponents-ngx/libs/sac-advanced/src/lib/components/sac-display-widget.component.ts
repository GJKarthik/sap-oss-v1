/**
 * SAC Display Widget Component — Text, Image, Shape, WebPage, Icon widgets
 *
 * Selector: sac-display-widget (derived from mangle/sac_widget.mg)
 * Wraps TextWidget, ImageWidget, ShapeWidget, WebPageWidget, IconWidget
 * from sap-sac-webcomponents-ts/src/advanced.
 */

import {
  Component,
  Input,
  Output,
  EventEmitter,
  ChangeDetectionStrategy,
} from '@angular/core';

export type DisplayWidgetType = 'text' | 'image' | 'shape' | 'webpage' | 'icon';

@Component({
  selector: 'sac-display-widget',
  template: `
    <div class="sac-display-widget"
         [class]="cssClass"
         [style.width]="width"
         [style.height]="height"
         [style.display]="visible ? 'block' : 'none'"
         (click)="onClick.emit($event)">

      <div *ngIf="widgetType === 'text'" class="sac-display-widget__text"
           [innerHTML]="text"></div>

      <img *ngIf="widgetType === 'image'" class="sac-display-widget__image"
           [src]="src" [alt]="alt" />

      <div *ngIf="widgetType === 'shape'" class="sac-display-widget__shape"
           [style.background]="fillColor"
           [style.borderColor]="strokeColor"></div>

      <iframe *ngIf="widgetType === 'webpage'" class="sac-display-widget__iframe"
              [src]="src" frameborder="0"></iframe>

      <span *ngIf="widgetType === 'icon'" class="sac-display-widget__icon"
            [style.color]="iconColor"
            [style.fontSize]="iconSize">{{ iconName }}</span>
    </div>
  `,
  styles: [`
    .sac-display-widget {
      position: relative;
      box-sizing: border-box;
      overflow: hidden;
    }
    .sac-display-widget__text {
      padding: 8px;
    }
    .sac-display-widget__image {
      width: 100%;
      height: 100%;
      object-fit: contain;
    }
    .sac-display-widget__shape {
      width: 100%;
      height: 100%;
      border: 2px solid #333;
      border-radius: 4px;
    }
    .sac-display-widget__iframe {
      width: 100%;
      height: 100%;
      border: none;
    }
    .sac-display-widget__icon {
      display: flex;
      align-items: center;
      justify-content: center;
      width: 100%;
      height: 100%;
    }
  `],
  changeDetection: ChangeDetectionStrategy.OnPush,
})
export class SacDisplayWidgetComponent {
  @Input() widgetId = '';
  @Input() visible = true;
  @Input() cssClass = '';
  @Input() width = 'auto';
  @Input() height = 'auto';
  @Input() widgetType: DisplayWidgetType = 'text';

  // Text inputs
  @Input() text = '';

  // Image inputs
  @Input() src: any = '';
  @Input() alt = '';

  // Shape inputs
  @Input() fillColor = 'transparent';
  @Input() strokeColor = '#333';

  // Icon inputs
  @Input() iconName = '';
  @Input() iconColor = '#333';
  @Input() iconSize = '24px';

  @Output() onClick = new EventEmitter<MouseEvent>();
}
