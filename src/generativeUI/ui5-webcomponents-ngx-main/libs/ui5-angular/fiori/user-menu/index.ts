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
import '@ui5/webcomponents-fiori/dist/UserMenu.js';
import {
  default as UserMenu,
  UserMenuItemClickEventDetail,
  UserMenuOtherAccountClickEventDetail,
} from '@ui5/webcomponents-fiori/dist/UserMenu.js';
import { ProxyInputs, ProxyOutputs } from '@ui5/webcomponents-ngx/utils';
@ProxyInputs([
  'open',
  'opener',
  'showManageAccount',
  'showOtherAccounts',
  'showEditAccounts',
  'showEditButton',
])
@ProxyOutputs([
  'avatar-click: ui5AvatarClick',
  'manage-account-click: ui5ManageAccountClick',
  'edit-accounts-click: ui5EditAccountsClick',
  'change-account: ui5ChangeAccount',
  'item-click: ui5ItemClick',
  'open: ui5Open',
  'close: ui5Close',
  'sign-out-click: ui5SignOutClick',
])
@Component({
  standalone: true,
  selector: 'ui5-user-menu',
  template: '<ng-content></ng-content>',
  inputs: [
    'open',
    'opener',
    'showManageAccount',
    'showOtherAccounts',
    'showEditAccounts',
    'showEditButton',
  ],
  outputs: [
    'ui5AvatarClick',
    'ui5ManageAccountClick',
    'ui5EditAccountsClick',
    'ui5ChangeAccount',
    'ui5ItemClick',
    'ui5Open',
    'ui5Close',
    'ui5SignOutClick',
  ],
  exportAs: 'ui5UserMenu',
})
class UserMenuComponent {
  /**
        Defines if the User Menu is opened.
        */
  @InputDecorator({ transform: booleanAttribute })
  open!: boolean;
  /**
        Defines the ID or DOM Reference of the element at which the user menu is shown.
When using this attribute in a declarative way, you must only use the `id` (as a string) of the element at which you want to show the popover.
You can only set the `opener` attribute to a DOM Reference when using JavaScript.
        */
  opener!: HTMLElement | string | null | undefined;
  /**
        Defines if the User Menu shows the Manage Account option.
        */
  @InputDecorator({ transform: booleanAttribute })
  showManageAccount!: boolean;
  /**
        Defines if the User Menu shows the Other Accounts option.
        */
  @InputDecorator({ transform: booleanAttribute })
  showOtherAccounts!: boolean;
  /**
        Defines if the User Menu shows the Edit Accounts option.
        */
  @InputDecorator({ transform: booleanAttribute })
  showEditAccounts!: boolean;
  /**
        Defines if the User menu shows edit button.
        */
  @InputDecorator({ transform: booleanAttribute })
  showEditButton!: boolean;

  /**
     Fired when the account avatar is selected.
    */
  ui5AvatarClick!: EventEmitter<void>;
  /**
     Fired when the "Manage Account" button is selected.
    */
  ui5ManageAccountClick!: EventEmitter<void>;
  /**
     Fired when the "Edit Accounts" button is selected.
    */
  ui5EditAccountsClick!: EventEmitter<void>;
  /**
     Fired when the account is switched to a different one.
    */
  ui5ChangeAccount!: EventEmitter<UserMenuOtherAccountClickEventDetail>;
  /**
     Fired when a menu item is selected.
    */
  ui5ItemClick!: EventEmitter<UserMenuItemClickEventDetail>;
  /**
     Fired when a user menu is open.
    */
  ui5Open!: EventEmitter<void>;
  /**
     Fired when a user menu is close.
    */
  ui5Close!: EventEmitter<void>;
  /**
     Fired when the "Sign Out" button is selected.
    */
  ui5SignOutClick!: EventEmitter<void>;

  private elementRef: ElementRef<UserMenu> = inject(ElementRef);
  private zone = inject(NgZone);
  private cdr = inject(ChangeDetectorRef);

  get element(): UserMenu {
    return this.elementRef.nativeElement;
  }

  constructor() {
    this.cdr.detach();
  }
}
export { UserMenuComponent };
