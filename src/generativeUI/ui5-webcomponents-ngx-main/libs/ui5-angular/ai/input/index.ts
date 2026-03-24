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
import '@ui5/webcomponents-ai/dist/Input.js';
import {
  default as Input,
  InputItemClickEventDetail,
  InputVersionChangeEventDetail,
} from '@ui5/webcomponents-ai/dist/Input.js';
import { GenericControlValueAccessor } from '@ui5/webcomponents-ngx/generic-cva';
import { ProxyInputs, ProxyOutputs } from '@ui5/webcomponents-ngx/utils';
import { InputSelectionChangeEventDetail } from '@ui5/webcomponents/dist/Input.js';
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
  'currentVersion',
  'totalVersions',
  'loading',
])
@ProxyOutputs([
  'change: ui5Change',
  'input: ui5Input',
  'select: ui5Select',
  'selection-change: ui5SelectionChange',
  'open: ui5Open',
  'close: ui5Close',
  'button-click: ui5ButtonClick',
  'item-click: ui5ItemClick',
  'stop-generation: ui5StopGeneration',
  'version-change: ui5VersionChange',
])
@Component({
  standalone: true,
  selector: 'ui5-ai-input',
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
    'currentVersion',
    'totalVersions',
    'loading',
  ],
  outputs: [
    'ui5Change',
    'ui5Input',
    'ui5Select',
    'ui5SelectionChange',
    'ui5Open',
    'ui5Close',
    'ui5ButtonClick',
    'ui5ItemClick',
    'ui5StopGeneration',
    'ui5VersionChange',
  ],
  exportAs: 'ui5AiInput',
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
        Indicates the index of the currently displayed version.
        */
  currentVersion!: number;
  /**
        Indicates the total number of result versions available.

When not set or set to 0, the versioning will be hidden.
        */
  totalVersions!: number;
  /**
        Defines whether the AI Writing Assistant is currently loading.

When `true`, indicates that an AI action is in progress.
        */
  @InputDecorator({ transform: booleanAttribute })
  loading!: boolean;

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
  /**
     Fired when the user selects the AI button.
    */
  ui5ButtonClick!: EventEmitter<void>;
  /**
     Fired when an item from the AI actions menu is clicked.
    */
  ui5ItemClick!: EventEmitter<InputItemClickEventDetail>;
  /**
     Fired when the user selects the "Stop" button to stop ongoing AI text generation.
    */
  ui5StopGeneration!: EventEmitter<void>;
  /**
     Fired when the user selects the version navigation buttons.
    */
  ui5VersionChange!: EventEmitter<InputVersionChangeEventDetail>;

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
