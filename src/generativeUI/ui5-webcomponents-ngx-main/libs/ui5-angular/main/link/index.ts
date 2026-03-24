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
import '@ui5/webcomponents/dist/Link.js';
import {
  default as Link,
  LinkAccessibilityAttributes,
  LinkClickEventDetail,
} from '@ui5/webcomponents/dist/Link.js';
@ProxyInputs([
  'disabled',
  'tooltip',
  'href',
  'target',
  'design',
  'interactiveAreaSize',
  'wrappingType',
  'accessibleName',
  'accessibleNameRef',
  'accessibleRole',
  'accessibilityAttributes',
  'accessibleDescription',
  'icon',
  'endIcon',
])
@ProxyOutputs(['click: ui5Click'])
@Component({
  standalone: true,
  selector: 'ui5-link',
  template: '<ng-content></ng-content>',
  inputs: [
    'disabled',
    'tooltip',
    'href',
    'target',
    'design',
    'interactiveAreaSize',
    'wrappingType',
    'accessibleName',
    'accessibleNameRef',
    'accessibleRole',
    'accessibilityAttributes',
    'accessibleDescription',
    'icon',
    'endIcon',
  ],
  outputs: ['ui5Click'],
  exportAs: 'ui5Link',
})
class LinkComponent {
  /**
        Defines whether the component is disabled.

**Note:** When disabled, the click event cannot be triggered by the user.
        */
  @InputDecorator({ transform: booleanAttribute })
  disabled!: boolean;
  /**
        Defines the tooltip of the component.
        */
  tooltip!: string | undefined;
  /**
        Defines the component href.

**Note:** Standard hyperlink behavior is supported.
        */
  href!: string | undefined;
  /**
        Defines the component target.

**Notes:**

- `_self`
- `_top`
- `_blank`
- `_parent`
- `_search`

**This property must only be used when the `href` property is set.**
        */
  target!: string | undefined;
  /**
        Defines the component design.

**Note:** Avaialble options are `Default`, `Subtle`, and `Emphasized`.
        */
  design!: 'Default' | 'Subtle' | 'Emphasized';
  /**
        Defines the target area size of the link:
- **InteractiveAreaSize.Normal**: The default target area size.
- **InteractiveAreaSize.Large**: The target area size is enlarged to 24px in height.

**Note:**The property is designed to make links easier to activate and helps meet the WCAG 2.2 Target Size requirement. It is applicable only for the SAP Horizon themes.
**Note:**To improve <code>ui5-link</code>'s reliability and usability, it is recommended to use the <code>InteractiveAreaSize.Large</code> value in scenarios where the <code>ui5-link</code> component is placed inside another interactive component, such as a list item or a table cell.
Setting the <code>interactiveAreaSize</code> property to <code>InteractiveAreaSize.Large</code> increases the <code>ui5-link</code>'s invisible touch area. As a result, the user's intended one-time selection command is more likely to activate the desired <code>ui5-link</code>, with minimal chance of unintentionally activating the underlying component.
        */
  interactiveAreaSize!: 'Normal' | 'Large';
  /**
        Defines how the text of a component will be displayed when there is not enough space.

**Note:** By default the text will wrap. If "None" is set - the text will truncate.
        */
  wrappingType!: 'None' | 'Normal';
  /**
        Defines the accessible ARIA name of the component.
        */
  accessibleName!: string | undefined;
  /**
        Receives id(or many ids) of the elements that label the input
        */
  accessibleNameRef!: string | undefined;
  /**
        Defines the ARIA role of the component.

**Note:** Use the <code>LinkAccessibleRole.Button</code> role in cases when navigation is not expected to occur and the href property is not defined.
        */
  accessibleRole!: 'Link' | 'Button';
  /**
        Defines the additional accessibility attributes that will be applied to the component.
The following fields are supported:

- **expanded**: Indicates whether the button, or another grouping element it controls, is currently expanded or collapsed.
Accepts the following string values: `true` or `false`.

- **hasPopup**: Indicates the availability and type of interactive popup element, such as menu or dialog, that can be triggered by the button.
Accepts the following string values: `dialog`, `grid`, `listbox`, `menu` or `tree`.
        */
  accessibilityAttributes!: LinkAccessibilityAttributes;
  /**
        Defines the accessible description of the component.
        */
  accessibleDescription!: string | undefined;
  /**
        Defines the icon, displayed as graphical element within the component before the link's text.
The SAP-icons font provides numerous options.

**Note:** Usage of icon-only link is not supported, the link must always have a text.

**Note:** We recommend using аn icon in the beginning or the end only, and with text.

See all the available icons within the [Icon Explorer](https://sdk.openui5.org/test-resources/sap/m/demokit/iconExplorer/webapp/index.html).
        */
  icon!: string | undefined;
  /**
        Defines the icon, displayed as graphical element within the component after the link's text.
The SAP-icons font provides numerous options.

**Note:** Usage of icon-only link is not supported, the link must always have a text.

**Note:** We recommend using аn icon in the beginning or the end only, and with text.

See all the available icons within the [Icon Explorer](https://sdk.openui5.org/test-resources/sap/m/demokit/iconExplorer/webapp/index.html).
        */
  endIcon!: string | undefined;

  /**
     Fired when the component is triggered either with a mouse/tap
or by using the Enter key.
    */
  ui5Click!: EventEmitter<LinkClickEventDetail>;

  private elementRef: ElementRef<Link> = inject(ElementRef);
  private zone = inject(NgZone);
  private cdr = inject(ChangeDetectorRef);

  get element(): Link {
    return this.elementRef.nativeElement;
  }

  constructor() {
    this.cdr.detach();
  }
}
export { LinkComponent };
