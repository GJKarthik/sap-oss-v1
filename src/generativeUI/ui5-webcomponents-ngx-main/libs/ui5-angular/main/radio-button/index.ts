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
import '@ui5/webcomponents/dist/RadioButton.js';
import RadioButton from '@ui5/webcomponents/dist/RadioButton.js';
@ProxyInputs([
  'disabled',
  'readonly',
  'required',
  'checked',
  'text',
  'valueState',
  'name',
  'value',
  'wrappingType',
  'accessibleName',
  'accessibleNameRef',
])
@ProxyOutputs(['change: ui5Change'])
@Component({
  standalone: true,
  selector: 'ui5-radio-button',
  template: '<ng-content></ng-content>',
  inputs: [
    'disabled',
    'readonly',
    'required',
    'checked',
    'text',
    'valueState',
    'name',
    'value',
    'wrappingType',
    'accessibleName',
    'accessibleNameRef',
  ],
  outputs: ['ui5Change'],
  exportAs: 'ui5RadioButton',
  hostDirectives: [GenericControlValueAccessor],
  host: { '(change)': '_cva?.onChange?.(cvaValue);' },
})
class RadioButtonComponent {
  /**
        Defines whether the component is disabled.

**Note:** A disabled component is completely noninteractive.
        */
  @InputDecorator({ transform: booleanAttribute })
  disabled!: boolean;
  /**
        Defines whether the component is read-only.

**Note:** A read-only component isn't editable or selectable.
However, because it's focusable, it still provides visual feedback upon user interaction.
        */
  @InputDecorator({ transform: booleanAttribute })
  readonly!: boolean;
  /**
        Defines whether the component is required.
        */
  @InputDecorator({ transform: booleanAttribute })
  required!: boolean;
  /**
        Defines whether the component is checked or not.

**Note:** The property value can be changed with user interaction,
either by clicking/tapping on the component,
or by using the Space or Enter key.

**Note:** Only enabled radio buttons can be checked.
Read-only radio buttons are not selectable, and therefore are always unchecked.
        */
  @InputDecorator({ transform: booleanAttribute })
  checked!: boolean;
  /**
        Defines the text of the component.
        */
  text!: string | undefined;
  /**
        Defines the value state of the component.
        */
  valueState!: 'None' | 'Positive' | 'Critical' | 'Negative' | 'Information';
  /**
        Determines the name by which the component will be identified upon submission in an HTML form.

Radio buttons with the same `name` will form a radio button group.

**Note:** By this name the component will be identified upon submission in an HTML form.

**Note:** The selection can be changed with `ARROW_UP/DOWN` and `ARROW_LEFT/RIGHT` keys between radio buttons in same group.

**Note:** Only one radio button can be selected per group.
        */
  name!: string | undefined;
  /**
        Defines the form value of the component.
When a form with a radio button group is submitted, the group's value
will be the value of the currently selected radio button.
        */
  value!: string;
  /**
        Defines whether the component text wraps when there is not enough space.

**Note:** for option "Normal" the text will wrap and the words will not be broken based on hyphenation.
        */
  wrappingType!: 'None' | 'Normal';
  /**
        Defines the accessible ARIA name of the component.
        */
  accessibleName!: string | undefined;
  /**
        Defines the IDs of the elements that label the component.
        */
  accessibleNameRef!: string | undefined;

  /**
     Fired when the component checked state changes.
    */
  ui5Change!: EventEmitter<void>;

  private elementRef: ElementRef<RadioButton> = inject(ElementRef);
  private zone = inject(NgZone);
  private cdr = inject(ChangeDetectorRef);
  protected _cva = inject(GenericControlValueAccessor);

  get element(): RadioButton {
    return this.elementRef.nativeElement;
  }

  set cvaValue(val: string) {
    this.element.checked = this.element.value === val;
  }
  get cvaValue() {
    return this.element.value;
  }

  constructor() {
    this.cdr.detach();
    this._cva.host = this;
  }
}
export { RadioButtonComponent };
