/**
 * SAC PageBook Component — Multi-page container
 *
 * Selector: sac-pagebook (derived from mangle/sac_widget.mg)
 * Wraps PageBook + PageBookPage from sap-sac-webcomponents-ts/src/widgets.
 */

import {
  Component,
  Input,
  Output,
  EventEmitter,
  ChangeDetectionStrategy,
} from '@angular/core';

@Component({
  selector: 'sac-pagebook',
  template: `
    <div class="sac-pagebook" [class]="cssClass" [style.display]="visible ? 'block' : 'none'">
      <div class="sac-pagebook__nav" *ngIf="showNav">
        <button *ngFor="let page of pages; let i = index"
                class="sac-pagebook__nav-item"
                [class.sac-pagebook__nav-item--active]="selectedKey === page.key"
                (click)="selectPage(page.key)">
          {{ page.label || 'Page ' + (i + 1) }}
        </button>
      </div>
      <div class="sac-pagebook__content">
        <ng-content></ng-content>
      </div>
    </div>
  `,
  styles: [`
    .sac-pagebook__nav {
      display: flex;
      gap: 4px;
      padding: 8px;
      background: #f7f7f7;
      border-bottom: 1px solid #e0e0e0;
    }
    .sac-pagebook__nav-item {
      padding: 6px 12px;
      border: 1px solid #ccc;
      border-radius: 4px;
      background: #fff;
      cursor: pointer;
      font-size: 13px;
    }
    .sac-pagebook__nav-item--active {
      background: #0854a0;
      color: #fff;
      border-color: #0854a0;
    }
    .sac-pagebook__content {
      padding: 12px;
    }
  `],
  changeDetection: ChangeDetectionStrategy.OnPush,
})
export class SacPageBookComponent {
  @Input() visible = true;
  @Input() cssClass = '';
  @Input() selectedKey = '';
  @Input() showNav = true;
  @Input() pages: Array<{ key: string; label?: string }> = [];

  @Output() onPageChange = new EventEmitter<string>();

  selectPage(key: string): void {
    this.selectedKey = key;
    this.onPageChange.emit(key);
  }
}
