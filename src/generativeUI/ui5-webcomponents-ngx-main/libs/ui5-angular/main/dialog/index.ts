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
import '@ui5/webcomponents/dist/Dialog.js';
import Dialog from '@ui5/webcomponents/dist/Dialog.js';
import { PopupBeforeCloseEventDetail } from '@ui5/webcomponents/dist/Popup.js';
@ProxyInputs([
  'initialFocus',
  'preventFocusRestore',
  'accessibleName',
  'accessibleNameRef',
  'accessibleRole',
  'accessibleDescription',
  'accessibleDescriptionRef',
  'preventInitialFocus',
  'open',
  'headerText',
  'stretch',
  'draggable',
  'resizable',
  'state',
])
@ProxyOutputs([
  'before-open: ui5BeforeOpen',
  'open: ui5Open',
  'before-close: ui5BeforeClose',
  'close: ui5Close',
])
@Component({
  standalone: true,
  selector: 'ui5-dialog',
  template: '<ng-content></ng-content>',
  inputs: [
    'initialFocus',
    'preventFocusRestore',
    'accessibleName',
    'accessibleNameRef',
    'accessibleRole',
    'accessibleDescription',
    'accessibleDescriptionRef',
    'preventInitialFocus',
    'open',
    'headerText',
    'stretch',
    'draggable',
    'resizable',
    'state',
  ],
  outputs: ['ui5BeforeOpen', 'ui5Open', 'ui5BeforeClose', 'ui5Close'],
  exportAs: 'ui5Dialog',
})
class DialogComponent {
  /**
        Defines the ID of the HTML Element, which will get the initial focus.

**Note:** If an element with `autofocus` attribute is added inside the component,
`initialFocus` won't take effect.
        */
  initialFocus!: string | undefined;
  /**
        Defines if the focus should be returned to the previously focused element,
when the popup closes.
        */
  @InputDecorator({ transform: booleanAttribute })
  preventFocusRestore!: boolean;
  /**
        Defines the accessible name of the component.
        */
  accessibleName!: string | undefined;
  /**
        Defines the IDs of the elements that label the component.
        */
  accessibleNameRef!: string | undefined;
  /**
        Allows setting a custom role.
        */
  accessibleRole!: 'None' | 'Dialog' | 'AlertDialog';
  /**
        Defines the accessible description of the component.
        */
  accessibleDescription!: string | undefined;
  /**
        Receives id(or many ids) of the elements that describe the component.
        */
  accessibleDescriptionRef!: string | undefined;
  /**
        Indicates whether initial focus should be prevented.
        */
  @InputDecorator({ transform: booleanAttribute })
  preventInitialFocus!: boolean;
  /**
        Indicates if the element is open
        */
  @InputDecorator({ transform: booleanAttribute })
  open!: boolean;
  /**
        Defines the header text.

**Note:** If `header` slot is provided, the `headerText` is ignored.
        */
  headerText!: string | undefined;
  /**
        Determines if the dialog will be stretched to full screen on mobile. On desktop,
the dialog will be stretched to approximately 90% of the viewport.

**Note:** For better usability of the component it is recommended to set this property to "true" when the dialog is opened on phone.
        */
  @InputDecorator({ transform: booleanAttribute })
  stretch!: boolean;
  /**
        Determines whether the component is draggable.
If this property is set to true, the Dialog will be draggable by its header.

**Note:** The component can be draggable only in desktop mode.

**Note:** This property overrides the default HTML "draggable" attribute native behavior.
When "draggable" is set to true, the native browser "draggable"
behavior is prevented and only the Dialog custom logic ("draggable by its header") works.
        */
  @InputDecorator({ transform: booleanAttribute })
  draggable!: boolean;
  /**
        Configures the component to be resizable.
If this property is set to true, the Dialog will have a resize handle in its bottom right corner in LTR languages.
In RTL languages, the resize handle will be placed in the bottom left corner.

**Note:** The component can be resizable only in desktop mode.

**Note:** Upon resizing, externally defined height and width styling will be ignored.
        */
  @InputDecorator({ transform: booleanAttribute })
  resizable!: boolean;
  /**
        Defines the state of the `Dialog`.

**Note:** If `"Negative"` and `"Critical"` states is set, it will change the
accessibility role to "alertdialog", if the accessibleRole property is set to `"Dialog"`.
        */
  state!: 'None' | 'Positive' | 'Critical' | 'Negative' | 'Information';

  /**
     Fired before the component is opened. This event can be cancelled, which will prevent the popup from opening.
    */
  ui5BeforeOpen!: EventEmitter<void>;
  /**
     Fired after the component is opened.
    */
  ui5Open!: EventEmitter<void>;
  /**
     Fired before the component is closed. This event can be cancelled, which will prevent the popup from closing.
    */
  ui5BeforeClose!: EventEmitter<PopupBeforeCloseEventDetail>;
  /**
     Fired after the component is closed.
    */
  ui5Close!: EventEmitter<void>;

  private elementRef: ElementRef<Dialog> = inject(ElementRef);
  private zone = inject(NgZone);
  private cdr = inject(ChangeDetectorRef);

  get element(): Dialog {
    return this.elementRef.nativeElement;
  }

  constructor() {
    this.cdr.detach();
  }
}
export { DialogComponent };
