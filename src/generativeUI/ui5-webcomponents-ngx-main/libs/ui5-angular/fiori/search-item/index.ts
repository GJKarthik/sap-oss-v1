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
import '@ui5/webcomponents-fiori/dist/SearchItem.js';
import SearchItem from '@ui5/webcomponents-fiori/dist/SearchItem.js';
import { ProxyInputs, ProxyOutputs } from '@ui5/webcomponents-ngx/utils';
@ProxyInputs([
  'text',
  'description',
  'icon',
  'selected',
  'deletable',
  'scopeName',
])
@ProxyOutputs(['delete: ui5Delete'])
@Component({
  standalone: true,
  selector: 'ui5-search-item',
  template: '<ng-content></ng-content>',
  inputs: ['text', 'description', 'icon', 'selected', 'deletable', 'scopeName'],
  outputs: ['ui5Delete'],
  exportAs: 'ui5SearchItem',
})
class SearchItemComponent {
  /**
        Defines the heading text of the search item.
        */
  text!: string | undefined;
  /**
        Defines the description that appears right under the item text, if available.
        */
  description!: string | undefined;
  /**
        Defines the icon name of the search item.
**Note:** If provided, the image slot will be ignored.
        */
  icon!: string | undefined;
  /**
        Defines whether the search item is selected.
        */
  @InputDecorator({ transform: booleanAttribute })
  selected!: boolean;
  /**
        Defines whether the search item is deletable.
        */
  @InputDecorator({ transform: booleanAttribute })
  deletable!: boolean;
  /**
        Defines the scope of the search item
        */
  scopeName!: string | undefined;

  /**
     Fired when delete button is pressed.
    */
  ui5Delete!: EventEmitter<void>;

  private elementRef: ElementRef<SearchItem> = inject(ElementRef);
  private zone = inject(NgZone);
  private cdr = inject(ChangeDetectorRef);

  get element(): SearchItem {
    return this.elementRef.nativeElement;
  }

  constructor() {
    this.cdr.detach();
  }
}
export { SearchItemComponent };
