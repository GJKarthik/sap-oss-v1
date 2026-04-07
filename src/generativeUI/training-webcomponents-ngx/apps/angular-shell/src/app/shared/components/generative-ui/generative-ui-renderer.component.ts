import {
  Component,
  ElementRef,
  EventEmitter,
  Input,
  OnChanges,
  Output,
  Renderer2,
  SimpleChanges,
  ViewChild,
  ChangeDetectionStrategy,
} from '@angular/core';
import { CommonModule } from '@angular/common';
import { GenerativeNode, UIIntent } from './generative-ui.types';

@Component({
  selector: 'app-generative-ui-renderer',
  standalone: true,
  imports: [CommonModule],
  changeDetection: ChangeDetectionStrategy.OnPush,
  template: `<div #container class="generative-container"></div>`,
  styles: [`
    .generative-container {
      display: block;
      width: 100%;
      animation: genFadeIn 0.4s cubic-bezier(0.4, 0, 0.2, 1);
    }
    @keyframes genFadeIn {
      from { opacity: 0; transform: translateY(10px); }
      to { opacity: 1; transform: translateY(0); }
    }

    /* Grid for data synthesis fragments */
    ::ng-deep .gen-ui-grid {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(140px, 1fr));
      gap: 1rem;
      margin: 1rem 0;
    }

    ::ng-deep .gen-ui-stat {
      display: flex;
      flex-direction: column;
      align-items: center;
      text-align: center;
      padding: 1rem;
      background: rgba(8, 84, 160, 0.03);
      border-radius: 0.75rem;
      border: 1px solid rgba(8, 84, 160, 0.1);
      animation: statPulseIn 0.5s cubic-bezier(0.34, 1.56, 0.64, 1) both;
    }

    ::ng-deep .gen-ui-stat:nth-child(1) { animation-delay: 0s; }
    ::ng-deep .gen-ui-stat:nth-child(2) { animation-delay: 0.08s; }
    ::ng-deep .gen-ui-stat:nth-child(3) { animation-delay: 0.16s; }
    ::ng-deep .gen-ui-stat:nth-child(4) { animation-delay: 0.24s; }
    ::ng-deep .gen-ui-stat:nth-child(5) { animation-delay: 0.32s; }
    ::ng-deep .gen-ui-stat:nth-child(6) { animation-delay: 0.40s; }

    @keyframes statPulseIn {
      from { opacity: 0; transform: scale(0.85) translateY(12px); }
      to { opacity: 1; transform: scale(1) translateY(0); }
    }

    /* Radial progress ring */
    ::ng-deep .gen-progress-ring {
      display: inline-flex;
      align-items: center;
      justify-content: center;
      position: relative;
      margin: 0.5rem auto;
    }

    ::ng-deep .gen-progress-ring svg {
      transform: rotate(-90deg);
    }

    ::ng-deep .gen-ring-bg {
      fill: none;
      stroke: rgba(0, 0, 0, 0.06);
      stroke-width: 6;
    }

    ::ng-deep .gen-ring-fill {
      fill: none;
      stroke-width: 6;
      stroke-linecap: round;
      transition: stroke-dashoffset 1s cubic-bezier(0.4, 0, 0.2, 1);
    }

    ::ng-deep .gen-ring-fill--brand { stroke: var(--sapBrandColor, #0a6ed1); }
    ::ng-deep .gen-ring-fill--positive { stroke: var(--sapPositiveColor, #107e3e); }
    ::ng-deep .gen-ring-fill--negative { stroke: var(--sapNegativeColor, #bb0000); }
    ::ng-deep .gen-ring-fill--warning { stroke: #d29922; }

    ::ng-deep .gen-ring-label {
      position: absolute;
      inset: 0;
      display: flex;
      flex-direction: column;
      align-items: center;
      justify-content: center;
      pointer-events: none;
    }

    ::ng-deep .gen-ring-value {
      font-size: 1.25rem;
      font-weight: 800;
      color: var(--sapTextColor);
      line-height: 1;
    }

    ::ng-deep .gen-ring-caption {
      font-size: 0.65rem;
      color: var(--sapContent_LabelColor);
      text-transform: uppercase;
      letter-spacing: 0.03em;
      margin-top: 2px;
    }

    /* Micro bar chart */
    ::ng-deep .gen-bar-chart {
      display: flex;
      align-items: flex-end;
      gap: 3px;
      height: 40px;
      padding: 0.5rem 0;
    }

    ::ng-deep .gen-bar {
      flex: 1;
      min-width: 6px;
      border-radius: 2px 2px 0 0;
      background: var(--sapBrandColor, #0a6ed1);
      animation: barGrow 0.6s cubic-bezier(0.34, 1.56, 0.64, 1) both;
      transform-origin: bottom;
    }

    ::ng-deep .gen-bar:nth-child(1) { animation-delay: 0s; }
    ::ng-deep .gen-bar:nth-child(2) { animation-delay: 0.05s; }
    ::ng-deep .gen-bar:nth-child(3) { animation-delay: 0.10s; }
    ::ng-deep .gen-bar:nth-child(4) { animation-delay: 0.15s; }
    ::ng-deep .gen-bar:nth-child(5) { animation-delay: 0.20s; }
    ::ng-deep .gen-bar:nth-child(6) { animation-delay: 0.25s; }
    ::ng-deep .gen-bar:nth-child(7) { animation-delay: 0.30s; }
    ::ng-deep .gen-bar:nth-child(8) { animation-delay: 0.35s; }

    @keyframes barGrow {
      from { transform: scaleY(0); opacity: 0; }
      to { transform: scaleY(1); opacity: 1; }
    }

    /* Synthesis fragment card */
    ::ng-deep .gen-synthesis {
      background: var(--glass-bg, rgba(255, 255, 255, 0.75));
      backdrop-filter: blur(8px);
      -webkit-backdrop-filter: blur(8px);
      border: 1px solid var(--glass-border, rgba(255, 255, 255, 0.3));
      border-radius: 0.75rem;
      padding: 1rem;
      box-shadow: 0 4px 16px rgba(0, 0, 0, 0.05);
      animation: synthesisFadeUp 0.5s cubic-bezier(0.4, 0, 0.2, 1);
    }

    @keyframes synthesisFadeUp {
      from { opacity: 0; transform: translateY(16px); }
      to { opacity: 1; transform: translateY(0); }
    }

    @media (prefers-reduced-motion: reduce) {
      ::ng-deep .gen-ui-stat,
      ::ng-deep .gen-bar,
      ::ng-deep .gen-synthesis,
      .generative-container { animation: none !important; }
      ::ng-deep .gen-ring-fill { transition: none; }
    }
  `]
})
export class GenerativeUiRendererComponent implements OnChanges {
  @Input() node: GenerativeNode | null = null;
  @Output() intent = new EventEmitter<UIIntent>();

  @ViewChild('container', { static: true }) containerRef!: ElementRef<HTMLDivElement>;

  constructor(private renderer: Renderer2) {}

  ngOnChanges(changes: SimpleChanges): void {
    if ((changes['node']) && this.node) {
      this.render();
    }
  }

  private render(): void {
    const container = this.containerRef.nativeElement;
    while (container.firstChild) {
      this.renderer.removeChild(container, container.firstChild);
    }
    if (!this.node) return;
    const element = this.createElement(this.node);
    if (element) {
      this.renderer.appendChild(container, element);
    }
  }

  private createElement(node: GenerativeNode): any {
    if (node.type === 'text') {
      return this.renderer.createText(node.content || '');
    }

    // Special type: radial progress ring
    if (node.type === 'gen-progress-ring') {
      return this.createProgressRing(node);
    }

    // Special type: micro bar chart
    if (node.type === 'gen-bar-chart') {
      return this.createBarChart(node);
    }

    const el = this.renderer.createElement(node.type);

    if (node.props) {
      for (const [key, value] of Object.entries(node.props)) {
        if (key === 'slot') {
          this.renderer.setAttribute(el, 'slot', String(value));
        } else if (key === 'class') {
          this.renderer.setAttribute(el, 'class', String(value));
        } else if (key === 'style') {
          this.renderer.setAttribute(el, 'style', String(value));
        } else {
          try {
            el[key] = value;
          } catch {
            this.renderer.setAttribute(el, key, String(value));
          }
        }
      }
    }

    if (node.content && node.type !== 'text') {
      const textNode = this.renderer.createText(node.content);
      this.renderer.appendChild(el, textNode);
    }

    if (node.intent) {
      const eventName = node.type.startsWith('ui5-input') ? 'input' : 'click';
      this.renderer.listen(el, eventName, (event: any) => {
        const payload = { ...node.intent?.payload };
        if (eventName === 'input') {
          payload.value = event.target.value;
        }
        this.intent.emit({
          action: node.intent!.action,
          payload: payload,
          sourceType: node.type
        });
      });
    }

    if (node.children && node.children.length > 0) {
      for (const child of node.children) {
        const childEl = this.createElement(child);
        if (childEl) {
          this.renderer.appendChild(el, childEl);
        }
      }
    }

    return el;
  }

  /**
   * Creates an SVG radial progress ring.
   * Props: value (0-100), size (px, default 72), variant (brand|positive|negative|warning), label, caption
   */
  private createProgressRing(node: GenerativeNode): HTMLElement {
    const value = Number(node.props?.['value'] ?? 0);
    const size = Number(node.props?.['size'] ?? 72);
    const variant = String(node.props?.['variant'] ?? 'brand');
    const label = String(node.props?.['label'] ?? `${value}%`);
    const caption = node.props?.['caption'] ? String(node.props['caption']) : '';

    const r = (size - 12) / 2;
    const circumference = 2 * Math.PI * r;
    const offset = circumference - (value / 100) * circumference;

    const wrapper = this.renderer.createElement('div');
    this.renderer.addClass(wrapper, 'gen-progress-ring');
    this.renderer.setStyle(wrapper, 'width', `${size}px`);
    this.renderer.setStyle(wrapper, 'height', `${size}px`);

    const svgNS = 'http://www.w3.org/2000/svg';
    const svg = document.createElementNS(svgNS, 'svg');
    svg.setAttribute('width', String(size));
    svg.setAttribute('height', String(size));
    svg.setAttribute('viewBox', `0 0 ${size} ${size}`);

    const bgCircle = document.createElementNS(svgNS, 'circle');
    bgCircle.setAttribute('cx', String(size / 2));
    bgCircle.setAttribute('cy', String(size / 2));
    bgCircle.setAttribute('r', String(r));
    bgCircle.setAttribute('class', 'gen-ring-bg');
    svg.appendChild(bgCircle);

    const fillCircle = document.createElementNS(svgNS, 'circle');
    fillCircle.setAttribute('cx', String(size / 2));
    fillCircle.setAttribute('cy', String(size / 2));
    fillCircle.setAttribute('r', String(r));
    fillCircle.setAttribute('class', `gen-ring-fill gen-ring-fill--${variant}`);
    fillCircle.setAttribute('stroke-dasharray', String(circumference));
    fillCircle.setAttribute('stroke-dashoffset', String(offset));
    svg.appendChild(fillCircle);

    wrapper.appendChild(svg);

    const labelDiv = this.renderer.createElement('div');
    this.renderer.addClass(labelDiv, 'gen-ring-label');

    const valueSpan = this.renderer.createElement('span');
    this.renderer.addClass(valueSpan, 'gen-ring-value');
    this.renderer.appendChild(valueSpan, this.renderer.createText(label));
    this.renderer.appendChild(labelDiv, valueSpan);

    if (caption) {
      const captionSpan = this.renderer.createElement('span');
      this.renderer.addClass(captionSpan, 'gen-ring-caption');
      this.renderer.appendChild(captionSpan, this.renderer.createText(caption));
      this.renderer.appendChild(labelDiv, captionSpan);
    }

    this.renderer.appendChild(wrapper, labelDiv);
    return wrapper;
  }

  /**
   * Creates a micro bar chart.
   * Props: values (number[]), maxHeight (px, default 40), color (CSS color)
   */
  private createBarChart(node: GenerativeNode): HTMLElement {
    const values: number[] = node.props?.['values'] ?? [];
    const maxHeight = Number(node.props?.['maxHeight'] ?? 40);
    const color = node.props?.['color'] ? String(node.props['color']) : undefined;

    const wrapper = this.renderer.createElement('div');
    this.renderer.addClass(wrapper, 'gen-bar-chart');
    this.renderer.setStyle(wrapper, 'height', `${maxHeight}px`);

    const maxVal = Math.max(...values, 1);
    for (const val of values) {
      const bar = this.renderer.createElement('div');
      this.renderer.addClass(bar, 'gen-bar');
      const pct = (val / maxVal) * 100;
      this.renderer.setStyle(bar, 'height', `${Math.max(pct, 4)}%`);
      if (color) {
        this.renderer.setStyle(bar, 'background', color);
      }
      this.renderer.appendChild(wrapper, bar);
    }

    return wrapper;
  }
}
