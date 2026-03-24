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
import '@ui5/webcomponents/dist/TextArea.js';
import {
  default as TextArea,
  TextAreaInputEventDetail,
} from '@ui5/webcomponents/dist/TextArea.js';
@ProxyInputs([
  'value',
  'disabled',
  'readonly',
  'required',
  'placeholder',
  'valueState',
  'rows',
  'maxlength',
  'showExceededText',
  'growing',
  'growingMaxRows',
  'name',
  'accessibleName',
  'accessibleNameRef',
  'accessibleDescription',
  'accessibleDescriptionRef',
])
@ProxyOutputs([
  'change: ui5Change',
  'input: ui5Input',
  'select: ui5Select',
  'scroll: ui5Scroll',
])
@Component({
  standalone: true,
  selector: 'ui5-textarea',
  template: '<ng-content></ng-content>',
  inputs: [
    'value',
    'disabled',
    'readonly',
    'required',
    'placeholder',
    'valueState',
    'rows',
    'maxlength',
    'showExceededText',
    'growing',
    'growingMaxRows',
    'name',
    'accessibleName',
    'accessibleNameRef',
    'accessibleDescription',
    'accessibleDescriptionRef',
  ],
  outputs: ['ui5Change', 'ui5Input', 'ui5Select', 'ui5Scroll'],
  exportAs: 'ui5Textarea',
  hostDirectives: [GenericControlValueAccessor],
  host: {
    '(change)': '_cva?.onChange?.(cvaValue);',
    '(input)': '_cva?.onChange?.(cvaValue);',
  },
})
class TextAreaComponent {
  /**
        Defines the value of the component.
        */
  value!: string;
  /**
        Indicates whether the user can interact with the component or not.

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
        Defines whether the component is required.
        */
  @InputDecorator({ transform: booleanAttribute })
  required!: boolean;
  /**
        Defines a short hint intended to aid the user with data entry when the component has no value.
        */
  placeholder!: string | undefined;
  /**
        Defines the value state of the component.

**Note:** If `maxlength` property is set,
the component turns into "Critical" state once the characters exceeds the limit.
In this case, only the "Negative" state is considered and can be applied.
        */
  valueState!: 'None' | 'Positive' | 'Critical' | 'Negative' | 'Information';
  /**
        Defines the number of visible text rows for the component.

**Notes:**

- If the `growing` property is enabled, this property defines the minimum rows to be displayed
in the textarea.
- The CSS `height` property wins over the `rows` property, if both are set.
        */
  rows!: number;
  /**
        Defines the maximum number of characters that the `value` can have.
        */
  maxlength!: number | undefined;
  /**
        Determines whether the characters exceeding the maximum allowed character count are visible
in the component.

If set to `false`, the user is not allowed to enter more characters than what is set in the
`maxlength` property.
If set to `true` the characters exceeding the `maxlength` value are selected on
paste and the counter below the component displays their number.
        */
  @InputDecorator({ transform: booleanAttribute })
  showExceededText!: boolean;
  /**
        Enables the component to automatically grow and shrink dynamically with its content.
        */
  @InputDecorator({ transform: booleanAttribute })
  growing!: boolean;
  /**
        Defines the maximum number of rows that the component can grow.
        */
  growingMaxRows!: number;
  /**
        Determines the name by which the component will be identified upon submission in an HTML form.

**Note:** This property is only applicable within the context of an HTML Form element.
        */
  name!: string | undefined;
  /**
        Defines the accessible ARIA name of the component.
        */
  accessibleName!: string | undefined;
  /**
        Receives id(or many ids) of the elements that label the textarea.
        */
  accessibleNameRef!: string | undefined;
  /**
        Defines the accessible description of the component.
        */
  accessibleDescription!: string | undefined;
  /**
        Receives id(or many ids) of the elements that describe the textarea.
        */
  accessibleDescriptionRef!: string | undefined;

  /**
     Fired when the text has changed and the focus leaves the component.
    */
  ui5Change!: EventEmitter<void>;
  /**
     Fired when the value of the component changes at each keystroke or when
something is pasted.
    */
  ui5Input!: EventEmitter<TextAreaInputEventDetail>;
  /**
     Fired when some text has been selected.
    */
  ui5Select!: EventEmitter<void>;
  /**
     Fired when textarea is scrolled.
    */
  ui5Scroll!: EventEmitter<void>;

  private elementRef: ElementRef<TextArea> = inject(ElementRef);
  private zone = inject(NgZone);
  private cdr = inject(ChangeDetectorRef);
  protected _cva = inject(GenericControlValueAccessor);

  get element(): TextArea {
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
export { TextAreaComponent };
