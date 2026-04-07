import { Component, Input, ChangeDetectionStrategy, CUSTOM_ELEMENTS_SCHEMA } from '@angular/core';
import { CommonModule } from '@angular/common';

export type StageStatus = 'idle' | 'running' | 'done' | 'error';

export interface FlowStage {
  num: number;
  name: string;
  status: StageStatus;
}

@Component({
  selector: 'app-pipeline-flow',
  standalone: true,
  imports: [CommonModule],
  schemas: [CUSTOM_ELEMENTS_SCHEMA],
  changeDetection: ChangeDetectionStrategy.OnPush,
  template: `
    <div class="flow-container">
      <svg [attr.viewBox]="'0 0 ' + svgWidth + ' 170'" class="flow-svg" preserveAspectRatio="xMidYMid meet">
        <defs>
          <!-- Glow filter for active elements -->
          <filter id="glowBlue" x="-50%" y="-50%" width="200%" height="200%">
            <feGaussianBlur stdDeviation="4" result="blur" />
            <feFlood flood-color="var(--sapBrandColor, #0a6ed1)" flood-opacity="0.6" />
            <feComposite in2="blur" operator="in" />
            <feMerge><feMergeNode /><feMergeNode in="SourceGraphic" /></feMerge>
          </filter>
          <filter id="glowGreen" x="-50%" y="-50%" width="200%" height="200%">
            <feGaussianBlur stdDeviation="3" result="blur" />
            <feFlood flood-color="var(--sapPositiveColor, #107e3e)" flood-opacity="0.4" />
            <feComposite in2="blur" operator="in" />
            <feMerge><feMergeNode /><feMergeNode in="SourceGraphic" /></feMerge>
          </filter>
          <filter id="glowRed" x="-50%" y="-50%" width="200%" height="200%">
            <feGaussianBlur stdDeviation="3" result="blur" />
            <feFlood flood-color="var(--sapNegativeColor, #bb0000)" flood-opacity="0.5" />
            <feComposite in2="blur" operator="in" />
            <feMerge><feMergeNode /><feMergeNode in="SourceGraphic" /></feMerge>
          </filter>
          <!-- Gradient for active connectors -->
          <linearGradient id="activeGrad" x1="0%" y1="0%" x2="100%" y2="0%">
            <stop offset="0%" stop-color="var(--sapBrandColor, #0a6ed1)" stop-opacity="0.3" />
            <stop offset="50%" stop-color="var(--sapBrandColor, #0a6ed1)" stop-opacity="1" />
            <stop offset="100%" stop-color="var(--sapBrandColor, #0a6ed1)" stop-opacity="0.3" />
          </linearGradient>
          <!-- Arrowhead -->
          <marker id="flowArrow" markerWidth="8" markerHeight="6" refX="7" refY="3" orient="auto">
            <path d="M0,0 L8,3 L0,6 Z" fill="var(--sapList_BorderColor, #d9d9d9)" />
          </marker>
          <marker id="flowArrowDone" markerWidth="8" markerHeight="6" refX="7" refY="3" orient="auto">
            <path d="M0,0 L8,3 L0,6 Z" fill="var(--sapPositiveColor, #2e7d32)" />
          </marker>
          <marker id="flowArrowActive" markerWidth="8" markerHeight="6" refX="7" refY="3" orient="auto">
            <path d="M0,0 L8,3 L0,6 Z" fill="var(--sapBrandColor, #0a6ed1)" />
          </marker>
        </defs>

        <!-- Connection Lines (bezier curves) -->
        @for (s of stages; track s.num; let i = $index) {
          @if (i < stages.length - 1) {
            <!-- Shadow line for depth -->
            <path
              [attr.d]="getBezierPath(i)"
              class="connector-shadow"
              [class.connector-shadow--active]="isConnectorActive(i)"
            />
            <!-- Main connector -->
            <path
              [attr.d]="getBezierPath(i)"
              class="connector-line"
              [class.connector-line--active]="isConnectorActive(i)"
              [class.connector-line--done]="isConnectorDone(i)"
              [attr.marker-end]="isConnectorDone(i) ? 'url(#flowArrowDone)' : isConnectorActive(i) ? 'url(#flowArrowActive)' : 'url(#flowArrow)'"
            />
            <!-- Animated particle on active connector -->
            @if (isConnectorActive(i)) {
              <circle r="4" class="data-pulse">
                <animateMotion [attr.path]="getBezierPath(i)" dur="1.2s" repeatCount="indefinite" />
              </circle>
              <circle r="2" class="data-pulse-trail">
                <animateMotion [attr.path]="getBezierPath(i)" dur="1.2s" repeatCount="indefinite" begin="0.15s" />
              </circle>
            }
          }
        }

        <!-- Stage Nodes -->
        @for (s of stages; track s.num; let i = $index) {
          <g [attr.transform]="'translate(' + getX(i) + ', 80)'" class="node-group">
            <!-- Outer ring glow for active -->
            @if (s.status === 'running') {
              <circle r="32" class="node-aura" />
            }

            <!-- Node background circle -->
            <circle
              r="26"
              class="node-circle"
              [class.node--idle]="s.status === 'idle'"
              [class.node--running]="s.status === 'running'"
              [class.node--done]="s.status === 'done'"
              [class.node--error]="s.status === 'error'"
              [attr.filter]="s.status === 'running' ? 'url(#glowBlue)' : s.status === 'done' ? 'url(#glowGreen)' : s.status === 'error' ? 'url(#glowRed)' : null"
            />

            <!-- Inner accent ring -->
            <circle r="20" class="node-inner"
              [class.node-inner--running]="s.status === 'running'"
              [class.node-inner--done]="s.status === 'done'"
              [class.node-inner--error]="s.status === 'error'"
            />

            <!-- Node content -->
            @if (s.status === 'done') {
              <text y="6" x="0" text-anchor="middle" class="node-check">&#xe05b;</text>
            } @else if (s.status === 'error') {
              <text y="6" x="0" text-anchor="middle" class="node-error-icon">&#xe0b1;</text>
            } @else {
              <text y="6" x="0" text-anchor="middle" class="node-num" [class.node-num--active]="s.status === 'running'">{{ s.num }}</text>
            }

            <!-- Progress ring for running -->
            @if (s.status === 'running') {
              <circle r="30" class="progress-ring" />
            }

            <!-- Label -->
            <text y="50" x="0" text-anchor="middle" class="node-label" [class.node-label--active]="s.status === 'running'" [class.node-label--done]="s.status === 'done'">{{ s.name }}</text>
          </g>
        }
      </svg>
    </div>
  `,
  styles: [`
    .flow-container {
      width: 100%;
      padding: 2rem 1rem;
      border-radius: 0.75rem;
      background: linear-gradient(180deg, var(--sapTile_Background, #fff) 0%, color-mix(in srgb, var(--sapBackgroundColor, #f5f6f7) 60%, white) 100%);
      border: 1px solid var(--sapTile_BorderColor, #e4e4e4);
      box-shadow: 0 2px 8px rgba(0, 0, 0, 0.04), 0 0 1px rgba(0, 0, 0, 0.08);
      overflow: hidden;
    }
    .flow-svg { width: 100%; height: auto; overflow: visible; }

    /* Connector lines */
    .connector-shadow { fill: none; stroke: rgba(0,0,0,0.04); stroke-width: 6; stroke-linecap: round; }
    .connector-shadow--active { stroke: rgba(8, 84, 160, 0.08); stroke-width: 8; }

    .connector-line {
      fill: none;
      stroke: var(--sapList_BorderColor, #d9d9d9);
      stroke-width: 2.5;
      stroke-linecap: round;
      transition: stroke 0.4s, stroke-width 0.4s;
    }
    .connector-line--done { stroke: var(--sapPositiveColor, #2e7d32); stroke-width: 3; }
    .connector-line--active {
      stroke: var(--sapBrandColor, #0854a0);
      stroke-width: 3;
      stroke-dasharray: 8 4;
      animation: dashFlow 0.8s linear infinite;
    }

    /* Animated particles */
    .data-pulse {
      fill: var(--sapBrandColor, #0a6ed1);
      filter: url(#glowBlue);
      opacity: 0.9;
    }
    .data-pulse-trail {
      fill: var(--sapBrandColor, #0a6ed1);
      opacity: 0.4;
    }

    /* Node circles */
    .node-circle {
      fill: var(--sapBaseColor, #fff);
      stroke: var(--sapList_BorderColor, #d9d9d9);
      stroke-width: 2;
      transition: all 0.4s cubic-bezier(0.4, 0, 0.2, 1);
    }
    .node--idle { fill: var(--sapBaseColor, #fff); stroke: var(--sapList_BorderColor, #d9d9d9); }
    .node--running { fill: color-mix(in srgb, var(--sapBrandColor) 8%, white); stroke: var(--sapBrandColor, #0854a0); stroke-width: 3; }
    .node--done { fill: color-mix(in srgb, var(--sapPositiveColor) 10%, white); stroke: var(--sapPositiveColor, #2e7d32); stroke-width: 2.5; }
    .node--error { fill: color-mix(in srgb, var(--sapNegativeColor) 8%, white); stroke: var(--sapNegativeColor, #c62828); stroke-width: 2.5; }

    /* Inner accent ring */
    .node-inner { fill: none; stroke: transparent; stroke-width: 1; transition: stroke 0.3s; }
    .node-inner--running { stroke: var(--sapBrandColor, #0854a0); stroke-opacity: 0.3; }
    .node-inner--done { stroke: var(--sapPositiveColor, #2e7d32); stroke-opacity: 0.2; }
    .node-inner--error { stroke: var(--sapNegativeColor, #c62828); stroke-opacity: 0.2; }

    /* Aura glow behind running node */
    .node-aura {
      fill: none;
      stroke: var(--sapBrandColor, #0a6ed1);
      stroke-width: 2;
      stroke-opacity: 0.15;
      animation: auraExpand 2s ease-in-out infinite;
    }

    /* Text content */
    .node-num { font-size: 15px; font-weight: 700; fill: var(--sapContent_LabelColor); }
    .node-num--active { fill: var(--sapBrandColor); }
    .node-check { font-family: 'SAP-icons'; font-size: 18px; fill: var(--sapPositiveColor); }
    .node-error-icon { font-family: 'SAP-icons'; font-size: 18px; fill: var(--sapNegativeColor); }
    .node-label { font-size: 11px; font-weight: 600; fill: var(--sapContent_LabelColor); text-transform: uppercase; letter-spacing: 0.02em; transition: fill 0.3s; }
    .node-label--active { fill: var(--sapBrandColor); font-weight: 700; }
    .node-label--done { fill: var(--sapPositiveColor); }

    /* Progress ring */
    .progress-ring {
      fill: none;
      stroke: var(--sapBrandColor);
      stroke-width: 2;
      stroke-dasharray: 12 8;
      animation: ringRotate 2s linear infinite;
      transform-origin: center;
    }

    /* Animations */
    @keyframes dashFlow { to { stroke-dashoffset: -12; } }
    @keyframes ringRotate { from { transform: rotate(0deg); } to { transform: rotate(360deg); } }
    @keyframes auraExpand {
      0%, 100% { r: 32; stroke-opacity: 0.15; }
      50% { r: 36; stroke-opacity: 0.05; }
    }

    @media (prefers-reduced-motion: reduce) {
      .connector-line--active { animation: none; }
      .progress-ring { animation: none; }
      .node-aura { animation: none; }
      .data-pulse, .data-pulse-trail { display: none; }
    }
  `]
})
export class PipelineFlowComponent {
  @Input() stages: FlowStage[] = [];

  get svgWidth(): number {
    return Math.max(800, this.stages.length * 130 + 80);
  }

  getX(index: number): number {
    const spacing = this.svgWidth / (this.stages.length + 1);
    return (index + 1) * spacing;
  }

  getBezierPath(index: number): string {
    const x1 = this.getX(index) + 28;
    const x2 = this.getX(index + 1) - 28;
    const y = 80;
    const cx = (x1 + x2) / 2;
    // Subtle wave: even connectors curve up, odd curve down
    const cy = y + (index % 2 === 0 ? -12 : 12);
    return `M ${x1} ${y} Q ${cx} ${cy} ${x2} ${y}`;
  }

  isConnectorActive(index: number): boolean {
    return this.stages[index].status === 'running' ||
           (this.stages[index].status === 'done' && this.stages[index + 1].status === 'running');
  }

  isConnectorDone(index: number): boolean {
    return this.stages[index].status === 'done' && this.stages[index + 1].status === 'done';
  }
}
