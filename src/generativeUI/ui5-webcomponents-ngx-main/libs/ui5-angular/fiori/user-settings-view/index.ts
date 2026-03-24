import {
  ChangeDetectorRef,
  Component,
  ElementRef,
  Input as InputDecorator,
  NgZone,
  booleanAttribute,
  inject,
} from '@angular/core';
import '@ui5/webcomponents-fiori/dist/UserSettingsView.js';
import UserSettingsView from '@ui5/webcomponents-fiori/dist/UserSettingsView.js';
import { ProxyInputs } from '@ui5/webcomponents-ngx/utils';
@ProxyInputs(['text', 'selected', 'secondary'])
@Component({
  standalone: true,
  selector: 'ui5-user-settings-view',
  template: '<ng-content></ng-content>',
  inputs: ['text', 'selected', 'secondary'],
  exportAs: 'ui5UserSettingsView',
})
class UserSettingsViewComponent {
  /**
        Defines the title text of the user settings view.
        */
  text!: string | undefined;
  /**
        Defines whether the view is selected. There can be just one selected view at a time.
        */
  @InputDecorator({ transform: booleanAttribute })
  selected!: boolean;
  /**
        Indicates whether the view is secondary. It is relevant only if the view is used in `pages` slot of `ui5-user-settings-item`
and controls the visibility of the back button.
        */
  @InputDecorator({ transform: booleanAttribute })
  secondary!: boolean;

  private elementRef: ElementRef<UserSettingsView> = inject(ElementRef);
  private zone = inject(NgZone);
  private cdr = inject(ChangeDetectorRef);

  get element(): UserSettingsView {
    return this.elementRef.nativeElement;
  }

  constructor() {
    this.cdr.detach();
  }
}
export { UserSettingsViewComponent };
