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
import '@ui5/webcomponents-fiori/dist/UserSettingsDialog.js';
import {
  default as UserSettingsDialog,
  UserSettingsItemSelectEventDetail,
} from '@ui5/webcomponents-fiori/dist/UserSettingsDialog.js';
import { ProxyInputs, ProxyOutputs } from '@ui5/webcomponents-ngx/utils';
@ProxyInputs(['open', 'headerText', 'showSearchField'])
@ProxyOutputs([
  'selection-change: ui5SelectionChange',
  'open: ui5Open',
  'before-close: ui5BeforeClose',
  'close: ui5Close',
])
@Component({
  standalone: true,
  selector: 'ui5-user-settings-dialog',
  template: '<ng-content></ng-content>',
  inputs: ['open', 'headerText', 'showSearchField'],
  outputs: ['ui5SelectionChange', 'ui5Open', 'ui5BeforeClose', 'ui5Close'],
  exportAs: 'ui5UserSettingsDialog',
})
class UserSettingsDialogComponent {
  /**
        Defines, if the User Settings Dialog is opened.
        */
  @InputDecorator({ transform: booleanAttribute })
  open!: boolean;
  /**
        Defines the headerText of the item.
        */
  headerText!: string | undefined;
  /**
        Defines if the Search Field would be displayed.

**Note:** By default the Search Field is not displayed.
        */
  @InputDecorator({ transform: booleanAttribute })
  showSearchField!: boolean;

  /**
     Fired when an item is selected.
    */
  ui5SelectionChange!: EventEmitter<UserSettingsItemSelectEventDetail>;
  /**
     Fired when a settings dialog is open.
    */
  ui5Open!: EventEmitter<void>;
  /**
     Fired before the settings dialog is closed.
    */
  ui5BeforeClose!: EventEmitter<void>;
  /**
     Fired when a settings dialog is closed.
    */
  ui5Close!: EventEmitter<void>;

  private elementRef: ElementRef<UserSettingsDialog> = inject(ElementRef);
  private zone = inject(NgZone);
  private cdr = inject(ChangeDetectorRef);

  get element(): UserSettingsDialog {
    return this.elementRef.nativeElement;
  }

  constructor() {
    this.cdr.detach();
  }
}
export { UserSettingsDialogComponent };
