import {
  ChangeDetectorRef,
  Component,
  ElementRef,
  NgZone,
  inject,
} from '@angular/core';
import '@ui5/webcomponents-fiori/dist/DynamicPageHeader.js';
import DynamicPageHeader from '@ui5/webcomponents-fiori/dist/DynamicPageHeader.js';

@Component({
  standalone: true,
  selector: 'ui5-dynamic-page-header',
  template: '<ng-content></ng-content>',
  exportAs: 'ui5DynamicPageHeader',
})
class DynamicPageHeaderComponent {
  private elementRef: ElementRef<DynamicPageHeader> = inject(ElementRef);
  private zone = inject(NgZone);
  private cdr = inject(ChangeDetectorRef);

  get element(): DynamicPageHeader {
    return this.elementRef.nativeElement;
  }

  constructor() {
    this.cdr.detach();
  }
}
export { DynamicPageHeaderComponent };
