import {
  ChangeDetectorRef,
  Component,
  ElementRef,
  EventEmitter,
  Input as InputDecorator,
  NgZone,
  booleanAttribute,
  inject,
} from '@angular/core';
import '@ui5/webcomponents-fiori/dist/NotificationListGroupItem.js';
import NotificationListGroupItem from '@ui5/webcomponents-fiori/dist/NotificationListGroupItem.js';
import { ProxyInputs, ProxyOutputs } from '@ui5/webcomponents-ngx/utils';
@ProxyInputs([
  'titleText',
  'read',
  'loading',
  'loadingDelay',
  'collapsed',
  'growing',
])
@ProxyOutputs(['toggle: ui5Toggle', 'load-more: ui5LoadMore'])
@Component({
  standalone: true,
  selector: 'ui5-li-notification-group',
  template: '<ng-content></ng-content>',
  inputs: [
    'titleText',
    'read',
    'loading',
    'loadingDelay',
    'collapsed',
    'growing',
  ],
  outputs: ['ui5Toggle', 'ui5LoadMore'],
  exportAs: 'ui5LiNotificationGroup',
})
class NotificationListGroupItemComponent {
  /**
        Defines the `titleText` of the item.
        */
  titleText!: string | undefined;
  /**
        Defines if the `notification` is new or has been already read.

**Note:** if set to `false` the `titleText` has bold font,
if set to true - it has a normal font.
        */
  @InputDecorator({ transform: booleanAttribute })
  read!: boolean;
  /**
        Defines if a busy indicator would be displayed over the item.
        */
  @InputDecorator({ transform: booleanAttribute })
  loading!: boolean;
  /**
        Defines the delay in milliseconds, after which the busy indicator will show up for this component.
        */
  loadingDelay!: number;
  /**
        Defines if the group is collapsed or expanded.
        */
  @InputDecorator({ transform: booleanAttribute })
  collapsed!: boolean;
  /**
        Defines whether the component will have growing capability by pressing a `More` button.
When button is pressed `load-more` event will be fired.
        */
  growing!: 'Button' | 'None';

  /**
     Fired when the `ui5-li-notification-group` is expanded/collapsed by user interaction.
    */
  ui5Toggle!: EventEmitter<void>;
  /**
     Fired when additional items are requested.
    */
  ui5LoadMore!: EventEmitter<void>;

  private elementRef: ElementRef<NotificationListGroupItem> =
    inject(ElementRef);
  private zone = inject(NgZone);
  private cdr = inject(ChangeDetectorRef);

  get element(): NotificationListGroupItem {
    return this.elementRef.nativeElement;
  }

  constructor() {
    this.cdr.detach();
  }
}
export { NotificationListGroupItemComponent };
