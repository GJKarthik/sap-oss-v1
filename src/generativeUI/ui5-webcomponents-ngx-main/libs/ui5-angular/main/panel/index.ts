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
import '@ui5/webcomponents/dist/Panel.js';
import Panel from '@ui5/webcomponents/dist/Panel.js';
@ProxyInputs([
  'headerText',
  'fixed',
  'collapsed',
  'noAnimation',
  'accessibleRole',
  'headerLevel',
  'accessibleName',
  'stickyHeader',
])
@ProxyOutputs(['toggle: ui5Toggle'])
@Component({
  standalone: true,
  selector: 'ui5-panel',
  template: '<ng-content></ng-content>',
  inputs: [
    'headerText',
    'fixed',
    'collapsed',
    'noAnimation',
    'accessibleRole',
    'headerLevel',
    'accessibleName',
    'stickyHeader',
  ],
  outputs: ['ui5Toggle'],
  exportAs: 'ui5Panel',
})
class PanelComponent {
  /**
        This property is used to set the header text of the component.
The text is visible in both expanded and collapsed states.

**Note:** This property is overridden by the `header` slot.
        */
  headerText!: string | undefined;
  /**
        Determines whether the component is in a fixed state that is not
expandable/collapsible by user interaction.
        */
  @InputDecorator({ transform: booleanAttribute })
  fixed!: boolean;
  /**
        Indicates whether the component is collapsed and only the header is displayed.
        */
  @InputDecorator({ transform: booleanAttribute })
  collapsed!: boolean;
  /**
        Indicates whether the transition between the expanded and the collapsed state of the component is animated. By default the animation is enabled.
        */
  @InputDecorator({ transform: booleanAttribute })
  noAnimation!: boolean;
  /**
        Sets the accessible ARIA role of the component.
Depending on the usage, you can change the role from the default `Form`
to `Region` or `Complementary`.
        */
  accessibleRole!: 'Complementary' | 'Form' | 'Region';
  /**
        Defines the "aria-level" of component heading,
set by the `headerText`.
        */
  headerLevel!: 'H1' | 'H2' | 'H3' | 'H4' | 'H5' | 'H6';
  /**
        Defines the accessible ARIA name of the component.
        */
  accessibleName!: string | undefined;
  /**
        Indicates whether the Panel header is sticky or not.
If stickyHeader is set to true, then whenever you scroll the content or
the application, the header of the panel will be always visible and
a solid color will be used for its design.
        */
  @InputDecorator({ transform: booleanAttribute })
  stickyHeader!: boolean;

  /**
     Fired when the component is expanded/collapsed by user interaction.
    */
  ui5Toggle!: EventEmitter<void>;

  private elementRef: ElementRef<Panel> = inject(ElementRef);
  private zone = inject(NgZone);
  private cdr = inject(ChangeDetectorRef);

  get element(): Panel {
    return this.elementRef.nativeElement;
  }

  constructor() {
    this.cdr.detach();
  }
}
export { PanelComponent };
