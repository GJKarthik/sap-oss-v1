/**
 * Confirmation Dialog Component
 * 
 * A reusable confirmation dialog for destructive actions.
 * Uses UI5 Dialog with proper accessibility attributes.
 */

import { Component, EventEmitter, Input, Output, ViewChild, ElementRef } from '@angular/core';
import { CommonModule } from '@angular/common';
import { Ui5WebcomponentsModule } from '@ui5/webcomponents-ngx';

export interface ConfirmationDialogData {
  title: string;
  message: string;
  confirmText?: string;
  cancelText?: string;
  confirmDesign?: 'Emphasized' | 'Negative' | 'Positive' | 'Transparent' | 'Default';
  icon?: string;
  itemName?: string;
}

@Component({
  selector: 'app-confirmation-dialog',
  standalone: true,
  imports: [CommonModule, Ui5WebcomponentsModule],
  template: `
    <ui5-dialog
      #dialog
      [headerText]="data.title"
      [state]="getDialogState()"
      [attr.aria-labelledby]="'dialog-title-' + dialogId"
      [attr.aria-describedby]="'dialog-message-' + dialogId"
      (after-close)="onDialogClose($event)">
      
      <div class="dialog-content">
        <div class="dialog-icon" *ngIf="data.icon">
          <ui5-icon [name]="data.icon" class="warning-icon"></ui5-icon>
        </div>
        
        <div class="dialog-message" [id]="'dialog-message-' + dialogId">
          <p>{{ data.message }}</p>
          <p *ngIf="data.itemName" class="item-name">
            <strong>{{ data.itemName }}</strong>
          </p>
        </div>
      </div>
      
      <div slot="footer" class="dialog-footer">
        <ui5-button 
          design="Transparent" 
          (click)="cancel()"
          class="footer-button">
          {{ data.cancelText || 'Cancel' }}
        </ui5-button>
        <ui5-button 
          [design]="data.confirmDesign || 'Negative'" 
          (click)="confirm()"
          class="footer-button"
          #confirmButton>
          {{ data.confirmText || 'Confirm' }}
        </ui5-button>
      </div>
    </ui5-dialog>
  `,
  styles: [`
    .dialog-content {
      display: flex;
      align-items: flex-start;
      gap: 1rem;
      padding: 1rem;
      min-width: 300px;
      max-width: 500px;
    }
    
    .dialog-icon {
      flex-shrink: 0;
    }
    
    .warning-icon {
      font-size: 2rem;
      color: var(--sapCriticalColor, #e9730c);
    }
    
    .dialog-message {
      flex: 1;
    }
    
    .dialog-message p {
      margin: 0 0 0.5rem 0;
      line-height: 1.5;
    }
    
    .dialog-message p:last-child {
      margin-bottom: 0;
    }
    
    .item-name {
      color: var(--sapContent_LabelColor);
      word-break: break-word;
    }
    
    .dialog-footer {
      display: flex;
      justify-content: flex-end;
      gap: 0.5rem;
      padding: 0.5rem 1rem;
      border-top: 1px solid var(--sapList_BorderColor);
      width: 100%;
    }
    
    .footer-button {
      min-width: 80px;
    }
  `]
})
export class ConfirmationDialogComponent {
  @Input() data: ConfirmationDialogData = {
    title: 'Confirm Action',
    message: 'Are you sure you want to proceed?'
  };
  
  @Output() confirmed = new EventEmitter<void>();
  @Output() cancelled = new EventEmitter<void>();
  
  @ViewChild('dialog') dialogRef!: ElementRef;
  @ViewChild('confirmButton') confirmButtonRef!: ElementRef;
  
  dialogId = Math.random().toString(36).substring(2, 9);
  private wasConfirmed = false;

  open(): void {
    this.wasConfirmed = false;
    const dialog = this.dialogRef?.nativeElement;
    if (dialog && typeof dialog.show === 'function') {
      dialog.show();
      // Focus the confirm button after dialog opens for accessibility
      setTimeout(() => {
        const confirmBtn = this.confirmButtonRef?.nativeElement;
        if (confirmBtn && typeof confirmBtn.focus === 'function') {
          confirmBtn.focus();
        }
      }, 100);
    }
  }

  close(): void {
    const dialog = this.dialogRef?.nativeElement;
    if (dialog && typeof dialog.close === 'function') {
      dialog.close();
    }
  }

  confirm(): void {
    this.wasConfirmed = true;
    this.close();
  }

  cancel(): void {
    this.wasConfirmed = false;
    this.close();
  }

  onDialogClose(event: Event): void {
    // Emit the appropriate event after the dialog closes
    if (this.wasConfirmed) {
      this.confirmed.emit();
    } else {
      this.cancelled.emit();
    }
  }

  getDialogState(): string {
    if (this.data.confirmDesign === 'Negative') {
      return 'Error';
    }
    if (this.data.confirmDesign === 'Positive') {
      return 'Success';
    }
    return 'Warning';
  }
}