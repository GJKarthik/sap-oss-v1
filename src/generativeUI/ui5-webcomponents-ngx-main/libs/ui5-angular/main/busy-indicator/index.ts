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
import '@ui5/webcomponents/dist/BusyIndicator.js';
import BusyIndicator from '@ui5/webcomponents/dist/BusyIndicator.js';
@ProxyInputs(['text', 'size', 'active', 'delay', 'textPlacement'])
@Component({
  standalone: true,
  selector: 'ui5-busy-indicator',
  template: '<ng-content></ng-content>',
  inputs: ['text', 'size', 'active', 'delay', 'textPlacement'],
  exportAs: 'ui5BusyIndicator',
})
class BusyIndicatorComponent {
  /**
        Defines text to be displayed below the component. It can be used to inform the user of the current operation.
        */
  text!: string | undefined;
  /**
        Defines the size of the component.
        */
  size!: 'S' | 'M' | 'L';
  /**
        Defines if the busy indicator is visible on the screen. By default it is not.
        */
  @InputDecorator({ transform: booleanAttribute })
  active!: boolean;
  /**
        Defines the delay in milliseconds, after which the busy indicator will be visible on the screen.
        */
  delay!: number;
  /**
        Defines the placement of the text.
        */
  textPlacement!: 'Top' | 'Bottom';

  private elementRef: ElementRef<BusyIndicator> = inject(ElementRef);
  private zone = inject(NgZone);
  private cdr = inject(ChangeDetectorRef);

  get element(): BusyIndicator {
    return this.elementRef.nativeElement;
  }

  constructor() {
    this.cdr.detach();
  }
}
export { BusyIndicatorComponent };
