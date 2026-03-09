/**
 * SAC TabStrip Component — Tabbed navigation container
 *
 * Selector: sac-tabstrip (derived from mangle/sac_widget.mg)
 * Wraps TabStrip + Tab from sap-sac-webcomponents-ts/src/widgets.
 */

import {
  Component,
  Input,
  Output,
  EventEmitter,
  ChangeDetectionStrategy,
} from '@angular/core';

@Component({
  selector: 'sac-tabstrip',
  template: `
    <div class="sac-tabstrip" [class]="cssClass" [style.display]="visible ? 'block' : 'none'">
      <div class="sac-tabstrip__tabs">
        <button *ngFor="let tab of tabs; let i = index"
                class="sac-tabstrip__tab"
                [class.sac-tabstrip__tab--active]="selectedKey === tab.key"
                (click)="selectTab(tab.key, i)">
          {{ tab.text }}
        </button>
      </div>
      <div class="sac-tabstrip__content">
        <ng-content></ng-content>
      </div>
    </div>
  `,
  styles: [`
    .sac-tabstrip__tabs {
      display: flex;
      border-bottom: 2px solid #e0e0e0;
    }
    .sac-tabstrip__tab {
      padding: 8px 16px;
      border: none;
      background: none;
      cursor: pointer;
      font-size: 14px;
      color: #666;
      border-bottom: 2px solid transparent;
      margin-bottom: -2px;
      transition: all 0.2s;
    }
    .sac-tabstrip__tab--active {
      color: #0854a0;
      border-bottom-color: #0854a0;
      font-weight: 600;
    }
    .sac-tabstrip__content {
      padding: 12px 0;
    }
  `],
  changeDetection: ChangeDetectionStrategy.OnPush,
})
export class SacTabStripComponent {
  @Input() visible = true;
  @Input() cssClass = '';
  @Input() selectedKey = '';
  @Input() tabs: Array<{ key: string; text: string }> = [];

  @Output() onSelect = new EventEmitter<{ tabIndex: number; tabId: string }>();

  selectTab(key: string, index: number): void {
    this.selectedKey = key;
    this.onSelect.emit({ tabIndex: index, tabId: key });
  }
}
