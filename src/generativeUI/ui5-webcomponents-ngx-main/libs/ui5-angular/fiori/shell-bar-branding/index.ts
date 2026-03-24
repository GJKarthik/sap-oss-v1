import {
  ChangeDetectorRef,
  Component,
  ElementRef,
  EventEmitter,
  NgZone,
  inject,
} from '@angular/core';
import '@ui5/webcomponents-fiori/dist/ShellBarBranding.js';
import ShellBarBranding from '@ui5/webcomponents-fiori/dist/ShellBarBranding.js';
import { ProxyInputs, ProxyOutputs } from '@ui5/webcomponents-ngx/utils';
@ProxyInputs(['href', 'target', 'accessibleName'])
@ProxyOutputs(['click: ui5Click'])
@Component({
  standalone: true,
  selector: 'ui5-shellbar-branding',
  template: '<ng-content></ng-content>',
  inputs: ['href', 'target', 'accessibleName'],
  outputs: ['ui5Click'],
  exportAs: 'ui5ShellbarBranding',
})
class ShellBarBrandingComponent {
  /**
        Defines the component href.

**Note:** Standard hyperlink behavior is supported.
        */
  href!: string | undefined;
  /**
        Defines the component target.

**Notes:**

- `_self`
- `_top`
- `_blank`
- `_parent`
- `_search`

**This property must only be used when the `href` property is set.**
        */
  target!: string | undefined;
  /**
        Defines the text alternative of the component.
If not provided a default text alternative will be set, if present.
        */
  accessibleName!: string | undefined;

  /**
     Fired, when the logo is activated.
    */
  ui5Click!: EventEmitter<void>;

  private elementRef: ElementRef<ShellBarBranding> = inject(ElementRef);
  private zone = inject(NgZone);
  private cdr = inject(ChangeDetectorRef);

  get element(): ShellBarBranding {
    return this.elementRef.nativeElement;
  }

  constructor() {
    this.cdr.detach();
  }
}
export { ShellBarBrandingComponent };
