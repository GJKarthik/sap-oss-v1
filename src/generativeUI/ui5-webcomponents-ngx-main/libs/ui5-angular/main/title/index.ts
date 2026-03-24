import {
  ChangeDetectorRef,
  Component,
  ElementRef,
  NgZone,
  inject,
} from '@angular/core';
import { ProxyInputs } from '@ui5/webcomponents-ngx/utils';
import '@ui5/webcomponents/dist/Title.js';
import Title from '@ui5/webcomponents/dist/Title.js';
@ProxyInputs(['wrappingType', 'level', 'size'])
@Component({
  standalone: true,
  selector: 'ui5-title',
  template: '<ng-content></ng-content>',
  inputs: ['wrappingType', 'level', 'size'],
  exportAs: 'ui5Title',
})
class TitleComponent {
  /**
        Defines how the text of a component will be displayed when there is not enough space.

**Note:** for option "Normal" the text will wrap and the words will not be broken based on hyphenation.
        */
  wrappingType!: 'None' | 'Normal';
  /**
        Defines the component level.
Available options are: `"H6"` to `"H1"`.
This property does not influence the style of the component.
Use the property `size` for this purpose instead.
        */
  level!: 'H1' | 'H2' | 'H3' | 'H4' | 'H5' | 'H6';
  /**
        Defines the visual appearance of the title.
Available options are: `"H6"` to `"H1"`.
        */
  size!: 'H1' | 'H2' | 'H3' | 'H4' | 'H5' | 'H6';

  private elementRef: ElementRef<Title> = inject(ElementRef);
  private zone = inject(NgZone);
  private cdr = inject(ChangeDetectorRef);

  get element(): Title {
    return this.elementRef.nativeElement;
  }

  constructor() {
    this.cdr.detach();
  }
}
export { TitleComponent };
