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
import '@ui5/webcomponents-ai/dist/Button.js';
import {
  AIButtonAccessibilityAttributes,
  default as Button,
} from '@ui5/webcomponents-ai/dist/Button.js';
import { ProxyInputs, ProxyOutputs } from '@ui5/webcomponents-ngx/utils';
@ProxyInputs([
  'design',
  'disabled',
  'state',
  'arrowButtonPressed',
  'accessibilityAttributes',
])
@ProxyOutputs(['click: ui5Click', 'arrow-button-click: ui5ArrowButtonClick'])
@Component({
  standalone: true,
  selector: 'ui5-ai-button',
  template: '<ng-content></ng-content>',
  inputs: [
    'design',
    'disabled',
    'state',
    'arrowButtonPressed',
    'accessibilityAttributes',
  ],
  outputs: ['ui5Click', 'ui5ArrowButtonClick'],
  exportAs: 'ui5AiButton',
})
class ButtonComponent {
  /**
        Defines the component design.
        */
  design!:
    | 'Default'
    | 'Positive'
    | 'Negative'
    | 'Transparent'
    | 'Emphasized'
    | 'Attention'
    | undefined;
  /**
        Defines whether the component is disabled.
A disabled component can't be pressed or
focused, and it is not in the tab chain.
        */
  @InputDecorator({ transform: booleanAttribute })
  disabled!: boolean;
  /**
        Defines the current state of the component.
        */
  state!: string | undefined;
  /**
        Defines the active state of the arrow button in split mode.
Set to true when the button is in split mode and a menu with additional options
is opened by the arrow button. Set back to false when the menu is closed.
        */
  @InputDecorator({ transform: booleanAttribute })
  arrowButtonPressed!: boolean;
  /**
        Defines the additional accessibility attributes that will be applied to the component.

This property allows for fine-tuned control of ARIA attributes for screen reader support.
It accepts an object with the following optional fields:

- **root**: Accessibility attributes that will be applied to the root element.
 - **hasPopup**: Indicates the availability and type of interactive popup element (such as a menu or dialog).
   Accepts string values: `"dialog"`, `"grid"`, `"listbox"`, `"menu"`, or `"tree"`.
 - **roleDescription**: Defines a human-readable description for the button's role.
   Accepts any string value.
 - **title**: Specifies a tooltip or description for screen readers.
   Accepts any string value.
- **ariaKeyShortcuts**: Defines keyboard shortcuts that activate or focus the button.

- **arrowButton**: Accessibility attributes that will be applied to the arrow (split) button element.
 - **hasPopup**: Indicates the type of popup triggered by the arrow button.
   Accepts string values: `"dialog"`, `"grid"`, `"listbox"`, `"menu"`, or `"tree"`.
 - **expanded**: Indicates whether the popup controlled by the arrow button is currently expanded.
   Accepts boolean values: `true` or `false`.
        */
  accessibilityAttributes!: AIButtonAccessibilityAttributes;

  /**
     Fired when the component is activated either with a
mouse/tap or by using the Enter or Space key.
    */
  ui5Click!: EventEmitter<void>;
  /**
     Fired when the component is in split mode and after the arrow button
is activated either by clicking or tapping it or by using the [Arrow Up] / [Arrow Down],
[Alt] + [Arrow Up]/ [Arrow Down], or [F4] keyboard keys.
    */
  ui5ArrowButtonClick!: EventEmitter<void>;

  private elementRef: ElementRef<Button> = inject(ElementRef);
  private zone = inject(NgZone);
  private cdr = inject(ChangeDetectorRef);

  get element(): Button {
    return this.elementRef.nativeElement;
  }

  constructor() {
    this.cdr.detach();
  }
}
export { ButtonComponent };
