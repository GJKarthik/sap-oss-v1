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
import '@ui5/webcomponents/dist/Icon.js';
import Icon from '@ui5/webcomponents/dist/Icon.js';
@ProxyInputs(['design', 'name', 'accessibleName', 'showTooltip', 'mode'])
@ProxyOutputs(['click: ui5Click'])
@Component({
  standalone: true,
  selector: 'ui5-icon',
  template: '<ng-content></ng-content>',
  inputs: ['design', 'name', 'accessibleName', 'showTooltip', 'mode'],
  outputs: ['ui5Click'],
  exportAs: 'ui5Icon',
})
class IconComponent {
  /**
        Defines the component semantic design.
        */
  design!:
    | 'Contrast'
    | 'Critical'
    | 'Default'
    | 'Information'
    | 'Negative'
    | 'Neutral'
    | 'NonInteractive'
    | 'Positive';
  /**
        Defines the unique identifier (icon name) of the component.

To browse all available icons, see the
[SAP Icons](https://sdk.openui5.org/test-resources/sap/m/demokit/iconExplorer/webapp/index.html),
[SAP Fiori Tools](https://sdk.openui5.org/test-resources/sap/m/demokit/iconExplorer/webapp/index.html#/overview/SAP-icons-TNT) and
[SAP Business Suite](https://sdk.openui5.org/test-resources/sap/m/demokit/iconExplorer/webapp/index.html)

Example:
`name='add'`, `name='delete'`, `name='employee'`.

**Note:** To use the SAP Fiori Tools icons,
you need to set the `tnt` prefix in front of the icon's name.

Example:
`name='tnt/antenna'`, `name='tnt/actor'`, `name='tnt/api'`.

**Note:** To use the SAP Business Suite icons,
you need to set the `business-suite` prefix in front of the icon's name.

Example:
`name='business-suite/3d'`, `name='business-suite/1x2-grid-layout'`, `name='business-suite/4x4-grid-layout'`.
        */
  name!: string | undefined;
  /**
        Defines the text alternative of the component.
If not provided a default text alternative will be set, if present.

**Note:** Every icon should have a text alternative in order to
calculate its accessible name.
        */
  accessibleName!: string | undefined;
  /**
        Defines whether the component should have a tooltip.

**Note:** The tooltip text should be provided via the `accessible-name` property.
        */
  @InputDecorator({ transform: booleanAttribute })
  showTooltip!: boolean;
  /**
        Defines the mode of the component.
        */
  mode!: 'Image' | 'Decorative' | 'Interactive';

  /**
     Fired on mouseup, `SPACE` and `ENTER`.
- on mouse click, the icon fires native `click` event
- on `SPACE` and `ENTER`, the icon fires custom `click` event
    */
  ui5Click!: EventEmitter<void>;

  private elementRef: ElementRef<Icon> = inject(ElementRef);
  private zone = inject(NgZone);
  private cdr = inject(ChangeDetectorRef);

  get element(): Icon {
    return this.elementRef.nativeElement;
  }

  constructor() {
    this.cdr.detach();
  }
}
export { IconComponent };
