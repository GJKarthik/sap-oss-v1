import {
  ChangeDetectorRef,
  Component,
  ElementRef,
  Input as InputDecorator,
  NgZone,
  booleanAttribute,
  inject,
} from '@angular/core';
import '@ui5/webcomponents-fiori/dist/IllustratedMessage.js';
import IllustratedMessage from '@ui5/webcomponents-fiori/dist/IllustratedMessage.js';
import { ProxyInputs } from '@ui5/webcomponents-ngx/utils';
@ProxyInputs([
  'name',
  'design',
  'subtitleText',
  'titleText',
  'accessibleNameRef',
  'decorative',
])
@Component({
  standalone: true,
  selector: 'ui5-illustrated-message',
  template: '<ng-content></ng-content>',
  inputs: [
    'name',
    'design',
    'subtitleText',
    'titleText',
    'accessibleNameRef',
    'decorative',
  ],
  exportAs: 'ui5IllustratedMessage',
})
class IllustratedMessageComponent {
  /**
        Defines the illustration name that will be displayed in the component.

Example:

`name='BeforeSearch'`, `name='UnableToUpload'`, etc..

**Note:** To use the TNT illustrations,
you need to set the `tnt` or `Tnt` prefix in front of the icon's name.

Example:

`name='tnt/Avatar'` or `name='TntAvatar'`.

**Note:** By default the `BeforeSearch` illustration is loaded.
When using an illustration type, other than the default, it should be loaded in addition:

`import "@ui5/webcomponents-fiori/dist/illustrations/NoData.js";`

For TNT illustrations:

`import "@ui5/webcomponents-fiori/dist/illustrations/tnt/SessionExpired.js";`
        */
  name!: string;
  /**
        Determines which illustration breakpoint variant is used.

As `IllustratedMessage` adapts itself around the `Illustration`, the other
elements of the component are displayed differently on the different breakpoints/illustration designs.
        */
  design!:
    | 'Auto'
    | 'Base'
    | 'Dot'
    | 'Spot'
    | 'Dialog'
    | 'Scene'
    | 'ExtraSmall'
    | 'Small'
    | 'Medium'
    | 'Large';
  /**
        Defines the subtitle of the component.

**Note:** Using this property, the default subtitle text of illustration will be overwritten.

**Note:** Using `subtitle` slot, the default of this property will be overwritten.
        */
  subtitleText!: string | undefined;
  /**
        Defines the title of the component.

**Note:** Using this property, the default title text of illustration will be overwritten.
        */
  titleText!: string | undefined;
  /**
        Receives id(or many ids) of the elements that label the component.
        */
  accessibleNameRef!: string | undefined;
  /**
        Defines whether the illustration is decorative.

When set to `true`, the attributes `role="presentation"` and `aria-hidden="true"` are applied to the SVG element.
        */
  @InputDecorator({ transform: booleanAttribute })
  decorative!: boolean;

  private elementRef: ElementRef<IllustratedMessage> = inject(ElementRef);
  private zone = inject(NgZone);
  private cdr = inject(ChangeDetectorRef);

  get element(): IllustratedMessage {
    return this.elementRef.nativeElement;
  }

  constructor() {
    this.cdr.detach();
  }
}
export { IllustratedMessageComponent };
