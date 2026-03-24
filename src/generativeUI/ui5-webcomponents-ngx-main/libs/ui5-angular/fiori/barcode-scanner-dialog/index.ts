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
import '@ui5/webcomponents-fiori/dist/BarcodeScannerDialog.js';
import {
  default as BarcodeScannerDialog,
  BarcodeScannerDialogScanErrorEventDetail,
  BarcodeScannerDialogScanSuccessEventDetail,
} from '@ui5/webcomponents-fiori/dist/BarcodeScannerDialog.js';
import { ProxyInputs, ProxyOutputs } from '@ui5/webcomponents-ngx/utils';
@ProxyInputs(['open'])
@ProxyOutputs([
  'close: ui5Close',
  'scan-success: ui5ScanSuccess',
  'scan-error: ui5ScanError',
])
@Component({
  standalone: true,
  selector: 'ui5-barcode-scanner-dialog',
  template: '<ng-content></ng-content>',
  inputs: ['open'],
  outputs: ['ui5Close', 'ui5ScanSuccess', 'ui5ScanError'],
  exportAs: 'ui5BarcodeScannerDialog',
})
class BarcodeScannerDialogComponent {
  /**
        Indicates whether the dialog is open.
        */
  @InputDecorator({ transform: booleanAttribute })
  open!: boolean;

  /**
     Fired when the user closes the component.
    */
  ui5Close!: EventEmitter<void>;
  /**
     Fires when the scan is completed successfuuly.
    */
  ui5ScanSuccess!: EventEmitter<BarcodeScannerDialogScanSuccessEventDetail>;
  /**
     Fires when the scan fails with error.
    */
  ui5ScanError!: EventEmitter<BarcodeScannerDialogScanErrorEventDetail>;

  private elementRef: ElementRef<BarcodeScannerDialog> = inject(ElementRef);
  private zone = inject(NgZone);
  private cdr = inject(ChangeDetectorRef);

  get element(): BarcodeScannerDialog {
    return this.elementRef.nativeElement;
  }

  constructor() {
    this.cdr.detach();
  }
}
export { BarcodeScannerDialogComponent };
