import {
  ChangeDetectorRef,
  Component,
  ElementRef,
  NgZone,
  inject,
} from '@angular/core';
import { ProxyInputs } from '@ui5/webcomponents-ngx/utils';
import '@ui5/webcomponents/dist/FormItem.js';
import FormItem from '@ui5/webcomponents/dist/FormItem.js';
@ProxyInputs(['columnSpan'])
@Component({
  standalone: true,
  selector: 'ui5-form-item',
  template: '<ng-content></ng-content>',
  inputs: ['columnSpan'],
  exportAs: 'ui5FormItem',
})
class FormItemComponent {
  /**
        Defines the column span of the component,
e.g how many columns the component should span to.

**Note:** The column span should be a number between 1 and the available columns of the FormGroup (when items are placed in a group)
or the Form. The available columns can be affected by the FormGroup#columnSpan and/or the Form#layout.
A number bigger than the available columns won't take effect.
        */
  columnSpan!: number | undefined;

  private elementRef: ElementRef<FormItem> = inject(ElementRef);
  private zone = inject(NgZone);
  private cdr = inject(ChangeDetectorRef);

  get element(): FormItem {
    return this.elementRef.nativeElement;
  }

  constructor() {
    this.cdr.detach();
  }
}
export { FormItemComponent };
