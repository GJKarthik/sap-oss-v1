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
import '@ui5/webcomponents-fiori/dist/SearchItemShowMore.js';
import {
  default as SearchItemShowMore,
  ShowMoreItemClickEventDetail,
} from '@ui5/webcomponents-fiori/dist/SearchItemShowMore.js';
import { ProxyInputs, ProxyOutputs } from '@ui5/webcomponents-ngx/utils';
@ProxyInputs(['itemsToShowCount', 'selected'])
@ProxyOutputs(['click: ui5Click'])
@Component({
  standalone: true,
  selector: 'ui5-search-item-show-more',
  template: '<ng-content></ng-content>',
  inputs: ['itemsToShowCount', 'selected'],
  outputs: ['ui5Click'],
  exportAs: 'ui5SearchItemShowMore',
})
class SearchItemShowMoreComponent {
  /**
        Specifies the number of additional items available to show.
If no value is defined, the control shows "Show more" (without any counter).
If a number is provided, it displays "Show more (N)", where N is that number.
        */
  itemsToShowCount!: number | undefined;
  /**
        Defines whether the show more item is selected.
        */
  @InputDecorator({ transform: booleanAttribute })
  selected!: boolean;

  /**
     Fired when the component is activated, either with a mouse/tap
or by pressing the Enter or Space keys.
    */
  ui5Click!: EventEmitter<ShowMoreItemClickEventDetail>;

  private elementRef: ElementRef<SearchItemShowMore> = inject(ElementRef);
  private zone = inject(NgZone);
  private cdr = inject(ChangeDetectorRef);

  get element(): SearchItemShowMore {
    return this.elementRef.nativeElement;
  }

  constructor() {
    this.cdr.detach();
  }
}
export { SearchItemShowMoreComponent };
