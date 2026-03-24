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
import '@ui5/webcomponents/dist/Tokenizer.js';
import {
  default as Tokenizer,
  TokenizerSelectionChangeEventDetail,
  TokenizerTokenDeleteEventDetail,
} from '@ui5/webcomponents/dist/Tokenizer.js';
@ProxyInputs([
  'readonly',
  'multiLine',
  'name',
  'showClearAll',
  'disabled',
  'accessibleName',
  'accessibleNameRef',
])
@ProxyOutputs([
  'token-delete: ui5TokenDelete',
  'selection-change: ui5SelectionChange',
])
@Component({
  standalone: true,
  selector: 'ui5-tokenizer',
  template: '<ng-content></ng-content>',
  inputs: [
    'readonly',
    'multiLine',
    'name',
    'showClearAll',
    'disabled',
    'accessibleName',
    'accessibleNameRef',
  ],
  outputs: ['ui5TokenDelete', 'ui5SelectionChange'],
  exportAs: 'ui5Tokenizer',
})
class TokenizerComponent {
  /**
        Defines whether the component is read-only.

**Note:** A read-only component is not editable,
but still provides visual feedback upon user interaction.
        */
  @InputDecorator({ transform: booleanAttribute })
  readonly!: boolean;
  /**
        Defines whether tokens are displayed on multiple lines.

**Note:** The `multiLine` property is in an experimental state and is a subject to change.
        */
  @InputDecorator({ transform: booleanAttribute })
  multiLine!: boolean;
  /**
        Determines the name by which the component will be identified upon submission in an HTML form.

**Note:** This property is only applicable within the context of an HTML Form element.
**Note:** When the component is used inside a form element,
the value is sent as the first element in the form data, even if it's empty.
        */
  name!: string | undefined;
  /**
        Defines whether "Clear All" button is present. Ensure `multiLine` is enabled, otherwise `showClearAll` will have no effect.

**Note:** The `showClearAll` property is in an experimental state and is a subject to change.
        */
  @InputDecorator({ transform: booleanAttribute })
  showClearAll!: boolean;
  /**
        Defines whether the component is disabled.

**Note:** A disabled component is completely noninteractive.
        */
  @InputDecorator({ transform: booleanAttribute })
  disabled!: boolean;
  /**
        Defines the accessible ARIA name of the component.
        */
  accessibleName!: string | undefined;
  /**
        Receives id(or many ids) of the elements that label the component.
        */
  accessibleNameRef!: string | undefined;

  /**
     Fired when tokens are being deleted (delete icon, delete or backspace is pressed)
    */
  ui5TokenDelete!: EventEmitter<TokenizerTokenDeleteEventDetail>;
  /**
     Fired when token selection is changed by user interaction
    */
  ui5SelectionChange!: EventEmitter<TokenizerSelectionChangeEventDetail>;

  private elementRef: ElementRef<Tokenizer> = inject(ElementRef);
  private zone = inject(NgZone);
  private cdr = inject(ChangeDetectorRef);

  get element(): Tokenizer {
    return this.elementRef.nativeElement;
  }

  constructor() {
    this.cdr.detach();
  }
}
export { TokenizerComponent };
