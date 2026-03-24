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
import '@ui5/webcomponents/dist/ComboBox.js';
import {
  default as ComboBox,
  ComboBoxSelectionChangeEventDetail,
} from '@ui5/webcomponents/dist/ComboBox.js';
@ProxyInputs([
  'value',
  'name',
  'noTypeahead',
  'placeholder',
  'disabled',
  'valueState',
  'readonly',
  'required',
  'loading',
  'filter',
  'showClearIcon',
  'accessibleName',
  'accessibleNameRef',
  'open',
])
@ProxyOutputs([
  'change: ui5Change',
  'open: ui5Open',
  'close: ui5Close',
  'input: ui5Input',
  'selection-change: ui5SelectionChange',
])
@Component({
  standalone: true,
  selector: 'ui5-combobox',
  template: '<ng-content></ng-content>',
  inputs: [
    'value',
    'name',
    'noTypeahead',
    'placeholder',
    'disabled',
    'valueState',
    'readonly',
    'required',
    'loading',
    'filter',
    'showClearIcon',
    'accessibleName',
    'accessibleNameRef',
    'open',
  ],
  outputs: [
    'ui5Change',
    'ui5Open',
    'ui5Close',
    'ui5Input',
    'ui5SelectionChange',
  ],
  exportAs: 'ui5Combobox',
  hostDirectives: [GenericControlValueAccessor],
  host: {
    '(change)': '_cva?.onChange?.(cvaValue);',
    '(input)': '_cva?.onChange?.(cvaValue);',
  },
})
class ComboBoxComponent {
  /**
        Defines the value of the component.
        */
  value!: string;
  /**
        Determines the name by which the component will be identified upon submission in an HTML form.

**Note:** This property is only applicable within the context of an HTML Form element.
        */
  name!: string | undefined;
  /**
        Defines whether the value will be autocompleted to match an item
        */
  @InputDecorator({ transform: booleanAttribute })
  noTypeahead!: boolean;
  /**
        Defines a short hint intended to aid the user with data entry when the
component has no value.
        */
  placeholder!: string | undefined;
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
        Indicates whether a loading indicator should be shown in the picker.
        */
  @InputDecorator({ transform: booleanAttribute })
  loading!: boolean;
  /**
        Defines the filter type of the component.
        */
  filter!: 'StartsWithPerTerm' | 'StartsWith' | 'Contains' | 'None';
  /**
        Defines whether the clear icon of the combobox will be shown.
        */
  @InputDecorator({ transform: booleanAttribute })
  showClearIcon!: boolean;
  /**
        Defines the accessible ARIA name of the component.
        */
  accessibleName!: string | undefined;
  /**
        Receives id(or many ids) of the elements that label the component
        */
  accessibleNameRef!: string | undefined;
  /**
        Indicates whether the items picker is open.
        */
  @InputDecorator({ transform: booleanAttribute })
  open!: boolean;

  /**
     Fired when the input operation has finished by pressing Enter, focusout or an item is selected.
    */
  ui5Change!: EventEmitter<void>;
  /**
     Fired when the dropdown is opened.
    */
  ui5Open!: EventEmitter<void>;
  /**
     Fired when the dropdown is closed.
    */
  ui5Close!: EventEmitter<void>;
  /**
     Fired when typing in input or clear icon is pressed.

**Note:** filterValue property is updated, input is changed.
    */
  ui5Input!: EventEmitter<void>;
  /**
     Fired when selection is changed by user interaction
    */
  ui5SelectionChange!: EventEmitter<ComboBoxSelectionChangeEventDetail>;

  private elementRef: ElementRef<ComboBox> = inject(ElementRef);
  private zone = inject(NgZone);
  private cdr = inject(ChangeDetectorRef);
  protected _cva = inject(GenericControlValueAccessor);

  get element(): ComboBox {
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
export { ComboBoxComponent };
