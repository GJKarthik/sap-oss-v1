import {
  ChangeDetectorRef,
  Component,
  ElementRef,
  NgZone,
  inject,
} from '@angular/core';
import { ProxyInputs } from '@ui5/webcomponents-ngx/utils';
import '@ui5/webcomponents/dist/FormGroup.js';
import FormGroup from '@ui5/webcomponents/dist/FormGroup.js';
@ProxyInputs([
  'headerText',
  'headerLevel',
  'columnSpan',
  'accessibleName',
  'accessibleNameRef',
])
@Component({
  standalone: true,
  selector: 'ui5-form-group',
  template: '<ng-content></ng-content>',
  inputs: [
    'headerText',
    'headerLevel',
    'columnSpan',
    'accessibleName',
    'accessibleNameRef',
  ],
  exportAs: 'ui5FormGroup',
})
class FormGroupComponent {
  /**
        Defines header text of the component.
        */
  headerText!: string | undefined;
  /**
        Defines the compoennt heading level,
set by the `headerText`.
        */
  headerLevel!: 'H1' | 'H2' | 'H3' | 'H4' | 'H5' | 'H6';
  /**
        Defines column span of the component,
e.g how many columns the group should span to.
        */
  columnSpan!: number | undefined;
  /**
        Defines the accessible ARIA name of the component.
        */
  accessibleName!: string | undefined;
  /**
        Defines id (or many ids) of the element (or elements) that label the component.
        */
  accessibleNameRef!: string | undefined;

  private elementRef: ElementRef<FormGroup> = inject(ElementRef);
  private zone = inject(NgZone);
  private cdr = inject(ChangeDetectorRef);

  get element(): FormGroup {
    return this.elementRef.nativeElement;
  }

  constructor() {
    this.cdr.detach();
  }
}
export { FormGroupComponent };
