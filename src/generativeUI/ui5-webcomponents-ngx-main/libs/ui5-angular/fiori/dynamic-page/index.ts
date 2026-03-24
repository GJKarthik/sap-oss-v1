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
import '@ui5/webcomponents-fiori/dist/DynamicPage.js';
import DynamicPage from '@ui5/webcomponents-fiori/dist/DynamicPage.js';
import { ProxyInputs, ProxyOutputs } from '@ui5/webcomponents-ngx/utils';
@ProxyInputs(['hidePinButton', 'headerPinned', 'showFooter', 'headerSnapped'])
@ProxyOutputs([
  'pin-button-toggle: ui5PinButtonToggle',
  'title-toggle: ui5TitleToggle',
])
@Component({
  standalone: true,
  selector: 'ui5-dynamic-page',
  template: '<ng-content></ng-content>',
  inputs: ['hidePinButton', 'headerPinned', 'showFooter', 'headerSnapped'],
  outputs: ['ui5PinButtonToggle', 'ui5TitleToggle'],
  exportAs: 'ui5DynamicPage',
})
class DynamicPageComponent {
  /**
        Defines if the pin button is hidden.
        */
  @InputDecorator({ transform: booleanAttribute })
  hidePinButton!: boolean;
  /**
        Defines if the header is pinned.
        */
  @InputDecorator({ transform: booleanAttribute })
  headerPinned!: boolean;
  /**
        Defines if the footer is shown.
        */
  @InputDecorator({ transform: booleanAttribute })
  showFooter!: boolean;
  /**
        Defines if the header is snapped.
        */
  @InputDecorator({ transform: booleanAttribute })
  headerSnapped!: boolean;

  /**
     Fired when the pin header button is toggled.
    */
  ui5PinButtonToggle!: EventEmitter<void>;
  /**
     Fired when the expand/collapse area of the title is toggled.
    */
  ui5TitleToggle!: EventEmitter<void>;

  private elementRef: ElementRef<DynamicPage> = inject(ElementRef);
  private zone = inject(NgZone);
  private cdr = inject(ChangeDetectorRef);

  get element(): DynamicPage {
    return this.elementRef.nativeElement;
  }

  constructor() {
    this.cdr.detach();
  }
}
export { DynamicPageComponent };
