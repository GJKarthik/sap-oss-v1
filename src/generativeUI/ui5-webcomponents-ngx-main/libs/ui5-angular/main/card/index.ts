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
import '@ui5/webcomponents/dist/Card.js';
import Card from '@ui5/webcomponents/dist/Card.js';
@ProxyInputs(['accessibleName', 'accessibleNameRef', 'loading', 'loadingDelay'])
@Component({
  standalone: true,
  selector: 'ui5-card',
  template: '<ng-content></ng-content>',
  inputs: ['accessibleName', 'accessibleNameRef', 'loading', 'loadingDelay'],
  exportAs: 'ui5Card',
})
class CardComponent {
  /**
        Defines the accessible name of the component, which is used as the name of the card region and should be unique per card.

**Note:** `accessibleName` should be always set, unless `accessibleNameRef` is set.
        */
  accessibleName!: string | undefined;
  /**
        Defines the IDs of the elements that label the component.
        */
  accessibleNameRef!: string | undefined;
  /**
        Defines if a loading indicator would be displayed over the card.
        */
  @InputDecorator({ transform: booleanAttribute })
  loading!: boolean;
  /**
        Defines the delay in milliseconds, after which the loading indicator will show up for this card.
        */
  loadingDelay!: number;

  private elementRef: ElementRef<Card> = inject(ElementRef);
  private zone = inject(NgZone);
  private cdr = inject(ChangeDetectorRef);

  get element(): Card {
    return this.elementRef.nativeElement;
  }

  constructor() {
    this.cdr.detach();
  }
}
export { CardComponent };
