import {
  ChangeDetectorRef,
  Component,
  ElementRef,
  NgZone,
  inject,
} from '@angular/core';
import '@ui5/webcomponents/dist/TabSeparator.js';
import TabSeparator from '@ui5/webcomponents/dist/TabSeparator.js';

@Component({
  standalone: true,
  selector: 'ui5-tab-separator',
  template: '<ng-content></ng-content>',
  exportAs: 'ui5TabSeparator',
})
class TabSeparatorComponent {
  private elementRef: ElementRef<TabSeparator> = inject(ElementRef);
  private zone = inject(NgZone);
  private cdr = inject(ChangeDetectorRef);

  get element(): TabSeparator {
    return this.elementRef.nativeElement;
  }

  constructor() {
    this.cdr.detach();
  }
}
export { TabSeparatorComponent };
