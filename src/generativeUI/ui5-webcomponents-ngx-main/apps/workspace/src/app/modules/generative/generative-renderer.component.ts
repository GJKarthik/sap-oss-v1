import { Component, Input } from '@angular/core';

export interface GenerativeNode {
  type: string;
  props?: Record<string, any>;
  content?: string;
  children?: GenerativeNode[];
  intent?: { action: string; payload?: any };
}

@Component({
  selector: 'app-generative-renderer',
  template: `
    <app-generative-node-builder [node]="node"></app-generative-node-builder>
  `,
  standalone: false
})
export class GenerativeRendererComponent {
  @Input() node!: GenerativeNode;
}
