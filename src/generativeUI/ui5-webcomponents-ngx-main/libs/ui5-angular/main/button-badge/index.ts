import {
  ChangeDetectorRef,
  Component,
  ElementRef,
  NgZone,
  inject,
} from '@angular/core';
import { ProxyInputs } from '@ui5/webcomponents-ngx/utils';
import '@ui5/webcomponents/dist/ButtonBadge.js';
import ButtonBadge from '@ui5/webcomponents/dist/ButtonBadge.js';
@ProxyInputs(['design', 'text'])
@Component({
  standalone: true,
  selector: 'ui5-button-badge',
  template: '<ng-content></ng-content>',
  inputs: ['design', 'text'],
  exportAs: 'ui5ButtonBadge',
})
class ButtonBadgeComponent {
  /**
        Defines the badge placement and appearance.
- **InlineText** - displayed inside the button after its text, and recommended for **compact** density.
- **OverlayText** - displayed at the top-end corner of the button, and recommended for **cozy** density.
- **AttentionDot** - displayed at the top-end corner of the button as a dot, and suitable for both **cozy** and **compact** densities.
        */
  design!: 'InlineText' | 'OverlayText' | 'AttentionDot';
  /**
        Defines the text of the component.

**Note:** Text is not applied when the `design` property is set to `AttentionDot`.

**Note:** The badge component only accepts numeric values and the "+" symbol. Using other characters or formats may result in unpredictable behavior, which is not guaranteed or supported.
        */
  text!: string;

  private elementRef: ElementRef<ButtonBadge> = inject(ElementRef);
  private zone = inject(NgZone);
  private cdr = inject(ChangeDetectorRef);

  get element(): ButtonBadge {
    return this.elementRef.nativeElement;
  }

  constructor() {
    this.cdr.detach();
  }
}
export { ButtonBadgeComponent };
