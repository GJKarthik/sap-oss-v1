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
import '@ui5/webcomponents-fiori/dist/NotificationListItem.js';
import {
  default as NotificationListItem,
  NotificationListItemCloseEventDetail,
} from '@ui5/webcomponents-fiori/dist/NotificationListItem.js';
import { ProxyInputs, ProxyOutputs } from '@ui5/webcomponents-ngx/utils';
@ProxyInputs([
  'titleText',
  'read',
  'loading',
  'loadingDelay',
  'wrappingType',
  'state',
  'showClose',
  'importance',
])
@ProxyOutputs(['close: ui5Close'])
@Component({
  standalone: true,
  selector: 'ui5-li-notification',
  template: '<ng-content></ng-content>',
  inputs: [
    'titleText',
    'read',
    'loading',
    'loadingDelay',
    'wrappingType',
    'state',
    'showClose',
    'importance',
  ],
  outputs: ['ui5Close'],
  exportAs: 'ui5LiNotification',
})
class NotificationListItemComponent {
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
        Defines if the `titleText` and `description` should wrap,
they truncate by default.

**Note:** by default the `titleText` and `description`,
and a `ShowMore/Less` button would be displayed.
        */
  wrappingType!: 'None' | 'Normal';
  /**
        Defines the status indicator of the item.
        */
  state!: 'None' | 'Positive' | 'Critical' | 'Negative' | 'Information';
  /**
        Defines if the `Close` button would be displayed.
        */
  @InputDecorator({ transform: booleanAttribute })
  showClose!: boolean;
  /**
        Defines the `Important` label of the item.
        */
  importance!: 'Standard' | 'Important';

  /**
     Fired when the `Close` button is pressed.
    */
  ui5Close!: EventEmitter<NotificationListItemCloseEventDetail>;

  private elementRef: ElementRef<NotificationListItem> = inject(ElementRef);
  private zone = inject(NgZone);
  private cdr = inject(ChangeDetectorRef);

  get element(): NotificationListItem {
    return this.elementRef.nativeElement;
  }

  constructor() {
    this.cdr.detach();
  }
}
export { NotificationListItemComponent };
