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
import '@ui5/webcomponents/dist/ToolbarSelect.js';
import {
  default as ToolbarSelect,
  ToolbarSelectChangeEventDetail,
} from '@ui5/webcomponents/dist/ToolbarSelect.js';
@ProxyInputs([
  'overflowPriority',
  'preventOverflowClosing',
  'width',
  'valueState',
  'disabled',
  'accessibleName',
  'accessibleNameRef',
  'value',
])
@ProxyOutputs(['change: ui5Change', 'open: ui5Open', 'close: ui5Close'])
@Component({
  standalone: true,
  selector: 'ui5-toolbar-select',
  template: '<ng-content></ng-content>',
  inputs: [
    'overflowPriority',
    'preventOverflowClosing',
    'width',
    'valueState',
    'disabled',
    'accessibleName',
    'accessibleNameRef',
    'value',
  ],
  outputs: ['ui5Change', 'ui5Open', 'ui5Close'],
  exportAs: 'ui5ToolbarSelect',
})
class ToolbarSelectComponent {
  /**
        Property used to define the access of the item to the overflow Popover. If "NeverOverflow" option is set,
the item never goes in the Popover, if "AlwaysOverflow" - it never comes out of it.
        */
  overflowPriority!: 'Default' | 'NeverOverflow' | 'AlwaysOverflow';
  /**
        Defines if the toolbar overflow popup should close upon intereaction with the item.
It will close by default.
        */
  @InputDecorator({ transform: booleanAttribute })
  preventOverflowClosing!: boolean;
  /**
        Defines the width of the select.

**Note:** all CSS sizes are supported - 'percentage', 'px', 'rem', 'auto', etc.
        */
  width!: string | undefined;
  /**
        Defines the value state of the component.
        */
  valueState!: 'None' | 'Positive' | 'Critical' | 'Negative' | 'Information';
  /**
        Defines whether the component is in disabled state.

**Note:** A disabled component is noninteractive.
        */
  @InputDecorator({ transform: booleanAttribute })
  disabled!: boolean;
  /**
        Defines the accessible ARIA name of the component.
        */
  accessibleName!: string | undefined;
  /**
        Receives id(or many ids) of the elements that label the select.
        */
  accessibleNameRef!: string | undefined;
  /**
        Defines the value of the component:
        */
  value!: string | undefined;

  /**
     Fired when the selected option changes.
    */
  ui5Change!: EventEmitter<ToolbarSelectChangeEventDetail>;
  /**
     Fired after the component's dropdown menu opens.
    */
  ui5Open!: EventEmitter<void>;
  /**
     Fired after the component's dropdown menu closes.
    */
  ui5Close!: EventEmitter<void>;

  private elementRef: ElementRef<ToolbarSelect> = inject(ElementRef);
  private zone = inject(NgZone);
  private cdr = inject(ChangeDetectorRef);

  get element(): ToolbarSelect {
    return this.elementRef.nativeElement;
  }

  constructor() {
    this.cdr.detach();
  }
}
export { ToolbarSelectComponent };
