import {
  ChangeDetectorRef,
  Component,
  ElementRef,
  NgZone,
  inject,
} from '@angular/core';
import '@ui5/webcomponents/dist/MenuSeparator.js';
import MenuSeparator from '@ui5/webcomponents/dist/MenuSeparator.js';

@Component({
  standalone: true,
  selector: 'ui5-menu-separator',
  template: '<ng-content></ng-content>',
  exportAs: 'ui5MenuSeparator',
})
class MenuSeparatorComponent {
  private elementRef: ElementRef<MenuSeparator> = inject(ElementRef);
  private zone = inject(NgZone);
  private cdr = inject(ChangeDetectorRef);

  get element(): MenuSeparator {
    return this.elementRef.nativeElement;
  }

  constructor() {
    this.cdr.detach();
  }
}
export { MenuSeparatorComponent };
