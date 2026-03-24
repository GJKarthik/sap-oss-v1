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
import '@ui5/webcomponents/dist/Select.js';
import {
  default as Select,
  SelectChangeEventDetail,
  SelectLiveChangeEventDetail,
} from '@ui5/webcomponents/dist/Select.js';
@ProxyInputs([
  'disabled',
  'name',
  'valueState',
  'required',
  'readonly',
  'accessibleName',
  'accessibleNameRef',
  'accessibleDescription',
  'accessibleDescriptionRef',
  'tooltip',
  'textSeparator',
  'value',
])
@ProxyOutputs([
  'change: ui5Change',
  'live-change: ui5LiveChange',
  'open: ui5Open',
  'close: ui5Close',
])
@Component({
  standalone: true,
  selector: 'ui5-select',
  template: '<ng-content></ng-content>',
  inputs: [
    'disabled',
    'name',
    'valueState',
    'required',
    'readonly',
    'accessibleName',
    'accessibleNameRef',
    'accessibleDescription',
    'accessibleDescriptionRef',
    'tooltip',
    'textSeparator',
    'value',
  ],
  outputs: ['ui5Change', 'ui5LiveChange', 'ui5Open', 'ui5Close'],
  exportAs: 'ui5Select',
  hostDirectives: [GenericControlValueAccessor],
  host: { '(change)': '_cva?.onChange?.(cvaValue);' },
})
class SelectComponent {
  /**
        Defines whether the component is in disabled state.

**Note:** A disabled component is noninteractive.
        */
  @InputDecorator({ transform: booleanAttribute })
  disabled!: boolean;
  /**
        Determines the name by which the component will be identified upon submission in an HTML form.

**Note:** This property is only applicable within the context of an HTML Form element.
        */
  name!: string | undefined;
  /**
        Defines the value state of the component.
        */
  valueState!: 'None' | 'Positive' | 'Critical' | 'Negative' | 'Information';
  /**
        Defines whether the component is required.
        */
  @InputDecorator({ transform: booleanAttribute })
  required!: boolean;
  /**
        Defines whether the component is read-only.

**Note:** A read-only component is not editable,
but still provides visual feedback upon user interaction.
        */
  @InputDecorator({ transform: booleanAttribute })
  readonly!: boolean;
  /**
        Defines the accessible ARIA name of the component.
        */
  accessibleName!: string | undefined;
  /**
        Receives id(or many ids) of the elements that label the select.
        */
  accessibleNameRef!: string | undefined;
  /**
        Defines the accessible description of the component.
        */
  accessibleDescription!: string | undefined;
  /**
        Receives id(or many ids) of the elements that describe the select.
        */
  accessibleDescriptionRef!: string | undefined;
  /**
        Defines the tooltip of the select.
        */
  tooltip!: string | undefined;
  /**
        Defines the separator type for the two columns layout when Select is in read-only mode.
        */
  textSeparator!: 'Bullet' | 'Dash' | 'VerticalLine';
  /**
        Defines the value of the component:

- when get - returns the value of the component or the value/text content of the selected option.
- when set - selects the option with matching `value` property or text content.

**Note:** Use either the Select's value or the Options' selected property.
Mixed usage could result in unexpected behavior.

**Note:** If the given value does not match any existing option,
no option will be selected and the Select component will be displayed as empty.
        */
  value!: string;

  /**
     Fired when the selected option changes.
    */
  ui5Change!: EventEmitter<SelectChangeEventDetail>;
  /**
     Fired when the user navigates through the options, but the selection is not finalized,
or when pressing the ESC key to revert the current selection.
    */
  ui5LiveChange!: EventEmitter<SelectLiveChangeEventDetail>;
  /**
     Fired after the component's dropdown menu opens.
    */
  ui5Open!: EventEmitter<void>;
  /**
     Fired after the component's dropdown menu closes.
    */
  ui5Close!: EventEmitter<void>;

  private elementRef: ElementRef<Select> = inject(ElementRef);
  private zone = inject(NgZone);
  private cdr = inject(ChangeDetectorRef);
  protected _cva = inject(GenericControlValueAccessor);

  get element(): Select {
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
export { SelectComponent };
