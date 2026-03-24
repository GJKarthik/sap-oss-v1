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
import '@ui5/webcomponents/dist/Toast.js';
import Toast from '@ui5/webcomponents/dist/Toast.js';
@ProxyInputs(['duration', 'placement', 'open'])
@ProxyOutputs(['close: ui5Close'])
@Component({
  standalone: true,
  selector: 'ui5-toast',
  template: '<ng-content></ng-content>',
  inputs: ['duration', 'placement', 'open'],
  outputs: ['ui5Close'],
  exportAs: 'ui5Toast',
})
class ToastComponent {
  /**
        Defines the duration in milliseconds for which component
remains on the screen before it's automatically closed.

**Note:** The minimum supported value is `500` ms
and even if a lower value is set, the duration would remain `500` ms.
        */
  duration!: number;
  /**
        Defines the placement of the component.
        */
  placement!:
    | 'TopStart'
    | 'TopCenter'
    | 'TopEnd'
    | 'MiddleStart'
    | 'MiddleCenter'
    | 'MiddleEnd'
    | 'BottomStart'
    | 'BottomCenter'
    | 'BottomEnd';
  /**
        Indicates whether the component is open (visible).
        */
  @InputDecorator({ transform: booleanAttribute })
  open!: boolean;

  /**
     Fired after the component is auto closed.
    */
  ui5Close!: EventEmitter<void>;

  private elementRef: ElementRef<Toast> = inject(ElementRef);
  private zone = inject(NgZone);
  private cdr = inject(ChangeDetectorRef);

  get element(): Toast {
    return this.elementRef.nativeElement;
  }

  constructor() {
    this.cdr.detach();
  }
}
export { ToastComponent };
