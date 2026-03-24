import {
  ChangeDetectorRef,
  Component,
  ElementRef,
  NgZone,
  inject,
} from '@angular/core';
import '@ui5/webcomponents-fiori/dist/NavigationLayout.js';
import NavigationLayout from '@ui5/webcomponents-fiori/dist/NavigationLayout.js';
import { ProxyInputs } from '@ui5/webcomponents-ngx/utils';
@ProxyInputs(['mode'])
@Component({
  standalone: true,
  selector: 'ui5-navigation-layout',
  template: '<ng-content></ng-content>',
  inputs: ['mode'],
  exportAs: 'ui5NavigationLayout',
})
class NavigationLayoutComponent {
  /**
        Specifies the navigation layout mode.
        */
  mode!: 'Auto' | 'Collapsed' | 'Expanded';

  private elementRef: ElementRef<NavigationLayout> = inject(ElementRef);
  private zone = inject(NgZone);
  private cdr = inject(ChangeDetectorRef);

  get element(): NavigationLayout {
    return this.elementRef.nativeElement;
  }

  constructor() {
    this.cdr.detach();
  }
}
export { NavigationLayoutComponent };
