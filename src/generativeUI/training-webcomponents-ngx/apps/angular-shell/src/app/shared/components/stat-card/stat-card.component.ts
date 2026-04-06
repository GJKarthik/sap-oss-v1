import { Component, Input, ChangeDetectionStrategy } from '@angular/core';
import { CommonModule } from '@angular/common';

/**
 * Reusable stat card component for displaying key metrics.
 * Supports loading state, custom badges, and content projection.
 */
@Component({
  selector: 'app-stat-card',
  standalone: true,
  imports: [CommonModule],
  changeDetection: ChangeDetectionStrategy.OnPush,
  template: `
    <div 
      class="stat-card"
      [class.stat-card--loading]="loading"
      [class.stat-card--clickable]="clickable"
      role="article"
      [attr.aria-label]="label + ': ' + (loading ? 'Loading' : value)"
      [attr.aria-busy]="loading"
    >
      @if (loading) {
        <div class="stat-skeleton">
          <div class="stat-skeleton-value"></div>
          <div class="stat-skeleton-label"></div>
        </div>
      } @else {
        <div class="stat-value" [class]="valueClass">
          @if (badge) {
            <span class="status-badge" [class]="badge">{{ value }}</span>
          } @else {
            {{ value }}
          }
        </div>
        <div class="stat-label">{{ label }}</div>
        @if (sublabel) {
          <div class="stat-sublabel">{{ sublabel }}</div>
        }
        <ng-content></ng-content>
      }
    </div>
  `,
  styles: [`
    .stat-card {
      background: var(--sapTile_Background, #fff);
      border: 1px solid var(--sapTile_BorderColor, #e4e4e4);
      border-radius: 0.5rem;
      padding: 1.25rem;
      text-align: center;
      min-height: 90px;
      display: flex;
      flex-direction: column;
      justify-content: center;
      transition: box-shadow 0.15s, border-color 0.15s;
    }

    .stat-card--clickable {
      cursor: pointer;

      &:hover {
        border-color: var(--sapBrandColor, #0854a0);
        box-shadow: 0 2px 8px rgba(0, 0, 0, 0.08);
      }

      &:focus-visible {
        outline: 2px solid var(--sapBrandColor, #0854a0);
        outline-offset: 2px;
      }
    }

    .stat-card--loading {
      pointer-events: none;
    }

    .stat-value {
      font-size: 1.75rem;
      font-weight: 700;
      color: var(--sapTextColor, #32363a);
      line-height: 1.2;
    }

    .stat-label {
      font-size: 0.8125rem;
      color: var(--sapContent_LabelColor, #6a6d70);
      margin-top: 0.25rem;
    }

    .stat-sublabel {
      font-size: 0.7rem;
      color: var(--sapContent_LabelColor, #6a6d70);
      margin-top: 0.25rem;
    }

    .stat-skeleton {
      display: flex;
      flex-direction: column;
      align-items: center;
      gap: 0.5rem;
    }

    .stat-skeleton-value {
      height: 2rem;
      width: 4rem;
      background: linear-gradient(
        90deg,
        var(--sapList_Background, #f5f5f5) 0%,
        var(--sapBackgroundColor, #fafafa) 50%,
        var(--sapList_Background, #f5f5f5) 100%
      );
      background-size: 200% 100%;
      animation: shimmer 1.5s infinite ease-in-out;
      border-radius: 0.25rem;
    }

    .stat-skeleton-label {
      height: 0.75rem;
      width: 5rem;
      background: linear-gradient(
        90deg,
        var(--sapList_Background, #f5f5f5) 0%,
        var(--sapBackgroundColor, #fafafa) 50%,
        var(--sapList_Background, #f5f5f5) 100%
      );
      background-size: 200% 100%;
      animation: shimmer 1.5s infinite ease-in-out;
      border-radius: 0.25rem;
    }

    @keyframes shimmer {
      0% { background-position: 200% 0; }
      100% { background-position: -200% 0; }
    }
  `],
})
export class StatCardComponent {
  @Input() value: string | number = '';
  @Input() label = '';
  @Input() sublabel = '';
  @Input() loading = false;
  @Input() clickable = false;
  @Input() badge = '';
  @Input() valueClass = '';
}
