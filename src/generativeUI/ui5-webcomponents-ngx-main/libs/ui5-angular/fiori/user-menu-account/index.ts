import {
  ChangeDetectorRef,
  Component,
  ElementRef,
  Input as InputDecorator,
  NgZone,
  booleanAttribute,
  inject,
} from '@angular/core';
import '@ui5/webcomponents-fiori/dist/UserMenuAccount.js';
import UserMenuAccount from '@ui5/webcomponents-fiori/dist/UserMenuAccount.js';
import { ProxyInputs } from '@ui5/webcomponents-ngx/utils';
@ProxyInputs([
  'avatarSrc',
  'avatarInitials',
  'titleText',
  'subtitleText',
  'description',
  'additionalInfo',
  'selected',
  'loading',
])
@Component({
  standalone: true,
  selector: 'ui5-user-menu-account',
  template: '<ng-content></ng-content>',
  inputs: [
    'avatarSrc',
    'avatarInitials',
    'titleText',
    'subtitleText',
    'description',
    'additionalInfo',
    'selected',
    'loading',
  ],
  exportAs: 'ui5UserMenuAccount',
})
class UserMenuAccountComponent {
  /**
        Defines the avatar image url of the user.
        */
  avatarSrc!: string | undefined;
  /**
        Defines the avatar initials of the user.
        */
  avatarInitials!: string | undefined;
  /**
        Defines the title text of the user.
        */
  titleText!: string;
  /**
        Defines additional text of the user.
        */
  subtitleText!: string;
  /**
        Defines description of the user.
        */
  description!: string;
  /**
        Defines additional information for the user.
        */
  additionalInfo!: string;
  /**
        Defines if the user is selected.
        */
  @InputDecorator({ transform: booleanAttribute })
  selected!: boolean;
  /**
        Indicates whether a loading indicator should be shown.
        */
  @InputDecorator({ transform: booleanAttribute })
  loading!: boolean;

  private elementRef: ElementRef<UserMenuAccount> = inject(ElementRef);
  private zone = inject(NgZone);
  private cdr = inject(ChangeDetectorRef);

  get element(): UserMenuAccount {
    return this.elementRef.nativeElement;
  }

  constructor() {
    this.cdr.detach();
  }
}
export { UserMenuAccountComponent };
