import {
  ChangeDetectorRef,
  Component,
  ElementRef,
  NgZone,
  inject,
} from '@angular/core';
import { ProxyInputs } from '@ui5/webcomponents-ngx/utils';
import '@ui5/webcomponents/dist/Bar.js';
import Bar from '@ui5/webcomponents/dist/Bar.js';
@ProxyInputs([
  'design',
  'accessibleRole',
  'accessibleName',
  'accessibleNameRef',
])
@Component({
  standalone: true,
  selector: 'ui5-bar',
  template: '<ng-content></ng-content>',
  inputs: ['design', 'accessibleRole', 'accessibleName', 'accessibleNameRef'],
  exportAs: 'ui5Bar',
})
class BarComponent {
  /**
        Defines the component's design.
        */
  design!: 'Header' | 'Subheader' | 'Footer' | 'FloatingFooter';
  /**
        Specifies the ARIA role applied to the component for accessibility purposes.

**Note:**

- Set accessibleRole to "toolbar" only when the component contains two or more active, interactive elements (such as buttons, links, or input fields) within the bar.

- If there is only one or no active element, it is recommended to avoid using the "toolbar" role, as it implies a grouping of multiple interactive controls.
        */
  accessibleRole!: 'Toolbar' | 'None';
  /**
        Defines the accessible ARIA name of the component.
        */
  accessibleName!: string | undefined;
  /**
        Receives id(or many ids) of the elements that label the bar.
        */
  accessibleNameRef!: string | undefined;

  private elementRef: ElementRef<Bar> = inject(ElementRef);
  private zone = inject(NgZone);
  private cdr = inject(ChangeDetectorRef);

  get element(): Bar {
    return this.elementRef.nativeElement;
  }

  constructor() {
    this.cdr.detach();
  }
}
export { BarComponent };
