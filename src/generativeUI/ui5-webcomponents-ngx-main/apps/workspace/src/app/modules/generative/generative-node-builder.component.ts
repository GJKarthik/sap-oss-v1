import { Component, ElementRef, Input, OnChanges, Renderer2, SimpleChanges } from '@angular/core';
import { GenerativeNode } from './generative-renderer.component';
import { GenerativeIntentService } from './generative-intent.service';

@Component({
  selector: 'app-generative-node-builder',
  template: '',
  standalone: false
})
export class GenerativeNodeBuilderComponent implements OnChanges {
  @Input() node!: GenerativeNode;

  constructor(
    private el: ElementRef, 
    private renderer: Renderer2,
    private intentService: GenerativeIntentService
  ) {}

  ngOnChanges(changes: SimpleChanges): void {
    if (changes['node'] && this.node) {
      this.buildDom();
    }
  }

  private buildDom() {
    // Clear previous
    const nativeEl = this.el.nativeElement;
    while (nativeEl.firstChild) {
      this.renderer.removeChild(nativeEl, nativeEl.firstChild);
    }
    
    // Build new tree using Renderer2 natively handling Custom Elements (ui5-*)
    const root = this.createElement(this.node);
    if (root) {
      this.renderer.appendChild(nativeEl, root);
    }
  }

  private createElement(node: GenerativeNode): any {
    // Basic text node
    if (node.type === 'text') {
      return this.renderer.createText(node.content || '');
    }

    // Custom UI5 Element
    const el = this.renderer.createElement(node.type);

    // Apply Props
    if (node.props) {
      for (const [key, value] of Object.entries(node.props)) {
        if (key === 'slot') {
          this.renderer.setAttribute(el, 'slot', String(value));
        } else {
          // ui5 web components map props to kebab-case attributes or direct DOM properties
          el[key] = value;
        }
      }
    }

    // Apply state bubbling (Intents)
    if (node.intent) {
      // Listen to generic click or UI5 specific events
      const eventName = node.type.startsWith('ui5-input') ? 'input' : 'click';
      this.renderer.listen(el, eventName, (event: any) => {
        // If it's an input, snag the value into the payload dynamically
        const payload = { ...node.intent?.payload };
        if (eventName === 'input') {
          payload.value = event.target.value;
        }
        
        this.intentService.dispatch({
          action: node.intent!.action,
          payload: payload,
          sourceType: node.type
        });
      });
    }

    // Text content shorthand for buttons/labels
    if (node.content && node.type !== 'text') {
      const textNode = this.renderer.createText(node.content);
      this.renderer.appendChild(el, textNode);
    }

    // Recursively append children
    if (node.children && node.children.length > 0) {
      for (const childNode of node.children) {
        const childEl = this.createElement(childNode);
        if (childEl) {
          this.renderer.appendChild(el, childEl);
        }
      }
    }

    return el;
  }
}
