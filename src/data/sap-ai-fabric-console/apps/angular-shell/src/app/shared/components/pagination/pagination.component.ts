/**
 * Pagination Component
 * 
 * A reusable pagination component following SAP Fiori guidelines.
 * Supports page navigation, page size selection, and accessibility.
 */

import { Component, EventEmitter, Input, Output, OnChanges, SimpleChanges } from '@angular/core';
import { CommonModule } from '@angular/common';
import { FormsModule } from '@angular/forms';
import { Ui5WebcomponentsModule } from '@ui5/webcomponents-ngx';

export interface PaginationState {
  page: number;
  pageSize: number;
  totalItems: number;
}

@Component({
  selector: 'app-pagination',
  standalone: true,
  imports: [CommonModule, FormsModule, Ui5WebcomponentsModule],
  template: `
    <div class="pagination-container" role="navigation" aria-label="Pagination">
      <div class="pagination-info">
        <span class="items-info" *ngIf="totalItems > 0">
          Showing {{ startItem }}-{{ endItem }} of {{ totalItems }} items
        </span>
        <span class="items-info" *ngIf="totalItems === 0">
          No items to display
        </span>
      </div>
      
      <div class="pagination-controls">
        <!-- Page Size Selector -->
        <div class="page-size-selector" *ngIf="showPageSizeSelector">
          <label for="page-size-select" class="page-size-label">Items per page:</label>
          <ui5-select 
            id="page-size-select"
            (change)="onPageSizeChange($event)"
            accessible-name="Items per page">
            <ui5-option 
              *ngFor="let size of pageSizeOptions" 
              [value]="size.toString()"
              [selected]="size === pageSize">
              {{ size }}
            </ui5-option>
          </ui5-select>
        </div>

        <!-- Page Navigation -->
        <div class="page-navigation">
          <ui5-button 
            design="Transparent" 
            icon="navigation-left-arrow"
            [disabled]="page <= 1"
            (click)="goToFirstPage()"
            aria-label="Go to first page"
            title="First page">
          </ui5-button>
          
          <ui5-button 
            design="Transparent" 
            icon="slim-arrow-left"
            [disabled]="page <= 1"
            (click)="goToPreviousPage()"
            aria-label="Go to previous page"
            title="Previous page">
          </ui5-button>
          
          <div class="page-numbers" *ngIf="showPageNumbers">
            <ui5-button 
              *ngFor="let pageNum of visiblePages"
              [design]="pageNum === page ? 'Emphasized' : 'Transparent'"
              (click)="goToPage(pageNum)"
              [attr.aria-label]="'Go to page ' + pageNum"
              [attr.aria-current]="pageNum === page ? 'page' : null"
              class="page-number-button">
              {{ pageNum }}
            </ui5-button>
          </div>
          
          <div class="page-input" *ngIf="!showPageNumbers && totalPages > 1">
            <span>Page</span>
            <ui5-input 
              type="Number"
              [value]="page.toString()"
              (change)="onPageInputChange($event)"
              accessible-name="Current page number"
              style="width: 60px;">
            </ui5-input>
            <span>of {{ totalPages }}</span>
          </div>
          
          <ui5-button 
            design="Transparent" 
            icon="slim-arrow-right"
            [disabled]="page >= totalPages"
            (click)="goToNextPage()"
            aria-label="Go to next page"
            title="Next page">
          </ui5-button>
          
          <ui5-button 
            design="Transparent" 
            icon="navigation-right-arrow"
            [disabled]="page >= totalPages"
            (click)="goToLastPage()"
            aria-label="Go to last page"
            title="Last page">
          </ui5-button>
        </div>
      </div>
    </div>
  `,
  styles: [`
    .pagination-container {
      display: flex;
      justify-content: space-between;
      align-items: center;
      padding: 0.75rem 1rem;
      border-top: 1px solid var(--sapList_BorderColor);
      background: var(--sapList_Background);
      flex-wrap: wrap;
      gap: 1rem;
    }
    
    .pagination-info {
      color: var(--sapContent_LabelColor);
      font-size: var(--sapFontSmallSize);
    }
    
    .pagination-controls {
      display: flex;
      align-items: center;
      gap: 1.5rem;
      flex-wrap: wrap;
    }
    
    .page-size-selector {
      display: flex;
      align-items: center;
      gap: 0.5rem;
    }
    
    .page-size-label {
      color: var(--sapContent_LabelColor);
      font-size: var(--sapFontSmallSize);
      white-space: nowrap;
    }
    
    .page-navigation {
      display: flex;
      align-items: center;
      gap: 0.25rem;
    }
    
    .page-numbers {
      display: flex;
      gap: 0.125rem;
    }
    
    .page-number-button {
      min-width: 32px;
    }
    
    .page-input {
      display: flex;
      align-items: center;
      gap: 0.5rem;
      color: var(--sapContent_LabelColor);
      font-size: var(--sapFontSmallSize);
    }
    
    @media (max-width: 600px) {
      .pagination-container {
        flex-direction: column;
        align-items: stretch;
      }
      
      .pagination-controls {
        justify-content: center;
      }
      
      .page-size-selector {
        display: none;
      }
    }
  `]
})
export class PaginationComponent implements OnChanges {
  @Input() page = 1;
  @Input() pageSize = 10;
  @Input() totalItems = 0;
  @Input() pageSizeOptions: number[] = [10, 25, 50, 100];
  @Input() showPageSizeSelector = true;
  @Input() showPageNumbers = true;
  @Input() maxVisiblePages = 5;
  
  @Output() pageChange = new EventEmitter<PaginationState>();
  
  totalPages = 0;
  visiblePages: number[] = [];
  startItem = 0;
  endItem = 0;

  ngOnChanges(changes: SimpleChanges): void {
    this.calculatePagination();
  }

  private calculatePagination(): void {
    this.totalPages = Math.ceil(this.totalItems / this.pageSize) || 1;
    
    // Ensure current page is valid
    if (this.page > this.totalPages) {
      this.page = this.totalPages;
    }
    if (this.page < 1) {
      this.page = 1;
    }
    
    // Calculate visible page numbers
    this.visiblePages = this.getVisiblePages();
    
    // Calculate item range
    this.startItem = this.totalItems > 0 ? (this.page - 1) * this.pageSize + 1 : 0;
    this.endItem = Math.min(this.page * this.pageSize, this.totalItems);
  }

  private getVisiblePages(): number[] {
    const pages: number[] = [];
    
    if (this.totalPages <= this.maxVisiblePages) {
      for (let i = 1; i <= this.totalPages; i++) {
        pages.push(i);
      }
    } else {
      const half = Math.floor(this.maxVisiblePages / 2);
      let start = Math.max(1, this.page - half);
      let end = Math.min(this.totalPages, start + this.maxVisiblePages - 1);
      
      if (end - start + 1 < this.maxVisiblePages) {
        start = Math.max(1, end - this.maxVisiblePages + 1);
      }
      
      for (let i = start; i <= end; i++) {
        pages.push(i);
      }
    }
    
    return pages;
  }

  private emitChange(): void {
    this.calculatePagination();
    this.pageChange.emit({
      page: this.page,
      pageSize: this.pageSize,
      totalItems: this.totalItems
    });
  }

  goToPage(pageNum: number): void {
    if (pageNum >= 1 && pageNum <= this.totalPages && pageNum !== this.page) {
      this.page = pageNum;
      this.emitChange();
    }
  }

  goToFirstPage(): void {
    this.goToPage(1);
  }

  goToLastPage(): void {
    this.goToPage(this.totalPages);
  }

  goToPreviousPage(): void {
    this.goToPage(this.page - 1);
  }

  goToNextPage(): void {
    this.goToPage(this.page + 1);
  }

  onPageSizeChange(event: Event): void {
    const select = event.target as HTMLSelectElement;
    const newPageSize = parseInt(select.value || (event as CustomEvent).detail?.selectedOption?.value, 10);
    if (newPageSize && newPageSize !== this.pageSize) {
      this.pageSize = newPageSize;
      this.page = 1; // Reset to first page when page size changes
      this.emitChange();
    }
  }

  onPageInputChange(event: Event): void {
    const input = event.target as HTMLInputElement;
    const newPage = parseInt(input.value, 10);
    if (newPage && newPage >= 1 && newPage <= this.totalPages) {
      this.goToPage(newPage);
    } else {
      // Reset to current page if invalid
      input.value = this.page.toString();
    }
  }
}