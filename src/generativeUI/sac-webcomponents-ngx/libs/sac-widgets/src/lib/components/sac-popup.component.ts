/**
 * SAC Popup Component — Modal dialog container
 *
 * Selector: sac-popup (derived from mangle/sac_widget.mg)
 * Wraps Popup from sap-sac-webcomponents-ts/src/widgets.
 */

import {
  Component,
  Input,
  Output,
  EventEmitter,
  ChangeDetectionStrategy,
} from '@angular/core';

@Component({
  selector: 'sac-popup',
  template: `
    <div class="sac-popup-overlay" *ngIf="open" [class.sac-popup--modal]="modal"
         (click)="onOverlayClick($event)">
      <div class="sac-popup" [class]="cssClass" (click)="$event.stopPropagation()">
        <div class="sac-popup__header" *ngIf="title">
          <h3 class="sac-popup__title">{{ title }}</h3>
          <button class="sac-popup__close" (click)="close()">&times;</button>
        </div>
        <div class="sac-popup__content">
          <ng-content></ng-content>
        </div>
        <div class="sac-popup__footer" *ngIf="showFooter">
          <ng-content select="[sacPopupFooter]"></ng-content>
        </div>
      </div>
    </div>
  `,
  styles: [`
    .sac-popup-overlay {
      position: fixed;
      top: 0; left: 0; right: 0; bottom: 0;
      display: flex;
      align-items: center;
      justify-content: center;
      z-index: 1000;
    }
    .sac-popup--modal {
      background: rgba(0,0,0,0.4);
    }
    .sac-popup {
      background: #fff;
      border-radius: 8px;
      box-shadow: 0 4px 24px rgba(0,0,0,0.15);
      min-width: 320px;
      max-width: 90vw;
      max-height: 90vh;
      overflow: auto;
    }
    .sac-popup__header {
      display: flex;
      align-items: center;
      justify-content: space-between;
      padding: 12px 16px;
      border-bottom: 1px solid #e0e0e0;
    }
    .sac-popup__title {
      margin: 0;
      font-size: 16px;
      font-weight: 600;
    }
    .sac-popup__close {
      border: none;
      background: none;
      font-size: 20px;
      cursor: pointer;
      color: #666;
      padding: 0 4px;
    }
    .sac-popup__content {
      padding: 16px;
    }
    .sac-popup__footer {
      padding: 12px 16px;
      border-top: 1px solid #e0e0e0;
      display: flex;
      justify-content: flex-end;
      gap: 8px;
    }
  `],
  changeDetection: ChangeDetectionStrategy.OnPush,
})
export class SacPopupComponent {
  @Input() open = false;
  @Input() modal = true;
  @Input() title = '';
  @Input() cssClass = '';
  @Input() showFooter = false;

  @Output() onOpen = new EventEmitter<string>();
  @Output() onClose = new EventEmitter<string>();

  close(): void {
    this.open = false;
    this.onClose.emit(this.title);
  }

  onOverlayClick(event: MouseEvent): void {
    if (this.modal) {
      this.close();
    }
  }
}
