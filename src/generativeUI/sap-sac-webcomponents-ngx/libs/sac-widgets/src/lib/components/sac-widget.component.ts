/**
 * SAC Widget Component — Base widget wrapper
 *
 * Selector: sac-widget (derived from mangle/sac_widget.mg)
 * Wraps the Widget base class from sap-sac-webcomponents-ts/src/widgets.
 */

import {
  Component,
  Input,
  Output,
  EventEmitter,
  OnInit,
  OnDestroy,
  ChangeDetectionStrategy,
} from '@angular/core';

import { SacWidgetService } from '../services/sac-widget.service';
import type { WidgetResizeEvent } from '../types/widget-events.types';

@Component({
  selector: 'sac-widget',
  template: `
    <div class="sac-widget"
         [class]="cssClass"
         [style.width]="width"
         [style.height]="height"
         [style.display]="visible ? 'block' : 'none'"
         [class.sac-widget--disabled]="!enabled">
      <ng-content></ng-content>
    </div>
  `,
  styles: [`
    .sac-widget {
      position: relative;
      box-sizing: border-box;
    }
    .sac-widget--disabled {
      opacity: 0.5;
      pointer-events: none;
    }
  `],
  changeDetection: ChangeDetectionStrategy.OnPush,
})
export class SacWidgetComponent implements OnInit, OnDestroy {
  @Input() widgetId = '';
  @Input() visible = true;
  @Input() enabled = true;
  @Input() cssClass = '';
  @Input() width = 'auto';
  @Input() height = 'auto';

  @Output() onClick = new EventEmitter<MouseEvent>();
  @Output() onResize = new EventEmitter<WidgetResizeEvent>();

  constructor(private widgetService: SacWidgetService) {}

  ngOnInit(): void {
    if (this.widgetId) {
      this.widgetService.register(this.widgetId, {
        visible: this.visible,
        enabled: this.enabled,
        cssClass: this.cssClass,
        width: this.width,
        height: this.height,
      });
    }
  }

  ngOnDestroy(): void {
    if (this.widgetId) {
      this.widgetService.unregister(this.widgetId);
    }
  }
}
