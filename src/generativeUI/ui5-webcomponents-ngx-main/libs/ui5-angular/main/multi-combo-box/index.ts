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
import { GenericControlValueAccessor } from '@ui5/webcomponents-ngx/generic-cva';
import { ProxyInputs, ProxyOutputs } from '@ui5/webcomponents-ngx/utils';
import '@ui5/webcomponents/dist/MultiComboBox.js';
import {
  default as MultiComboBox,
  MultiComboBoxSelectionChangeEventDetail,
} from '@ui5/webcomponents/dist/MultiComboBox.js';
@ProxyInputs([
  'value',
  'name',
  'noTypeahead',
  'placeholder',
  'noValidation',
  'disabled',
  'valueState',
  'readonly',
  'required',
  'filter',
  'showClearIcon',
  'accessibleName',
  'accessibleNameRef',
  'showSelectAll',
  'open',
])
@ProxyOutputs([
  'change: ui5Change',
  'input: ui5Input',
  'open: ui5Open',
  'close: ui5Close',
  'selection-change: ui5SelectionChange',
])
@Component({
  standalone: true,
  selector: 'ui5-multi-combobox',
  template: '<ng-content></ng-content>',
  inputs: [
    'value',
    'name',
    'noTypeahead',
    'placeholder',
    'noValidation',
    'disabled',
    'valueState',
    'readonly',
    'required',
    'filter',
    'showClearIcon',
    'accessibleName',
    'accessibleNameRef',
    'showSelectAll',
    'open',
  ],
  outputs: [
    'ui5Change',
    'ui5Input',
    'ui5Open',
    'ui5Close',
    'ui5SelectionChange',
  ],
  exportAs: 'ui5MultiCombobox',
  hostDirectives: [GenericControlValueAccessor],
  host: {
    '(change)': '_cva?.onChange?.(cvaValue);',
    '(input)': '_cva?.onChange?.(cvaValue);',
  },
})
class MultiComboBoxComponent {
  /**
        Defines the value of the component.

**Note:** The property is updated upon typing.
        */
  value!: string;
  /**
        Determines the name by which the component will be identified upon submission in an HTML form.

**Note:** This property is only applicable within the context of an HTML Form element.
**Note:** When the component is used inside a form element,
the value is sent as the first element in the form data, even if it's empty.
        */
  name!: string | undefined;
  /**
        Defines whether the value will be autcompleted to match an item
        */
  @InputDecorator({ transform: booleanAttribute })
  noTypeahead!: boolean;
  /**
        Defines a short hint intended to aid the user with data entry when the
component has no value.
        */
  placeholder!: string | undefined;
  /**
        Defines if the user input will be prevented, if no matching item has been found
        */
  @InputDecorator({ transform: booleanAttribute })
  noValidation!: boolean;
  /**
        Defines whether the component is in disabled state.

**Note:** A disabled component is completely noninteractive.
        */
  @InputDecorator({ transform: booleanAttribute })
  disabled!: boolean;
  /**
        Defines the value state of the component.
        */
  valueState!: 'None' | 'Positive' | 'Critical' | 'Negative' | 'Information';
  /**
        Defines whether the component is read-only.

**Note:** A read-only component is not editable,
but still provides visual feedback upon user interaction.
        */
  @InputDecorator({ transform: booleanAttribute })
  readonly!: boolean;
  /**
        Defines whether the component is required.
        */
  @InputDecorator({ transform: booleanAttribute })
  required!: boolean;
  /**
        Defines the filter type of the component.
        */
  filter!: 'StartsWithPerTerm' | 'StartsWith' | 'Contains' | 'None';
  /**
        Defines whether the clear icon of the multi-combobox will be shown.
        */
  @InputDecorator({ transform: booleanAttribute })
  showClearIcon!: boolean;
  /**
        Defines the accessible ARIA name of the component.
        */
  accessibleName!: string | undefined;
  /**
        Receives id(or many ids) of the elements that label the component.
        */
  accessibleNameRef!: string | undefined;
  /**
        Determines if the select all checkbox is visible on top of suggestions.
        */
  @InputDecorator({ transform: booleanAttribute })
  showSelectAll!: boolean;
  /**
        Indicates whether the items picker is open.
        */
  @InputDecorator({ transform: booleanAttribute })
  open!: boolean;

  /**
     Fired when the input operation has finished by pressing Enter or on focusout.
    */
  ui5Change!: EventEmitter<void>;
  /**
     Fired when the value of the component changes at each keystroke or clear icon is pressed.
    */
  ui5Input!: EventEmitter<void>;
  /**
     Fired when the dropdown is opened.
    */
  ui5Open!: EventEmitter<void>;
  /**
     Fired when the dropdown is closed.
    */
  ui5Close!: EventEmitter<void>;
  /**
     Fired when selection is changed by user interaction.
    */
  ui5SelectionChange!: EventEmitter<MultiComboBoxSelectionChangeEventDetail>;

  private elementRef: ElementRef<MultiComboBox> = inject(ElementRef);
  private zone = inject(NgZone);
  private cdr = inject(ChangeDetectorRef);
  protected _cva = inject(GenericControlValueAccessor);

  get element(): MultiComboBox {
    return this.elementRef.nativeElement;
  }

  set cvaValue(val) {
    this.element.value = val;
    this.cdr.detectChanges();
  }
  get cvaValue() {
    return this.element.value;
  }

  constructor() {
    this.cdr.detach();
    this._cva.host = this;
  }
}
export { MultiComboBoxComponent };
