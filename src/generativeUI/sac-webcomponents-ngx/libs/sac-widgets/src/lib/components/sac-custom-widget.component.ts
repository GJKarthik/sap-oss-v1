/**
 * SAC CustomWidget Component — Extensible widget for custom JS/HTML
 *
 * Selector: sac-custom-widget (derived from mangle/sac_widget.mg)
 * Wraps CustomWidget from sap-sac-webcomponents-ts/src/widgets.
 */

import {
  Component,
  Input,
  Output,
  EventEmitter,
  ChangeDetectionStrategy,
} from '@angular/core';

import type {
  CustomWidgetDataBinding,
  CustomWidgetProperty,
  CustomWidgetMessage,
} from '../types/widget.types';
import type { CustomWidgetMessageEvent, CustomWidgetPropertyChangeEvent } from '../types/widget-events.types';

@Component({
  selector: 'sac-custom-widget',
  template: `
    <div class="sac-custom-widget"
         [class]="cssClass"
         [style.width]="width"
         [style.height]="height"
         [style.display]="visible ? 'block' : 'none'">
      <ng-content></ng-content>
    </div>
  `,
  styles: [`
    .sac-custom-widget {
      position: relative;
      box-sizing: border-box;
    }
  `],
  changeDetection: ChangeDetectionStrategy.OnPush,
})
export class SacCustomWidgetComponent {
  @Input() widgetId = '';
  @Input() visible = true;
  @Input() enabled = true;
  @Input() cssClass = '';
  @Input() width = 'auto';
  @Input() height = 'auto';
  @Input() properties: CustomWidgetProperty[] = [];
  @Input() dataBinding?: CustomWidgetDataBinding;

  @Output() onMessage = new EventEmitter<CustomWidgetMessageEvent>();
  @Output() onPropertyChange = new EventEmitter<CustomWidgetPropertyChangeEvent>();

  getProperty(name: string): unknown {
    const prop = this.properties.find(p => p.name === name);
    return prop?.value;
  }

  setProperty(name: string, value: unknown): void {
    const prop = this.properties.find(p => p.name === name);
    if (prop) {
      const oldValue = prop.value;
      prop.value = value;
      this.onPropertyChange.emit({ propertyName: name, oldValue, newValue: value });
    }
  }

  sendMessage(message: CustomWidgetMessage): void {
    this.onMessage.emit({ type: message.type, payload: message.payload });
  }
}
