import {
  ChangeDetectorRef,
  Component,
  ElementRef,
  NgZone,
  inject,
} from '@angular/core';
import { ProxyInputs } from '@ui5/webcomponents-ngx/utils';
import '@ui5/webcomponents/dist/ExpandableText.js';
import ExpandableText from '@ui5/webcomponents/dist/ExpandableText.js';
@ProxyInputs(['text', 'maxCharacters', 'overflowMode', 'emptyIndicatorMode'])
@Component({
  standalone: true,
  selector: 'ui5-expandable-text',
  template: '<ng-content></ng-content>',
  inputs: ['text', 'maxCharacters', 'overflowMode', 'emptyIndicatorMode'],
  exportAs: 'ui5ExpandableText',
})
class ExpandableTextComponent {
  /**
        Text of the component.
        */
  text!: string | undefined;
  /**
        Maximum number of characters to be displayed initially. If the text length exceeds this limit, the text will be truncated with an ellipsis, and the "More" link will be displayed.
        */
  maxCharacters!: number;
  /**
        Determines how the full text will be displayed.
        */
  overflowMode!: 'InPlace' | 'Popover';
  /**
        Specifies if an empty indicator should be displayed when there is no text.
        */
  emptyIndicatorMode!: 'Off' | 'On';

  private elementRef: ElementRef<ExpandableText> = inject(ElementRef);
  private zone = inject(NgZone);
  private cdr = inject(ChangeDetectorRef);

  get element(): ExpandableText {
    return this.elementRef.nativeElement;
  }

  constructor() {
    this.cdr.detach();
  }
}
export { ExpandableTextComponent };
