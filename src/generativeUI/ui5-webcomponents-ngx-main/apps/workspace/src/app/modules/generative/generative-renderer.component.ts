import { Component, Input } from '@angular/core';
import { GenerativeNodeBuilderComponent } from './generative-node-builder.component';

export interface GenerativeNode {
  type: string;
  props?: Record<string, any>;
  content?: string;
  children?: GenerativeNode[];
  intent?: { action: string; payload?: any };
}

@Component({
  selector: 'app-generative-renderer',
  imports: [GenerativeNodeBuilderComponent],
  template: `
    <app-generative-node-builder [node]="node"></app-generative-node-builder>
  `,
  standalone: true
})
export class GenerativeRendererComponent {
  @Input() node!: GenerativeNode;
}
