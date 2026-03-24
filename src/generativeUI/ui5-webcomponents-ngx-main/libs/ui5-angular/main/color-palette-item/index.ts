import {
  ChangeDetectorRef,
  Component,
  ElementRef,
  Input as InputDecorator,
  NgZone,
  booleanAttribute,
  inject,
} from '@angular/core';
import { ProxyInputs } from '@ui5/webcomponents-ngx/utils';
import '@ui5/webcomponents/dist/ColorPaletteItem.js';
import ColorPaletteItem from '@ui5/webcomponents/dist/ColorPaletteItem.js';
@ProxyInputs(['value', 'selected'])
@Component({
  standalone: true,
  selector: 'ui5-color-palette-item',
  template: '<ng-content></ng-content>',
  inputs: ['value', 'selected'],
  exportAs: 'ui5ColorPaletteItem',
})
class ColorPaletteItemComponent {
  /**
        Defines the colour of the component.

**Note:** The value should be a valid CSS color.
        */
  value!: string;
  /**
        Defines if the component is selected.

**Note:** Only one item must be selected per <code>ui5-color-palette</code>.
If more than one item is defined as selected, the last one would be considered as the selected one.
        */
  @InputDecorator({ transform: booleanAttribute })
  selected!: boolean;

  private elementRef: ElementRef<ColorPaletteItem> = inject(ElementRef);
  private zone = inject(NgZone);
  private cdr = inject(ChangeDetectorRef);

  get element(): ColorPaletteItem {
    return this.elementRef.nativeElement;
  }

  constructor() {
    this.cdr.detach();
  }
}
export { ColorPaletteItemComponent };
