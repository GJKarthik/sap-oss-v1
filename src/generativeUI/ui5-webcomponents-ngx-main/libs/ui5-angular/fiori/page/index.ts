import {
  ChangeDetectorRef,
  Component,
  ElementRef,
  Input as InputDecorator,
  NgZone,
  booleanAttribute,
  inject,
} from '@angular/core';
import '@ui5/webcomponents-fiori/dist/Page.js';
import Page from '@ui5/webcomponents-fiori/dist/Page.js';
import { ProxyInputs } from '@ui5/webcomponents-ngx/utils';
@ProxyInputs(['backgroundDesign', 'noScrolling', 'fixedFooter', 'hideFooter'])
@Component({
  standalone: true,
  selector: 'ui5-page',
  template: '<ng-content></ng-content>',
  inputs: ['backgroundDesign', 'noScrolling', 'fixedFooter', 'hideFooter'],
  exportAs: 'ui5Page',
})
class PageComponent {
  /**
        Defines the background color of the `ui5-page`.

**Note:** When a ui5-list is placed inside the page, we recommend using “List” to ensure better color contrast.
        */
  backgroundDesign!: 'List' | 'Solid' | 'Transparent';
  /**
        Disables vertical scrolling of page content.
If set to true, there will be no vertical scrolling at all.
        */
  @InputDecorator({ transform: booleanAttribute })
  noScrolling!: boolean;
  /**
        Defines if the footer is fixed at the very bottom of the page.

**Note:** When set to true the footer is fixed at the very bottom of the page, otherwise it floats over the content with a slight offset from the bottom.
        */
  @InputDecorator({ transform: booleanAttribute })
  fixedFooter!: boolean;
  /**
        Defines the footer visibility.
        */
  @InputDecorator({ transform: booleanAttribute })
  hideFooter!: boolean;

  private elementRef: ElementRef<Page> = inject(ElementRef);
  private zone = inject(NgZone);
  private cdr = inject(ChangeDetectorRef);

  get element(): Page {
    return this.elementRef.nativeElement;
  }

  constructor() {
    this.cdr.detach();
  }
}
export { PageComponent };
