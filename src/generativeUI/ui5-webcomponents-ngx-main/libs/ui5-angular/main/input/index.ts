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
import '@ui5/webcomponents/dist/Input.js';
import {
  default as Input,
  InputSelectionChangeEventDetail,
} from '@ui5/webcomponents/dist/Input.js';
@ProxyInputs([
  'disabled',
  'placeholder',
  'readonly',
  'required',
  'noTypeahead',
  'type',
  'value',
  'valueState',
  'name',
  'showSuggestions',
  'maxlength',
  'accessibleName',
  'accessibleNameRef',
  'accessibleDescription',
  'accessibleDescriptionRef',
  'showClearIcon',
  'open',
])
@ProxyOutputs([
  'change: ui5Change',
  'input: ui5Input',
  'select: ui5Select',
  'selection-change: ui5SelectionChange',
  'open: ui5Open',
  'close: ui5Close',
])
@Component({
  standalone: true,
  selector: 'ui5-input',
  template: '<ng-content></ng-content>',
  inputs: [
    'disabled',
    'placeholder',
    'readonly',
    'required',
    'noTypeahead',
    'type',
    'value',
    'valueState',
    'name',
    'showSuggestions',
    'maxlength',
    'accessibleName',
    'accessibleNameRef',
    'accessibleDescription',
    'accessibleDescriptionRef',
    'showClearIcon',
    'open',
  ],
  outputs: [
    'ui5Change',
    'ui5Input',
    'ui5Select',
    'ui5SelectionChange',
    'ui5Open',
    'ui5Close',
  ],
  exportAs: 'ui5Input',
  hostDirectives: [GenericControlValueAccessor],
  host: {
    '(change)': '_cva?.onChange?.(cvaValue);',
    '(input)': '_cva?.onChange?.(cvaValue);',
  },
})
class InputComponent {
  /**
        Defines whether the component is in disabled state.

**Note:** A disabled component is completely noninteractive.
        */
  @InputDecorator({ transform: booleanAttribute })
  disabled!: boolean;
  /**
        Defines a short hint intended to aid the user with data entry when the
component has no value.
        */
  placeholder!: string | undefined;
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
        Defines whether the value will be autcompleted to match an item
        */
  @InputDecorator({ transform: booleanAttribute })
  noTypeahead!: boolean;
  /**
        Defines the HTML type of the component.

**Notes:**

- The particular effect of this property differs depending on the browser
and the current language settings, especially for type `Number`.
- The property is mostly intended to be used with touch devices
that use different soft keyboard layouts depending on the given input type.
        */
  type!: 'Text' | 'Email' | 'Number' | 'Password' | 'Tel' | 'URL' | 'Search';
  /**
        Defines the value of the component.

**Note:** The property is updated upon typing.
        */
  value!: string;
  /**
        Defines the value state of the component.
        */
  valueState!: 'None' | 'Positive' | 'Critical' | 'Negative' | 'Information';
  /**
        Determines the name by which the component will be identified upon submission in an HTML form.

**Note:** This property is only applicable within the context of an HTML Form element.
        */
  name!: string | undefined;
  /**
        Defines whether the component should show suggestions, if such are present.
        */
  @InputDecorator({ transform: booleanAttribute })
  showSuggestions!: boolean;
  /**
        Sets the maximum number of characters available in the input field.

**Note:** This property is not compatible with the ui5-input type InputType.Number. If the ui5-input type is set to Number, the maxlength value is ignored.
        */
  maxlength!: number | undefined;
  /**
        Defines the accessible ARIA name of the component.
        */
  accessibleName!: string | undefined;
  /**
        Receives id(or many ids) of the elements that label the input.
        */
  accessibleNameRef!: string | undefined;
  /**
        Defines the accessible description of the component.
        */
  accessibleDescription!: string | undefined;
  /**
        Receives id(or many ids) of the elements that describe the input.
        */
  accessibleDescriptionRef!: string | undefined;
  /**
        Defines whether the clear icon of the input will be shown.
        */
  @InputDecorator({ transform: booleanAttribute })
  showClearIcon!: boolean;
  /**
        Defines whether the suggestions picker is open.
The picker will not open if the `showSuggestions` property is set to `false`, the input is disabled or the input is readonly.
The picker will close automatically and `close` event will be fired if the input is not in the viewport.
        */
  @InputDecorator({ transform: booleanAttribute })
  open!: boolean;

  /**
     Fired when the input operation has finished by pressing Enter or on focusout.
    */
  ui5Change!: EventEmitter<void>;
  /**
     Fired when the value of the component changes at each keystroke,
and when a suggestion item has been selected.
    */
  ui5Input!: EventEmitter<void>;
  /**
     Fired when some text has been selected.
    */
  ui5Select!: EventEmitter<void>;
  /**
     Fired when the user navigates to a suggestion item via the ARROW keys,
as a preview, before the final selection.
    */
  ui5SelectionChange!: EventEmitter<InputSelectionChangeEventDetail>;
  /**
     Fired when the suggestions picker is open.
    */
  ui5Open!: EventEmitter<void>;
  /**
     Fired when the suggestions picker is closed.
    */
  ui5Close!: EventEmitter<void>;

  private elementRef: ElementRef<Input> = inject(ElementRef);
  private zone = inject(NgZone);
  private cdr = inject(ChangeDetectorRef);
  protected _cva = inject(GenericControlValueAccessor);

  get element(): Input {
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
export { InputComponent };
