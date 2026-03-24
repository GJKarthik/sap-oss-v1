import {
  ChangeDetectorRef,
  Component,
  ElementRef,
  EventEmitter,
  NgZone,
  inject,
} from '@angular/core';
import '@ui5/webcomponents-fiori/dist/ShellBarItem.js';
import {
  default as ShellBarItem,
  ShellBarItemAccessibilityAttributes,
  ShellBarItemClickEventDetail,
} from '@ui5/webcomponents-fiori/dist/ShellBarItem.js';
import { ProxyInputs, ProxyOutputs } from '@ui5/webcomponents-ngx/utils';
@ProxyInputs(['icon', 'text', 'count', 'accessibilityAttributes'])
@ProxyOutputs(['click: ui5Click'])
@Component({
  standalone: true,
  selector: 'ui5-shellbar-item',
  template: '<ng-content></ng-content>',
  inputs: ['icon', 'text', 'count', 'accessibilityAttributes'],
  outputs: ['ui5Click'],
  exportAs: 'ui5ShellbarItem',
})
class ShellBarItemComponent {
  /**
        Defines the name of the item's icon.
        */
  icon!: string | undefined;
  /**
        Defines the item text.

**Note:** The text is only displayed inside the overflow popover list view.
        */
  text!: string | undefined;
  /**
        Defines the count displayed in the top-right corner.
        */
  count!: string | undefined;
  /**
        Defines additional accessibility attributes on Shellbar Items.

The accessibility attributes support the following values:

- **expanded**: Indicates whether the button, or another grouping element it controls,
is currently expanded or collapsed.
Accepts the following string values: `true` or `false`.

- **hasPopup**: Indicates the availability and type of interactive popup element,
such as menu or dialog, that can be triggered by the button.

- **controls**: Identifies the element (or elements) whose contents
or presence are controlled by the component.
Accepts a lowercase string value, referencing the ID of the element it controls.
        */
  accessibilityAttributes!: ShellBarItemAccessibilityAttributes;

  /**
     Fired, when the item is pressed.
    */
  ui5Click!: EventEmitter<ShellBarItemClickEventDetail>;

  private elementRef: ElementRef<ShellBarItem> = inject(ElementRef);
  private zone = inject(NgZone);
  private cdr = inject(ChangeDetectorRef);

  get element(): ShellBarItem {
    return this.elementRef.nativeElement;
  }

  constructor() {
    this.cdr.detach();
  }
}
export { ShellBarItemComponent };
