import {
  ChangeDetectorRef,
  Component,
  ElementRef,
  EventEmitter,
  NgZone,
  inject,
} from '@angular/core';
import '@ui5/webcomponents-fiori/dist/NotificationList.js';
import {
  NotificationItemClickEventDetail,
  NotificationItemCloseEventDetail,
  NotificationItemToggleEventDetail,
  default as NotificationList,
} from '@ui5/webcomponents-fiori/dist/NotificationList.js';
import { ProxyInputs, ProxyOutputs } from '@ui5/webcomponents-ngx/utils';
@ProxyInputs(['noDataText'])
@ProxyOutputs([
  'item-click: ui5ItemClick',
  'item-close: ui5ItemClose',
  'item-toggle: ui5ItemToggle',
])
@Component({
  standalone: true,
  selector: 'ui5-notification-list',
  template: '<ng-content></ng-content>',
  inputs: ['noDataText'],
  outputs: ['ui5ItemClick', 'ui5ItemClose', 'ui5ItemToggle'],
  exportAs: 'ui5NotificationList',
})
class NotificationListComponent {
  /**
        Defines the text that is displayed when the component contains no items.
        */
  noDataText!: string | undefined;

  /**
     Fired when an item is clicked.
    */
  ui5ItemClick!: EventEmitter<NotificationItemClickEventDetail>;
  /**
     Fired when the `Close` button of any item is clicked.
    */
  ui5ItemClose!: EventEmitter<NotificationItemCloseEventDetail>;
  /**
     Fired when an item is toggled.
    */
  ui5ItemToggle!: EventEmitter<NotificationItemToggleEventDetail>;

  private elementRef: ElementRef<NotificationList> = inject(ElementRef);
  private zone = inject(NgZone);
  private cdr = inject(ChangeDetectorRef);

  get element(): NotificationList {
    return this.elementRef.nativeElement;
  }

  constructor() {
    this.cdr.detach();
  }
}
export { NotificationListComponent };
