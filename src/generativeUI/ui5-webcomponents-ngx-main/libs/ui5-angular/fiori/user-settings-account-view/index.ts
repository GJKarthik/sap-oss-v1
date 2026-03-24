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
import '@ui5/webcomponents-fiori/dist/UserSettingsAccountView.js';
import UserSettingsAccountView from '@ui5/webcomponents-fiori/dist/UserSettingsAccountView.js';
import { ProxyInputs, ProxyOutputs } from '@ui5/webcomponents-ngx/utils';
@ProxyInputs(['text', 'selected', 'secondary', 'showManageAccount'])
@ProxyOutputs([
  'edit-accounts-click: ui5EditAccountsClick',
  'manage-account-click: ui5ManageAccountClick',
])
@Component({
  standalone: true,
  selector: 'ui5-user-settings-account-view',
  template: '<ng-content></ng-content>',
  inputs: ['text', 'selected', 'secondary', 'showManageAccount'],
  outputs: ['ui5EditAccountsClick', 'ui5ManageAccountClick'],
  exportAs: 'ui5UserSettingsAccountView',
})
class UserSettingsAccountViewComponent {
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
  /**
        Defines if the User Menu shows the `Manage Account` option.
        */
  @InputDecorator({ transform: booleanAttribute })
  showManageAccount!: boolean;

  /**
     Fired when the `Edit Accounts` button is selected.
    */
  ui5EditAccountsClick!: EventEmitter<void>;
  /**
     Fired when the `Manage Account` button is selected.
    */
  ui5ManageAccountClick!: EventEmitter<void>;

  private elementRef: ElementRef<UserSettingsAccountView> = inject(ElementRef);
  private zone = inject(NgZone);
  private cdr = inject(ChangeDetectorRef);

  get element(): UserSettingsAccountView {
    return this.elementRef.nativeElement;
  }

  constructor() {
    this.cdr.detach();
  }
}
export { UserSettingsAccountViewComponent };
