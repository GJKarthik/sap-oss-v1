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
import '@ui5/webcomponents/dist/CheckBox.js';
import CheckBox from '@ui5/webcomponents/dist/CheckBox.js';
@ProxyInputs([
  'accessibleNameRef',
  'accessibleName',
  'disabled',
  'readonly',
  'displayOnly',
  'required',
  'indeterminate',
  'checked',
  'text',
  'valueState',
  'wrappingType',
  'name',
  'value',
])
@ProxyOutputs(['change: ui5Change'])
@Component({
  standalone: true,
  selector: 'ui5-checkbox',
  template: '<ng-content></ng-content>',
  inputs: [
    'accessibleNameRef',
    'accessibleName',
    'disabled',
    'readonly',
    'displayOnly',
    'required',
    'indeterminate',
    'checked',
    'text',
    'valueState',
    'wrappingType',
    'name',
    'value',
  ],
  outputs: ['ui5Change'],
  exportAs: 'ui5Checkbox',
  hostDirectives: [GenericControlValueAccessor],
  host: { '(change)': '_cva?.onChange?.(cvaValue);' },
})
class CheckBoxComponent {
  /**
        Receives id(or many ids) of the elements that label the component
        */
  accessibleNameRef!: string | undefined;
  /**
        Defines the accessible ARIA name of the component.
        */
  accessibleName!: string | undefined;
  /**
        Defines whether the component is disabled.

**Note:** A disabled component is completely noninteractive.
        */
  @InputDecorator({ transform: booleanAttribute })
  disabled!: boolean;
  /**
        Defines whether the component is read-only.

**Note:** A read-only component is not editable,
but still provides visual feedback upon user interaction.
        */
  @InputDecorator({ transform: booleanAttribute })
  readonly!: boolean;
  /**
        Determines whether the `ui5-checkbox` is in display only state.

When set to `true`, the `ui5-checkbox` is not interactive, not editable, not focusable
and not in the tab chain. This setting is used for forms in review mode.

**Note:** When the property `disabled` is set to `true` this property has no effect.
        */
  @InputDecorator({ transform: booleanAttribute })
  displayOnly!: boolean;
  /**
        Defines whether the component is required.

**Note:** We advise against using the text property of the checkbox when there is a
label associated with it to avoid having two required asterisks.
        */
  @InputDecorator({ transform: booleanAttribute })
  required!: boolean;
  /**
        Defines whether the component is displayed as partially checked.

**Note:** The indeterminate state can be set only programmatically and can’t be achieved by user
interaction and the resulting visual state depends on the values of the `indeterminate`
and `checked` properties:

-  If the component is checked and indeterminate, it will be displayed as partially checked
-  If the component is checked and it is not indeterminate, it will be displayed as checked
-  If the component is not checked, it will be displayed as not checked regardless value of the indeterminate attribute
        */
  @InputDecorator({ transform: booleanAttribute })
  indeterminate!: boolean;
  /**
        Defines if the component is checked.

**Note:** The property can be changed with user interaction,
either by cliking/tapping on the component, or by
pressing the Enter or Space key.
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
        Defines whether the component text wraps when there is not enough space.

**Note:** for option "Normal" the text will wrap and the words will not be broken based on hyphenation.
**Note:** for option "None" the text will be truncated with an ellipsis.
        */
  wrappingType!: 'None' | 'Normal';
  /**
        Determines the name by which the component will be identified upon submission in an HTML form.

**Note:** This property is only applicable within the context of an HTML Form element.
        */
  name!: string | undefined;
  /**
        Defines the form value of the component that is submitted when the checkbox is checked.

When a form containing `ui5-checkbox` elements is submitted, only the values of the
**checked** checkboxes are included in the form data sent to the server. Unchecked
checkboxes do not contribute any data to the form submission.

This property is particularly useful for **checkbox groups**, where multiple checkboxes with the same `name` but different `value` properties can be used to represent a set of related options.
        */
  value!: string;

  /**
     Fired when the component checked state changes.
    */
  ui5Change!: EventEmitter<void>;

  private elementRef: ElementRef<CheckBox> = inject(ElementRef);
  private zone = inject(NgZone);
  private cdr = inject(ChangeDetectorRef);
  protected _cva = inject(GenericControlValueAccessor);

  get element(): CheckBox {
    return this.elementRef.nativeElement;
  }

  set cvaValue(val) {
    this.element.checked = val;
    this.cdr.detectChanges();
  }
  get cvaValue() {
    return this.element.checked;
  }

  constructor() {
    this.cdr.detach();
    this._cva.host = this;
  }
}
export { CheckBoxComponent };
