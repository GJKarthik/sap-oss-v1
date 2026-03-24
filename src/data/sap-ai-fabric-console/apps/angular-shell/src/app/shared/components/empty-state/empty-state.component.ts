/**
 * Empty State Component
 * 
 * A reusable component for displaying consistent empty states across the application.
 * Supports customizable icons, titles, descriptions, and optional action buttons.
 */

import { Component, EventEmitter, Input, Output } from '@angular/core';
import { CommonModule } from '@angular/common';
import { Ui5WebcomponentsModule } from '@ui5/webcomponents-ngx';

@Component({
  selector: 'app-empty-state',
  standalone: true,
  imports: [CommonModule, Ui5WebcomponentsModule],
  template: `
    <div class="empty-state" role="status" [attr.aria-label]="title">
      <div class="empty-state-icon" *ngIf="icon">
        <ui5-icon [name]="icon" aria-hidden="true"></ui5-icon>
      </div>
      
      <h3 class="empty-state-title" *ngIf="title">{{ title }}</h3>
      
      <p class="empty-state-description" *ngIf="description">{{ description }}</p>
      
      <div class="empty-state-action" *ngIf="actionText">
        <ui5-button 
          [design]="actionDesign" 
          [icon]="actionIcon"
          (click)="actionClicked.emit()">
          {{ actionText }}
        </ui5-button>
      </div>
      
      <ng-content></ng-content>
    </div>
  `,
  styles: [`
    .empty-state {
      display: flex;
      flex-direction: column;
      align-items: center;
      justify-content: center;
      padding: 2rem 1rem;
      text-align: center;
      min-height: 200px;
    }
    
    .empty-state-icon {
      margin-bottom: 1rem;
    }
    
    .empty-state-icon ui5-icon {
      font-size: 3rem;
      color: var(--sapContent_IllustratedMessageNeutral, var(--sapContent_LabelColor));
    }
    
    .empty-state-title {
      margin: 0 0 0.5rem 0;
      font-size: var(--sapFontHeader4Size, 1.125rem);
      font-weight: 600;
      color: var(--sapTextColor);
    }
    
    .empty-state-description {
      margin: 0 0 1rem 0;
      font-size: var(--sapFontSize);
      color: var(--sapContent_LabelColor);
      max-width: 400px;
      line-height: 1.5;
    }
    
    .empty-state-action {
      margin-top: 0.5rem;
    }
  `]
})
export class EmptyStateComponent {
  @Input() icon = 'document';
  @Input() title = '';
  @Input() description = '';
  @Input() actionText = '';
  @Input() actionIcon = '';
  @Input() actionDesign: 'Emphasized' | 'Default' | 'Positive' | 'Negative' | 'Transparent' = 'Emphasized';
  
  @Output() actionClicked = new EventEmitter<void>();
}