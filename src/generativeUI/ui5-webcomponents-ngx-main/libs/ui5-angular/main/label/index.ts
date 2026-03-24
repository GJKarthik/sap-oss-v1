import {
  ChangeDetectorRef,
  Component,
  ElementRef,
  Input as InputDecorator,
  NgZone,
  booleanAttribute,
  inject,
} from '@angular/core';
import { ProxyInputs } from '@ui5/webcomponents-ngx/utils';
import '@ui5/webcomponents/dist/Label.js';
import Label from '@ui5/webcomponents/dist/Label.js';
@ProxyInputs(['for', 'showColon', 'required', 'wrappingType'])
@Component({
  standalone: true,
  selector: 'ui5-label',
  template: '<ng-content></ng-content>',
  inputs: ['for', 'showColon', 'required', 'wrappingType'],
  exportAs: 'ui5Label',
})
class LabelComponent {
  /**
        Defines the labeled input by providing its ID.

**Note:** Can be used with both `ui5-input` and native input.
        */
  for!: string | undefined;
  /**
        Defines whether colon is added to the component text.

**Note:** Usually used in forms.
        */
  @InputDecorator({ transform: booleanAttribute })
  showColon!: boolean;
  /**
        Defines whether an asterisk character is added to the component text.

**Note:** Usually indicates that user input (bound with the `for` property) is required.
In that case the `required` property of
the corresponding input should also be set.
        */
  @InputDecorator({ transform: booleanAttribute })
  required!: boolean;
  /**
        Defines how the text of a component will be displayed when there is not enough space.

**Note:** for option "Normal" the text will wrap and the words will not be broken based on hyphenation.
        */
  wrappingType!: 'None' | 'Normal';

  private elementRef: ElementRef<Label> = inject(ElementRef);
  private zone = inject(NgZone);
  private cdr = inject(ChangeDetectorRef);

  get element(): Label {
    return this.elementRef.nativeElement;
  }

  constructor() {
    this.cdr.detach();
  }
}
export { LabelComponent };
