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
import '@ui5/webcomponents-fiori/dist/ViewSettingsDialog.js';
import {
  default as ViewSettingsDialog,
  ViewSettingsDialogCancelEventDetail,
  ViewSettingsDialogConfirmEventDetail,
} from '@ui5/webcomponents-fiori/dist/ViewSettingsDialog.js';
import { ProxyInputs, ProxyOutputs } from '@ui5/webcomponents-ngx/utils';
@ProxyInputs(['sortDescending', 'groupDescending', 'open'])
@ProxyOutputs([
  'confirm: ui5Confirm',
  'cancel: ui5Cancel',
  'before-open: ui5BeforeOpen',
  'open: ui5Open',
  'close: ui5Close',
])
@Component({
  standalone: true,
  selector: 'ui5-view-settings-dialog',
  template: '<ng-content></ng-content>',
  inputs: ['sortDescending', 'groupDescending', 'open'],
  outputs: ['ui5Confirm', 'ui5Cancel', 'ui5BeforeOpen', 'ui5Open', 'ui5Close'],
  exportAs: 'ui5ViewSettingsDialog',
})
class ViewSettingsDialogComponent {
  /**
        Defines the initial sort order.
        */
  @InputDecorator({ transform: booleanAttribute })
  sortDescending!: boolean;
  /**
        Defines the initial group order.
        */
  @InputDecorator({ transform: booleanAttribute })
  groupDescending!: boolean;
  /**
        Indicates if the dialog is open.
        */
  @InputDecorator({ transform: booleanAttribute })
  open!: boolean;

  /**
     Fired when confirmation button is activated.
    */
  ui5Confirm!: EventEmitter<ViewSettingsDialogConfirmEventDetail>;
  /**
     Fired when cancel button is activated.
    */
  ui5Cancel!: EventEmitter<ViewSettingsDialogCancelEventDetail>;
  /**
     Fired before the component is opened.
    */
  ui5BeforeOpen!: EventEmitter<void>;
  /**
     Fired after the dialog is opened.
    */
  ui5Open!: EventEmitter<void>;
  /**
     Fired after the dialog is closed.
    */
  ui5Close!: EventEmitter<void>;

  private elementRef: ElementRef<ViewSettingsDialog> = inject(ElementRef);
  private zone = inject(NgZone);
  private cdr = inject(ChangeDetectorRef);

  get element(): ViewSettingsDialog {
    return this.elementRef.nativeElement;
  }

  constructor() {
    this.cdr.detach();
  }
}
export { ViewSettingsDialogComponent };
