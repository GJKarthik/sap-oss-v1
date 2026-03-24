import {
  ChangeDetectorRef,
  Component,
  ElementRef,
  NgZone,
  inject,
} from '@angular/core';
import '@ui5/webcomponents-fiori/dist/ShellBarSpacer.js';
import ShellBarSpacer from '@ui5/webcomponents-fiori/dist/ShellBarSpacer.js';

@Component({
  standalone: true,
  selector: 'ui5-shellbar-spacer',
  template: '<ng-content></ng-content>',
  exportAs: 'ui5ShellbarSpacer',
})
class ShellBarSpacerComponent {
  private elementRef: ElementRef<ShellBarSpacer> = inject(ElementRef);
  private zone = inject(NgZone);
  private cdr = inject(ChangeDetectorRef);

  get element(): ShellBarSpacer {
    return this.elementRef.nativeElement;
  }

  constructor() {
    this.cdr.detach();
  }
}
export { ShellBarSpacerComponent };
