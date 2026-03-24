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
import { ProxyInputs, ProxyOutputs } from '@ui5/webcomponents-ngx/utils';
import '@ui5/webcomponents/dist/Carousel.js';
import {
  default as Carousel,
  CarouselNavigateEventDetail,
} from '@ui5/webcomponents/dist/Carousel.js';
@ProxyInputs([
  'accessibleName',
  'accessibleNameRef',
  'cyclic',
  'itemsPerPage',
  'hideNavigationArrows',
  'hidePageIndicator',
  'pageIndicatorType',
  'backgroundDesign',
  'pageIndicatorBackgroundDesign',
  'pageIndicatorBorderDesign',
  'arrowsPlacement',
])
@ProxyOutputs(['navigate: ui5Navigate'])
@Component({
  standalone: true,
  selector: 'ui5-carousel',
  template: '<ng-content></ng-content>',
  inputs: [
    'accessibleName',
    'accessibleNameRef',
    'cyclic',
    'itemsPerPage',
    'hideNavigationArrows',
    'hidePageIndicator',
    'pageIndicatorType',
    'backgroundDesign',
    'pageIndicatorBackgroundDesign',
    'pageIndicatorBorderDesign',
    'arrowsPlacement',
  ],
  outputs: ['ui5Navigate'],
  exportAs: 'ui5Carousel',
})
class CarouselComponent {
  /**
        Defines the accessible name of the component.
        */
  accessibleName!: string | undefined;
  /**
        Defines the IDs of the elements that label the input.
        */
  accessibleNameRef!: string | undefined;
  /**
        Defines whether the carousel should loop, i.e show the first page after the last page is reached and vice versa.
        */
  @InputDecorator({ transform: booleanAttribute })
  cyclic!: boolean;
  /**
        Defines the number of items per page depending on the carousel width.

- 'S' for screens smaller than 600 pixels.
- 'M' for screens greater than or equal to 600 pixels and smaller than 1024 pixels.
- 'L' for screens greater than or equal to 1024 pixels and smaller than 1440 pixels.
- 'XL' for screens greater than or equal to 1440 pixels.

One item per page is shown by default.
        */
  itemsPerPage!: string;
  /**
        Defines the visibility of the navigation arrows.
If set to true the navigation arrows will be hidden.
        */
  @InputDecorator({ transform: booleanAttribute })
  hideNavigationArrows!: boolean;
  /**
        Defines the visibility of the page indicator.
If set to true the page indicator will be hidden.
        */
  @InputDecorator({ transform: booleanAttribute })
  hidePageIndicator!: boolean;
  /**
        Defines the style of the page indicator.
Available options are:

- `Default` - The page indicator will be visualized as dots if there are fewer than 9 pages. If there are more pages, the page indicator will switch to displaying the current page and the total number of pages. (e.g. X of Y)
- `Numeric` - The page indicator will display the current page and the total number of pages. (e.g. X of Y)
        */
  pageIndicatorType!: 'Default' | 'Numeric';
  /**
        Defines the carousel's background design.
        */
  backgroundDesign!: 'Solid' | 'Transparent' | 'Translucent';
  /**
        Defines the page indicator background design.
        */
  pageIndicatorBackgroundDesign!: 'Solid' | 'Transparent' | 'Translucent';
  /**
        Defines the page indicator border design.
        */
  pageIndicatorBorderDesign!: 'Solid' | 'None';
  /**
        Defines the position of arrows.

Available options are:

- `Content` - the arrows are placed on the sides of the current page.
- `Navigation` - the arrows are placed on the sides of the page indicator.
        */
  arrowsPlacement!: 'Content' | 'Navigation';

  /**
     Fired whenever the page changes due to user interaction,
when the user clicks on the navigation arrows or while resizing,
based on the `items-per-page` property.
    */
  ui5Navigate!: EventEmitter<CarouselNavigateEventDetail>;

  private elementRef: ElementRef<Carousel> = inject(ElementRef);
  private zone = inject(NgZone);
  private cdr = inject(ChangeDetectorRef);

  get element(): Carousel {
    return this.elementRef.nativeElement;
  }

  constructor() {
    this.cdr.detach();
  }
}
export { CarouselComponent };
