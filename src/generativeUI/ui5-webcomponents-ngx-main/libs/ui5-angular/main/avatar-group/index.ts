import {
  ChangeDetectorRef,
  Component,
  ElementRef,
  EventEmitter,
  NgZone,
  inject,
} from '@angular/core';
import { ProxyInputs, ProxyOutputs } from '@ui5/webcomponents-ngx/utils';
import '@ui5/webcomponents/dist/AvatarGroup.js';
import {
  default as AvatarGroup,
  AvatarGroupAccessibilityAttributes,
  AvatarGroupClickEventDetail,
} from '@ui5/webcomponents/dist/AvatarGroup.js';
@ProxyInputs([
  'type',
  'accessibilityAttributes',
  'accessibleName',
  'accessibleNameRef',
])
@ProxyOutputs(['click: ui5Click', 'overflow: ui5Overflow'])
@Component({
  standalone: true,
  selector: 'ui5-avatar-group',
  template: '<ng-content></ng-content>',
  inputs: [
    'type',
    'accessibilityAttributes',
    'accessibleName',
    'accessibleNameRef',
  ],
  outputs: ['ui5Click', 'ui5Overflow'],
  exportAs: 'ui5AvatarGroup',
})
class AvatarGroupComponent {
  /**
        Defines the mode of the `AvatarGroup`.
        */
  type!: 'Group' | 'Individual';
  /**
        Defines the additional accessibility attributes that will be applied to the component.
The following field is supported:

- **hasPopup**: Indicates the availability and type of interactive popup element, such as menu or dialog, that can be triggered by the button.
Accepts the following string values: `dialog`, `grid`, `listbox`, `menu` or `tree`.
        */
  accessibilityAttributes!: AvatarGroupAccessibilityAttributes;
  /**
        Defines the accessible name of the AvatarGroup.
When provided, this will override the default aria-label text.
        */
  accessibleName!: string | undefined;
  /**
        Receives id(s) of the elements that describe the AvatarGroup.
When provided, this will be used as aria-labelledby instead of aria-label.
        */
  accessibleNameRef!: string | undefined;

  /**
     Fired when the component is activated either with a
click/tap or by using the Enter or Space key.
    */
  ui5Click!: EventEmitter<AvatarGroupClickEventDetail>;
  /**
     Fired when the count of visible `ui5-avatar` elements in the
component has changed
    */
  ui5Overflow!: EventEmitter<void>;

  private elementRef: ElementRef<AvatarGroup> = inject(ElementRef);
  private zone = inject(NgZone);
  private cdr = inject(ChangeDetectorRef);

  get element(): AvatarGroup {
    return this.elementRef.nativeElement;
  }

  constructor() {
    this.cdr.detach();
  }
}
export { AvatarGroupComponent };
