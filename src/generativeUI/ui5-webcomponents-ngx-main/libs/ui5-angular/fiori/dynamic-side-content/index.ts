import {
  ChangeDetectorRef,
  Component,
  ElementRef,
  EventEmitter,
  Input as InputDecorator,
  NgZone,
  booleanAttribute,
  inject,
} from '@angular/core';
import '@ui5/webcomponents-fiori/dist/DynamicSideContent.js';
import {
  default as DynamicSideContent,
  DynamicSideContentAccessibilityAttributes,
  DynamicSideContentLayoutChangeEventDetail,
} from '@ui5/webcomponents-fiori/dist/DynamicSideContent.js';
import { ProxyInputs, ProxyOutputs } from '@ui5/webcomponents-ngx/utils';
@ProxyInputs([
  'hideMainContent',
  'hideSideContent',
  'sideContentPosition',
  'sideContentVisibility',
  'sideContentFallDown',
  'equalSplit',
  'accessibilityAttributes',
])
@ProxyOutputs(['layout-change: ui5LayoutChange'])
@Component({
  standalone: true,
  selector: 'ui5-dynamic-side-content',
  template: '<ng-content></ng-content>',
  inputs: [
    'hideMainContent',
    'hideSideContent',
    'sideContentPosition',
    'sideContentVisibility',
    'sideContentFallDown',
    'equalSplit',
    'accessibilityAttributes',
  ],
  outputs: ['ui5LayoutChange'],
  exportAs: 'ui5DynamicSideContent',
})
class DynamicSideContentComponent {
  /**
        Defines the visibility of the main content.
        */
  @InputDecorator({ transform: booleanAttribute })
  hideMainContent!: boolean;
  /**
        Defines the visibility of the side content.
        */
  @InputDecorator({ transform: booleanAttribute })
  hideSideContent!: boolean;
  /**
        Defines whether the side content is positioned before the main content (left side
in LTR mode), or after the the main content (right side in LTR mode).
        */
  sideContentPosition!: 'End' | 'Start';
  /**
        Defines on which breakpoints the side content is visible.
        */
  sideContentVisibility!:
    | 'AlwaysShow'
    | 'ShowAboveL'
    | 'ShowAboveM'
    | 'ShowAboveS'
    | 'NeverShow';
  /**
        Defines on which breakpoints the side content falls down below the main content.
        */
  sideContentFallDown!: 'BelowXL' | 'BelowL' | 'BelowM' | 'OnMinimumWidth';
  /**
        Defines whether the component is in equal split mode. In this mode, the side and
the main content take 50:50 percent of the container on all screen sizes
except for phone, where the main and side contents are switching visibility
using the toggle method.
        */
  @InputDecorator({ transform: booleanAttribute })
  equalSplit!: boolean;
  /**
        Defines additional accessibility attributes on different areas of the component.

The accessibilityAttributes object has the following fields:

 - **mainContent**: `mainContent.ariaLabel` defines the aria-label of the main content area. Accepts any string.
 - **sideContent**: `sideContent.ariaLabel` defines the aria-label of the side content area. Accepts any string.
        */
  accessibilityAttributes!: DynamicSideContentAccessibilityAttributes;

  /**
     Fires when the current breakpoint has been changed.
    */
  ui5LayoutChange!: EventEmitter<DynamicSideContentLayoutChangeEventDetail>;

  private elementRef: ElementRef<DynamicSideContent> = inject(ElementRef);
  private zone = inject(NgZone);
  private cdr = inject(ChangeDetectorRef);

  get element(): DynamicSideContent {
    return this.elementRef.nativeElement;
  }

  constructor() {
    this.cdr.detach();
  }
}
export { DynamicSideContentComponent };
