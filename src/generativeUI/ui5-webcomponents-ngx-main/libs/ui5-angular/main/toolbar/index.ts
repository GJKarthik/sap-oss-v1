import {
  ChangeDetectorRef,
  Component,
  ElementRef,
  NgZone,
  inject,
} from '@angular/core';
import { ProxyInputs } from '@ui5/webcomponents-ngx/utils';
import '@ui5/webcomponents/dist/Toolbar.js';
import Toolbar from '@ui5/webcomponents/dist/Toolbar.js';
@ProxyInputs(['alignContent', 'accessibleName', 'accessibleNameRef', 'design'])
@Component({
  standalone: true,
  selector: 'ui5-toolbar',
  template: '<ng-content></ng-content>',
  inputs: ['alignContent', 'accessibleName', 'accessibleNameRef', 'design'],
  exportAs: 'ui5Toolbar',
})
class ToolbarComponent {
  /**
        Indicated the direction in which the Toolbar items will be aligned.
        */
  alignContent!: 'Start' | 'End';
  /**
        Defines the accessible ARIA name of the component.
        */
  accessibleName!: string | undefined;
  /**
        Receives id(or many ids) of the elements that label the input.
        */
  accessibleNameRef!: string | undefined;
  /**
        Defines the toolbar design.
        */
  design!: 'Solid' | 'Transparent';

  private elementRef: ElementRef<Toolbar> = inject(ElementRef);
  private zone = inject(NgZone);
  private cdr = inject(ChangeDetectorRef);

  get element(): Toolbar {
    return this.elementRef.nativeElement;
  }

  constructor() {
    this.cdr.detach();
  }
}
export { ToolbarComponent };
