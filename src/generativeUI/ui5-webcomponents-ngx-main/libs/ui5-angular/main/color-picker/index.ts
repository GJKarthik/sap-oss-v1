import {
  ChangeDetectorRef,
  Component,
  ElementRef,
  EventEmitter,
  Input as InputDecorator,
  NgZone,
  booleanAttribute,
  inject,
} from '@angular/core';
import { ProxyInputs, ProxyOutputs } from '@ui5/webcomponents-ngx/utils';
import '@ui5/webcomponents/dist/ColorPicker.js';
import ColorPicker from '@ui5/webcomponents/dist/ColorPicker.js';
@ProxyInputs(['value', 'name', 'simplified'])
@ProxyOutputs(['change: ui5Change'])
@Component({
  standalone: true,
  selector: 'ui5-color-picker',
  template: '<ng-content></ng-content>',
  inputs: ['value', 'name', 'simplified'],
  outputs: ['ui5Change'],
  exportAs: 'ui5ColorPicker',
})
class ColorPickerComponent {
  /**
        Defines the currently selected color of the component.

**Note**: use HEX, RGB, RGBA, HSV formats or a CSS color name when modifying this property.
        */
  value!: string;
  /**
        Determines the name by which the component will be identified upon submission in an HTML form.

**Note:** This property is only applicable within the context of an HTML Form element.
        */
  name!: string | undefined;
  /**
        When set to `true`, the alpha slider and inputs for RGB values will not be displayed.
        */
  @InputDecorator({ transform: booleanAttribute })
  simplified!: boolean;

  /**
     Fired when the the selected color is changed
    */
  ui5Change!: EventEmitter<void>;

  private elementRef: ElementRef<ColorPicker> = inject(ElementRef);
  private zone = inject(NgZone);
  private cdr = inject(ChangeDetectorRef);

  get element(): ColorPicker {
    return this.elementRef.nativeElement;
  }

  constructor() {
    this.cdr.detach();
  }
}
export { ColorPickerComponent };
