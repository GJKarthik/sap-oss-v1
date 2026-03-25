import { Component, Input, ChangeDetectionStrategy } from '@angular/core';
import { CommonModule } from '@angular/common';

/**
 * Loading skeleton component for better UX during data fetching.
 * Provides animated placeholder content matching SAP Fiori design.
 */
@Component({
  selector: 'app-skeleton',
  standalone: true,
  imports: [CommonModule],
  changeDetection: ChangeDetectionStrategy.OnPush,
  template: `
    <div 
      class="skeleton"
      [class.skeleton--text]="type === 'text'"
      [class.skeleton--avatar]="type === 'avatar'"
      [class.skeleton--card]="type === 'card'"
      [class.skeleton--table-row]="type === 'table-row'"
      [class.skeleton--stat]="type === 'stat'"
      [style.width]="width"
      [style.height]="height"
      [attr.aria-hidden]="true"
      role="presentation"
    >
      @if (type === 'card') {
        <div class="skeleton-card-header"></div>
        <div class="skeleton-card-body">
          <div class="skeleton-line skeleton-line--title"></div>
          <div class="skeleton-line skeleton-line--text"></div>
          <div class="skeleton-line skeleton-line--text skeleton-line--short"></div>
        </div>
      }
      @if (type === 'table-row') {
        @for (col of [1,2,3,4,5]; track col) {
          <div class="skeleton-cell"></div>
        }
      }
      @if (type === 'stat') {
        <div class="skeleton-stat-value"></div>
        <div class="skeleton-stat-label"></div>
      }
    </div>
  `,
  styles: [`
    .skeleton {
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

    .skeleton--text {
      height: 1rem;
      width: 100%;
    }

    .skeleton--avatar {
      width: 3rem;
      height: 3rem;
      border-radius: 50%;
    }

    .skeleton--card {
      background: var(--sapTile_Background, #fff);
      border: 1px solid var(--sapTile_BorderColor, #e4e4e4);
      border-radius: 0.5rem;
      padding: 1rem;
      min-height: 120px;
    }

    .skeleton-card-header {
      height: 0.75rem;
      width: 30%;
      background: var(--sapList_Background, #f5f5f5);
      border-radius: 0.25rem;
      margin-bottom: 1rem;
    }

    .skeleton-card-body {
      display: flex;
      flex-direction: column;
      gap: 0.5rem;
    }

    .skeleton-line {
      height: 0.75rem;
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

    .skeleton-line--title {
      width: 60%;
      height: 1rem;
    }

    .skeleton-line--text {
      width: 100%;
    }

    .skeleton-line--short {
      width: 70%;
    }

    .skeleton--table-row {
      display: flex;
      gap: 1rem;
      padding: 0.75rem 1rem;
      border-bottom: 1px solid var(--sapList_BorderColor, #e4e4e4);
    }

    .skeleton-cell {
      flex: 1;
      height: 1rem;
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

    .skeleton--stat {
      display: flex;
      flex-direction: column;
      align-items: center;
      gap: 0.5rem;
      padding: 1rem;
      background: var(--sapTile_Background, #fff);
      border: 1px solid var(--sapTile_BorderColor, #e4e4e4);
      border-radius: 0.5rem;
    }

    .skeleton-stat-value {
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

    .skeleton-stat-label {
      height: 0.75rem;
      width: 6rem;
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
export class SkeletonComponent {
  @Input() type: 'text' | 'avatar' | 'card' | 'table-row' | 'stat' = 'text';
  @Input() width: string = '100%';
  @Input() height: string = '';
}