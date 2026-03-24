import {
  ChangeDetectorRef,
  Component,
  ElementRef,
  NgZone,
  inject,
} from '@angular/core';
import { ProxyInputs } from '@ui5/webcomponents-ngx/utils';
import '@ui5/webcomponents/dist/Text.js';
import Text from '@ui5/webcomponents/dist/Text.js';
@ProxyInputs(['maxLines', 'emptyIndicatorMode'])
@Component({
  standalone: true,
  selector: 'ui5-text',
  template: '<ng-content></ng-content>',
  inputs: ['maxLines', 'emptyIndicatorMode'],
  exportAs: 'ui5Text',
})
class TextComponent {
  /**
        Defines the number of lines the text should wrap before it truncates.
        */
  maxLines!: number;
  /**
        Specifies if an empty indicator should be displayed when there is no text.
        */
  emptyIndicatorMode!: 'Off' | 'On';

  private elementRef: ElementRef<Text> = inject(ElementRef);
  private zone = inject(NgZone);
  private cdr = inject(ChangeDetectorRef);

  get element(): Text {
    return this.elementRef.nativeElement;
  }

  constructor() {
    this.cdr.detach();
  }
}
export { TextComponent };
