import {
  ChangeDetectorRef,
  Component,
  ElementRef,
  Input as InputDecorator,
  NgZone,
  booleanAttribute,
  inject,
} from '@angular/core';
import '@ui5/webcomponents-fiori/dist/MediaGalleryItem.js';
import MediaGalleryItem from '@ui5/webcomponents-fiori/dist/MediaGalleryItem.js';
import { ProxyInputs } from '@ui5/webcomponents-ngx/utils';
@ProxyInputs(['selected', 'disabled', 'layout'])
@Component({
  standalone: true,
  selector: 'ui5-media-gallery-item',
  template: '<ng-content></ng-content>',
  inputs: ['selected', 'disabled', 'layout'],
  exportAs: 'ui5MediaGalleryItem',
})
class MediaGalleryItemComponent {
  /**
        Defines the selected state of the component.
        */
  @InputDecorator({ transform: booleanAttribute })
  selected!: boolean;
  /**
        Defines whether the component is in disabled state.
        */
  @InputDecorator({ transform: booleanAttribute })
  disabled!: boolean;
  /**
        Determines the layout of the item container.
        */
  layout!: 'Square' | 'Wide';

  private elementRef: ElementRef<MediaGalleryItem> = inject(ElementRef);
  private zone = inject(NgZone);
  private cdr = inject(ChangeDetectorRef);

  get element(): MediaGalleryItem {
    return this.elementRef.nativeElement;
  }

  constructor() {
    this.cdr.detach();
  }
}
export { MediaGalleryItemComponent };
