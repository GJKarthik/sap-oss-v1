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
import '@ui5/webcomponents-fiori/dist/FlexibleColumnLayout.js';
import {
  FCLAccessibilityAttributes,
  default as FlexibleColumnLayout,
  FlexibleColumnLayoutLayoutChangeEventDetail,
  FlexibleColumnLayoutLayoutConfigurationChangeEventDetail,
  LayoutConfiguration,
} from '@ui5/webcomponents-fiori/dist/FlexibleColumnLayout.js';
import { ProxyInputs, ProxyOutputs } from '@ui5/webcomponents-ngx/utils';
@ProxyInputs([
  'layout',
  'disableResizing',
  'accessibilityAttributes',
  'layoutsConfiguration',
])
@ProxyOutputs([
  'layout-change: ui5LayoutChange',
  'layout-configuration-change: ui5LayoutConfigurationChange',
])
@Component({
  standalone: true,
  selector: 'ui5-flexible-column-layout',
  template: '<ng-content></ng-content>',
  inputs: [
    'layout',
    'disableResizing',
    'accessibilityAttributes',
    'layoutsConfiguration',
  ],
  outputs: ['ui5LayoutChange', 'ui5LayoutConfigurationChange'],
  exportAs: 'ui5FlexibleColumnLayout',
})
class FlexibleColumnLayoutComponent {
  /**
        Defines the columns layout and their proportion.

**Note:** The layout also depends on the screen size - one column for screens smaller than 599px,
two columns between 599px and 1023px and three columns for sizes bigger than 1023px.

**For example:** layout=`TwoColumnsStartExpanded` means the layout will display up to two columns
in 67%/33% proportion.
        */
  layout!:
    | 'OneColumn'
    | 'TwoColumnsStartExpanded'
    | 'TwoColumnsMidExpanded'
    | 'ThreeColumnsMidExpanded'
    | 'ThreeColumnsEndExpanded'
    | 'ThreeColumnsStartExpandedEndHidden'
    | 'ThreeColumnsMidExpandedEndHidden'
    | 'ThreeColumnsStartHiddenMidExpanded'
    | 'ThreeColumnsStartHiddenEndExpanded'
    | 'MidColumnFullScreen'
    | 'EndColumnFullScreen';
  /**
        Specifies if the user is allowed to change the columns layout by dragging the separator between the columns.
        */
  @InputDecorator({ transform: booleanAttribute })
  disableResizing!: boolean;
  /**
        Defines additional accessibility attributes on different areas of the component.

The accessibilityAttributes object has the following fields,
where each field is an object supporting one or more accessibility attributes:

 - **startColumn**: `startColumn.role` and `startColumn.name`.
 - **midColumn**: `midColumn.role` and `midColumn.name`.
 - **endColumn**: `endColumn.role` and `endColumn.name`.
 - **startSeparator**: `startSeparator.role` and `startSeparator.name`.
 - **endSeparator**: `endSeparator.role` and `endSeparator.name`.

The accessibility attributes support the following values:

- **role**: Defines the accessible ARIA landmark role of the area.
Accepts the following values: `none`, `complementary`, `contentinfo`, `main` or `region`.

- **name**: Defines the accessible ARIA name of the area.
Accepts any string.
        */
  accessibilityAttributes!: FCLAccessibilityAttributes;
  /**
        Allows to customize the column proportions per screen size and layout.
If no custom proportion provided for a specific layout, the default will be used.

**Notes:**

- The proportions should be given in percentages. For example ["30%", "40%", "30%"], ["70%", "30%", 0], etc.
- The proportions should add up to 100%.
- Hidden columns are marked as "0px", e.g. ["0px", "70%", "30%"]. Specifying 0 or "0%" for hidden columns is also valid.
- If the proportions do not match the layout (e.g. if provided proportions ["70%", "30%", "0px"] for "OneColumn" layout), then the default proportions will be used instead.
- Whenever the user drags the columns separator to resize the columns, the `layoutsConfiguration` object will be updated with the user-specified proportions for the given layout (and the `layout-configuration-change` event will be fired).
- No custom configuration available for the phone screen size, as the default of 100% column width is always used there.
        */
  layoutsConfiguration!: LayoutConfiguration;

  /**
     Fired when the layout changes via user interaction by dragging the separators
or by changing the component size due to resizing.
    */
  ui5LayoutChange!: EventEmitter<FlexibleColumnLayoutLayoutChangeEventDetail>;
  /**
     Fired when the `layoutsConfiguration` changes via user interaction by dragging the separators.
    */
  ui5LayoutConfigurationChange!: EventEmitter<FlexibleColumnLayoutLayoutConfigurationChangeEventDetail>;

  private elementRef: ElementRef<FlexibleColumnLayout> = inject(ElementRef);
  private zone = inject(NgZone);
  private cdr = inject(ChangeDetectorRef);

  get element(): FlexibleColumnLayout {
    return this.elementRef.nativeElement;
  }

  constructor() {
    this.cdr.detach();
  }
}
export { FlexibleColumnLayoutComponent };
