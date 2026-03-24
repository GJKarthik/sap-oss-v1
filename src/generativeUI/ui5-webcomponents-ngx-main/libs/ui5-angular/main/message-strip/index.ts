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
import '@ui5/webcomponents/dist/MessageStrip.js';
import MessageStrip from '@ui5/webcomponents/dist/MessageStrip.js';
@ProxyInputs(['design', 'colorScheme', 'hideIcon', 'hideCloseButton'])
@ProxyOutputs(['close: ui5Close'])
@Component({
  standalone: true,
  selector: 'ui5-message-strip',
  template: '<ng-content></ng-content>',
  inputs: ['design', 'colorScheme', 'hideIcon', 'hideCloseButton'],
  outputs: ['ui5Close'],
  exportAs: 'ui5MessageStrip',
})
class MessageStripComponent {
  /**
        Defines the component type.
        */
  design!:
    | 'Information'
    | 'Positive'
    | 'Negative'
    | 'Critical'
    | 'ColorSet1'
    | 'ColorSet2';
  /**
        Defines the color scheme of the component.
There are 10 predefined schemes.
To use one you can set a number from `"1"` to `"10"`. The `colorScheme` `"1"` will be set by default.
        */
  colorScheme!: string;
  /**
        Defines whether the MessageStrip will show an icon in the beginning.
You can directly provide an icon with the `icon` slot. Otherwise, the default icon for the type will be used.

 * **Note:** If <code>MessageStripDesign.ColorSet1</code> or <code>MessageStripDesign.ColorSet2</code> value is set to the <code>design</code> property, default icon will not be presented.
        */
  @InputDecorator({ transform: booleanAttribute })
  hideIcon!: boolean;
  /**
        Defines whether the MessageStrip renders close button.
        */
  @InputDecorator({ transform: booleanAttribute })
  hideCloseButton!: boolean;

  /**
     Fired when the close button is pressed either with a
click/tap or by using the Enter or Space key.
    */
  ui5Close!: EventEmitter<void>;

  private elementRef: ElementRef<MessageStrip> = inject(ElementRef);
  private zone = inject(NgZone);
  private cdr = inject(ChangeDetectorRef);

  get element(): MessageStrip {
    return this.elementRef.nativeElement;
  }

  constructor() {
    this.cdr.detach();
  }
}
export { MessageStripComponent };
