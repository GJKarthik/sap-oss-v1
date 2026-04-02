/**
 * SAC Panel Component — Container with collapse, title, busy indicator
 *
 * Selector: sac-panel (derived from mangle/sac_widget.mg)
 * Wraps Panel from sap-sac-webcomponents-ts/src/widgets.
 */

import {
  Component,
  Input,
  Output,
  EventEmitter,
  ChangeDetectionStrategy,
} from '@angular/core';

import type { PanelCollapseEvent } from '../types/widget-events.types';

@Component({
  selector: 'sac-panel',
  template: `
    <div class="sac-panel"
         [class]="cssClass"
         [style.display]="visible ? 'block' : 'none'"
         [class.sac-panel--collapsed]="collapsed">
      <div class="sac-panel__header" *ngIf="title" (click)="toggleCollapse()">
        <h3 class="sac-panel__title">{{ title }}</h3>
        <span class="sac-panel__collapse-icon" *ngIf="collapsible">
          {{ collapsed ? '▶' : '▼' }}
        </span>
      </div>
      <div class="sac-panel__content" [style.display]="collapsed ? 'none' : 'block'">
        <ng-content></ng-content>
      </div>
      <div class="sac-panel__busy" *ngIf="busy">
        <span class="sac-panel__spinner"></span>
        <span *ngIf="busyText">{{ busyText }}</span>
      </div>
    </div>
  `,
  styles: [`
    .sac-panel {
      position: relative;
      border: 1px solid #e0e0e0;
      border-radius: 4px;
      overflow: hidden;
    }
    .sac-panel__header {
      display: flex;
      align-items: center;
      justify-content: space-between;
      padding: 8px 12px;
      background: #f7f7f7;
      cursor: pointer;
      user-select: none;
    }
    .sac-panel__title {
      margin: 0;
      font-size: 14px;
      font-weight: 600;
    }
    .sac-panel__content {
      padding: 12px;
    }
    .sac-panel__busy {
      position: absolute;
      top: 0; left: 0; right: 0; bottom: 0;
      display: flex;
      align-items: center;
      justify-content: center;
      background: rgba(255,255,255,0.8);
    }
    .sac-panel__spinner {
      width: 24px;
      height: 24px;
      border: 3px solid #f3f3f3;
      border-top: 3px solid #0854a0;
      border-radius: 50%;
      animation: sac-spin 1s linear infinite;
    }
    @keyframes sac-spin {
      0% { transform: rotate(0deg); }
      100% { transform: rotate(360deg); }
    }
  `],
  changeDetection: ChangeDetectionStrategy.OnPush,
})
export class SacPanelComponent {
  @Input() visible = true;
  @Input() enabled = true;
  @Input() cssClass = '';
  @Input() title = '';
  @Input() collapsible = false;
  @Input() collapsed = false;
  @Input() busy = false;
  @Input() busyText = '';

  @Output() onCollapse = new EventEmitter<PanelCollapseEvent>();

  toggleCollapse(): void {
    if (!this.collapsible) return;
    this.collapsed = !this.collapsed;
    this.onCollapse.emit({ collapsed: this.collapsed });
  }
}
