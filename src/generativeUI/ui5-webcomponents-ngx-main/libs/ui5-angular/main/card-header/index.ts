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
import '@ui5/webcomponents/dist/CardHeader.js';
import CardHeader from '@ui5/webcomponents/dist/CardHeader.js';
@ProxyInputs(['titleText', 'subtitleText', 'additionalText', 'interactive'])
@ProxyOutputs(['click: ui5Click'])
@Component({
  standalone: true,
  selector: 'ui5-card-header',
  template: '<ng-content></ng-content>',
  inputs: ['titleText', 'subtitleText', 'additionalText', 'interactive'],
  outputs: ['ui5Click'],
  exportAs: 'ui5CardHeader',
})
class CardHeaderComponent {
  /**
        Defines the title text.
        */
  titleText!: string | undefined;
  /**
        Defines the subtitle text.
        */
  subtitleText!: string | undefined;
  /**
        Defines the additional text.
        */
  additionalText!: string | undefined;
  /**
        Defines if the component would be interactive,
e.g gets hover effect and `click` event is fired, when pressed.
        */
  @InputDecorator({ transform: booleanAttribute })
  interactive!: boolean;

  /**
     Fired when the component is activated by mouse/tap or by using the Enter or Space key.

**Note:** The event would be fired only if the `interactive` property is set to true.
    */
  ui5Click!: EventEmitter<void>;

  private elementRef: ElementRef<CardHeader> = inject(ElementRef);
  private zone = inject(NgZone);
  private cdr = inject(ChangeDetectorRef);

  get element(): CardHeader {
    return this.elementRef.nativeElement;
  }

  constructor() {
    this.cdr.detach();
  }
}
export { CardHeaderComponent };
