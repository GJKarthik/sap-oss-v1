import {
  ChangeDetectorRef,
  Component,
  ElementRef,
  Input as InputDecorator,
  NgZone,
  booleanAttribute,
  inject,
} from '@angular/core';
import { ProxyInputs } from '@ui5/webcomponents-ngx/utils';
import '@ui5/webcomponents/dist/Tab.js';
import Tab from '@ui5/webcomponents/dist/Tab.js';
@ProxyInputs([
  'text',
  'disabled',
  'additionalText',
  'icon',
  'design',
  'selected',
  'movable',
])
@Component({
  standalone: true,
  selector: 'ui5-tab',
  template: '<ng-content></ng-content>',
  inputs: [
    'text',
    'disabled',
    'additionalText',
    'icon',
    'design',
    'selected',
    'movable',
  ],
  exportAs: 'ui5Tab',
})
class TabComponent {
  /**
        The text to be displayed for the item.
        */
  text!: string | undefined;
  /**
        Disabled tabs can't be selected.
        */
  @InputDecorator({ transform: booleanAttribute })
  disabled!: boolean;
  /**
        Represents the "additionalText" text, which is displayed in the tab. In the cases when in the same time there are tabs with icons and tabs without icons, if a tab has no icon the "additionalText" is displayed larger.
        */
  additionalText!: string | undefined;
  /**
        Defines the icon source URI to be displayed as graphical element within the component.
The SAP-icons font provides numerous built-in icons.
See all the available icons in the [Icon Explorer](https://sdk.openui5.org/test-resources/sap/m/demokit/iconExplorer/webapp/index.html).
        */
  icon!: string | undefined;
  /**
        Defines the component's design color.

The design is applied to:

- the component icon
- the `text` when the component overflows
- the tab selection line

Available designs are: `"Default"`, `"Neutral"`, `"Positive"`, `"Critical"` and `"Negative"`.

**Note:** The design depends on the current theme.
        */
  design!: 'Default' | 'Positive' | 'Negative' | 'Critical' | 'Neutral';
  /**
        Specifies if the component is selected.
        */
  @InputDecorator({ transform: booleanAttribute })
  selected!: boolean;
  /**
        Defines if the tab is movable.
        */
  @InputDecorator({ transform: booleanAttribute })
  movable!: boolean;

  private elementRef: ElementRef<Tab> = inject(ElementRef);
  private zone = inject(NgZone);
  private cdr = inject(ChangeDetectorRef);

  get element(): Tab {
    return this.elementRef.nativeElement;
  }

  constructor() {
    this.cdr.detach();
  }
}
export { TabComponent };
