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
import '@ui5/webcomponents-fiori/dist/MediaGallery.js';
import {
  default as MediaGallery,
  MediaGallerySelectionChangeEventDetail,
} from '@ui5/webcomponents-fiori/dist/MediaGallery.js';
import { ProxyInputs, ProxyOutputs } from '@ui5/webcomponents-ngx/utils';
@ProxyInputs([
  'showAllThumbnails',
  'interactiveDisplayArea',
  'layout',
  'menuHorizontalAlign',
  'menuVerticalAlign',
])
@ProxyOutputs([
  'selection-change: ui5SelectionChange',
  'overflow-click: ui5OverflowClick',
  'display-area-click: ui5DisplayAreaClick',
])
@Component({
  standalone: true,
  selector: 'ui5-media-gallery',
  template: '<ng-content></ng-content>',
  inputs: [
    'showAllThumbnails',
    'interactiveDisplayArea',
    'layout',
    'menuHorizontalAlign',
    'menuVerticalAlign',
  ],
  outputs: ['ui5SelectionChange', 'ui5OverflowClick', 'ui5DisplayAreaClick'],
  exportAs: 'ui5MediaGallery',
})
class MediaGalleryComponent {
  /**
        If set to `true`, all thumbnails are rendered in a scrollable container.
If `false`, only up to five thumbnails are rendered, followed by
an overflow button that shows the count of the remaining thumbnails.
        */
  @InputDecorator({ transform: booleanAttribute })
  showAllThumbnails!: boolean;
  /**
        If enabled, a `display-area-click` event is fired
when the user clicks or taps on the display area.

The display area is the central area that contains
the enlarged content of the currently selected item.
        */
  @InputDecorator({ transform: booleanAttribute })
  interactiveDisplayArea!: boolean;
  /**
        Determines the layout of the component.
        */
  layout!: 'Auto' | 'Vertical' | 'Horizontal';
  /**
        Determines the horizontal alignment of the thumbnails menu
vs. the central display area.
        */
  menuHorizontalAlign!: 'Left' | 'Right';
  /**
        Determines the vertical alignment of the thumbnails menu
vs. the central display area.
        */
  menuVerticalAlign!: 'Top' | 'Bottom';

  /**
     Fired when selection is changed by user interaction.
    */
  ui5SelectionChange!: EventEmitter<MediaGallerySelectionChangeEventDetail>;
  /**
     Fired when the thumbnails overflow button is clicked.
    */
  ui5OverflowClick!: EventEmitter<void>;
  /**
     Fired when the display area is clicked.
The display area is the central area that contains
the enlarged content of the currently selected item.
    */
  ui5DisplayAreaClick!: EventEmitter<void>;

  private elementRef: ElementRef<MediaGallery> = inject(ElementRef);
  private zone = inject(NgZone);
  private cdr = inject(ChangeDetectorRef);

  get element(): MediaGallery {
    return this.elementRef.nativeElement;
  }

  constructor() {
    this.cdr.detach();
  }
}
export { MediaGalleryComponent };
