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
import { ProxyInputs, ProxyOutputs } from '@ui5/webcomponents-ngx/utils';
import '@ui5/webcomponents/dist/Menu.js';
import {
  default as Menu,
  MenuBeforeCloseEventDetail,
  MenuBeforeOpenEventDetail,
  MenuItemClickEventDetail,
} from '@ui5/webcomponents/dist/Menu.js';
@ProxyInputs([
  'headerText',
  'open',
  'placement',
  'horizontalAlign',
  'loading',
  'loadingDelay',
  'opener',
])
@ProxyOutputs([
  'item-click: ui5ItemClick',
  'before-open: ui5BeforeOpen',
  'open: ui5Open',
  'before-close: ui5BeforeClose',
  'close: ui5Close',
])
@Component({
  standalone: true,
  selector: 'ui5-menu',
  template: '<ng-content></ng-content>',
  inputs: [
    'headerText',
    'open',
    'placement',
    'horizontalAlign',
    'loading',
    'loadingDelay',
    'opener',
  ],
  outputs: [
    'ui5ItemClick',
    'ui5BeforeOpen',
    'ui5Open',
    'ui5BeforeClose',
    'ui5Close',
  ],
  exportAs: 'ui5Menu',
})
class MenuComponent {
  /**
        Defines the header text of the menu (displayed on mobile).
        */
  headerText!: string | undefined;
  /**
        Indicates if the menu is open.
        */
  @InputDecorator({ transform: booleanAttribute })
  open!: boolean;
  /**
        Determines on which side the component is placed at.
        */
  placement!: 'Start' | 'End' | 'Top' | 'Bottom';
  /**
        Determines the horizontal alignment of the menu relative to its opener control.
        */
  horizontalAlign!: 'Center' | 'Start' | 'End' | 'Stretch';
  /**
        Defines if a loading indicator would be displayed inside the corresponding ui5-menu popover.
        */
  @InputDecorator({ transform: booleanAttribute })
  loading!: boolean;
  /**
        Defines the delay in milliseconds, after which the loading indicator will be displayed inside the corresponding ui5-menu popover.
        */
  loadingDelay!: number;
  /**
        Defines the ID or DOM Reference of the element at which the menu is shown.
When using this attribute in a declarative way, you must only use the `id` (as a string) of the element at which you want to show the popover.
You can only set the `opener` attribute to a DOM Reference when using JavaScript.
        */
  opener!: HTMLElement | string | null | undefined;

  /**
     Fired when an item is being clicked.

**Note:** Since 1.17.0 the event is preventable, allowing the menu to remain open after an item is pressed.
    */
  ui5ItemClick!: EventEmitter<MenuItemClickEventDetail>;
  /**
     Fired before the menu is opened. This event can be cancelled, which will prevent the menu from opening.

**Note:** Since 1.14.0 the event is also fired before a sub-menu opens.
    */
  ui5BeforeOpen!: EventEmitter<MenuBeforeOpenEventDetail>;
  /**
     Fired after the menu is opened.
    */
  ui5Open!: EventEmitter<void>;
  /**
     Fired before the menu is closed. This event can be cancelled, which will prevent the menu from closing.
    */
  ui5BeforeClose!: EventEmitter<MenuBeforeCloseEventDetail>;
  /**
     Fired after the menu is closed.
    */
  ui5Close!: EventEmitter<void>;

  private elementRef: ElementRef<Menu> = inject(ElementRef);
  private zone = inject(NgZone);
  private cdr = inject(ChangeDetectorRef);

  get element(): Menu {
    return this.elementRef.nativeElement;
  }

  constructor() {
    this.cdr.detach();
  }
}
export { MenuComponent };
