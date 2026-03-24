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
import '@ui5/webcomponents/dist/ToolbarSelectOption.js';
import ToolbarSelectOption from '@ui5/webcomponents/dist/ToolbarSelectOption.js';
@ProxyInputs(['selected'])
@Component({
  standalone: true,
  selector: 'ui5-toolbar-select-option',
  template: '<ng-content></ng-content>',
  inputs: ['selected'],
  exportAs: 'ui5ToolbarSelectOption',
})
class ToolbarSelectOptionComponent {
  /**
        Defines the selected state of the component.
        */
  @InputDecorator({ transform: booleanAttribute })
  selected!: boolean;

  private elementRef: ElementRef<ToolbarSelectOption> = inject(ElementRef);
  private zone = inject(NgZone);
  private cdr = inject(ChangeDetectorRef);

  get element(): ToolbarSelectOption {
    return this.elementRef.nativeElement;
  }

  constructor() {
    this.cdr.detach();
  }
}
export { ToolbarSelectOptionComponent };
