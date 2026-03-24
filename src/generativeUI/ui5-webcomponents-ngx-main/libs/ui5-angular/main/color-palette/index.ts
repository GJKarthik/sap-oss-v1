import {
  ChangeDetectorRef,
  Component,
  ElementRef,
  EventEmitter,
  NgZone,
  inject,
} from '@angular/core';
import { ProxyOutputs } from '@ui5/webcomponents-ngx/utils';
import '@ui5/webcomponents/dist/ColorPalette.js';
import {
  default as ColorPalette,
  ColorPaletteItemClickEventDetail,
} from '@ui5/webcomponents/dist/ColorPalette.js';

@ProxyOutputs(['item-click: ui5ItemClick'])
@Component({
  standalone: true,
  selector: 'ui5-color-palette',
  template: '<ng-content></ng-content>',
  outputs: ['ui5ItemClick'],
  exportAs: 'ui5ColorPalette',
})
class ColorPaletteComponent {
  /**
     Fired when the user selects a color.
    */
  ui5ItemClick!: EventEmitter<ColorPaletteItemClickEventDetail>;

  private elementRef: ElementRef<ColorPalette> = inject(ElementRef);
  private zone = inject(NgZone);
  private cdr = inject(ChangeDetectorRef);

  get element(): ColorPalette {
    return this.elementRef.nativeElement;
  }

  constructor() {
    this.cdr.detach();
  }
}
export { ColorPaletteComponent };
