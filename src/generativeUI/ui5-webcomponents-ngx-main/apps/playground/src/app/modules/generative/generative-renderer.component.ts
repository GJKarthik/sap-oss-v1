import { Component, Input } from '@angular/core';

export interface GenerativeNode {
  type: string;
  props?: Record<string, any>;
  content?: string;
  children?: GenerativeNode[];
}

@Component({
  selector: 'app-generative-renderer',
  template: `
    <ng-container [ngSwitch]="node.type">
      <!-- Layout & Container Components -->
      <ui5-card *ngSwitchCase="'ui5-card'">
        <ui5-card-header slot="header" [titleText]="node.props?.['titleText'] || ''" [subtitleText]="node.props?.['subtitleText'] || ''"></ui5-card-header>
        <ng-container *ngFor="let child of node.children">
          <app-generative-renderer [node]="child"></app-generative-renderer>
        </ng-container>
      </ui5-card>

      <ui5-panel *ngSwitchCase="'ui5-panel'" [headerText]="node.props?.['headerText'] || ''" [collapsed]="node.props?.['collapsed'] || false">
        <ng-container *ngFor="let child of node.children">
          <app-generative-renderer [node]="child"></app-generative-renderer>
        </ng-container>
      </ui5-panel>

      <ui5-list *ngSwitchCase="'ui5-list'" [headerText]="node.props?.['headerText'] || ''">
        <ng-container *ngFor="let child of node.children">
          <app-generative-renderer [node]="child"></app-generative-renderer>
        </ng-container>
      </ui5-list>

      <ui5-li *ngSwitchCase="'ui5-li'" [description]="node.props?.['description'] || ''" [icon]="node.props?.['icon'] || ''">
        {{ node.content || '' }}
      </ui5-li>

      <!-- Input Controls -->
      <ui5-input *ngSwitchCase="'ui5-input'" 
        [placeholder]="node.props?.['placeholder'] || ''" 
        [value]="node.props?.['value'] || ''" 
        [readonly]="node.props?.['readonly'] || false">
      </ui5-input>

      <!-- Buttons -->
      <ui5-button *ngSwitchCase="'ui5-button'" 
        [design]="node.props?.['design'] || 'Default'" 
        [icon]="node.props?.['icon'] || ''">
        {{ node.content || 'Button' }}
      </ui5-button>

      <!-- Text / Fallback -->
      <div *ngSwitchDefault>
        <span *ngIf="node.content">{{ node.content }}</span>
        <ng-container *ngFor="let child of node.children">
          <app-generative-renderer [node]="child"></app-generative-renderer>
        </ng-container>
      </div>
    </ng-container>
  `,
  standalone: false
})
export class GenerativeRendererComponent {
  @Input() node!: GenerativeNode;
}
