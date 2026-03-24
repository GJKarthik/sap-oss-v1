import {
  ChangeDetectorRef,
  Component,
  ElementRef,
  NgZone,
  inject,
} from '@angular/core';
import '@ui5/webcomponents-fiori/dist/DynamicPageTitle.js';
import DynamicPageTitle from '@ui5/webcomponents-fiori/dist/DynamicPageTitle.js';

@Component({
  standalone: true,
  selector: 'ui5-dynamic-page-title',
  template: '<ng-content></ng-content>',
  exportAs: 'ui5DynamicPageTitle',
})
class DynamicPageTitleComponent {
  private elementRef: ElementRef<DynamicPageTitle> = inject(ElementRef);
  private zone = inject(NgZone);
  private cdr = inject(ChangeDetectorRef);

  get element(): DynamicPageTitle {
    return this.elementRef.nativeElement;
  }

  constructor() {
    this.cdr.detach();
  }
}
export { DynamicPageTitleComponent };
