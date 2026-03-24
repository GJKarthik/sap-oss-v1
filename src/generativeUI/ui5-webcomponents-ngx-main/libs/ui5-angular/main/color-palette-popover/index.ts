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
import '@ui5/webcomponents/dist/ColorPalettePopover.js';
import {
  default as ColorPalettePopover,
  ColorPalettePopoverItemClickEventDetail,
} from '@ui5/webcomponents/dist/ColorPalettePopover.js';
@ProxyInputs([
  'showRecentColors',
  'showMoreColors',
  'showDefaultColor',
  'defaultColor',
  'open',
  'opener',
])
@ProxyOutputs(['item-click: ui5ItemClick', 'close: ui5Close'])
@Component({
  standalone: true,
  selector: 'ui5-color-palette-popover',
  template: '<ng-content></ng-content>',
  inputs: [
    'showRecentColors',
    'showMoreColors',
    'showDefaultColor',
    'defaultColor',
    'open',
    'opener',
  ],
  outputs: ['ui5ItemClick', 'ui5Close'],
  exportAs: 'ui5ColorPalettePopover',
})
class ColorPalettePopoverComponent {
  /**
        Defines whether the user can see the last used colors in the bottom of the component
        */
  @InputDecorator({ transform: booleanAttribute })
  showRecentColors!: boolean;
  /**
        Defines whether the user can choose a custom color from a component.
        */
  @InputDecorator({ transform: booleanAttribute })
  showMoreColors!: boolean;
  /**
        Defines whether the user can choose the default color from a button.
        */
  @InputDecorator({ transform: booleanAttribute })
  showDefaultColor!: boolean;
  /**
        Defines the default color of the component.

**Note:** The default color should be a part of the ColorPalette colors`
        */
  defaultColor!: string | undefined;
  /**
        Defines the open | closed state of the popover.
        */
  @InputDecorator({ transform: booleanAttribute })
  open!: boolean;
  /**
        Defines the ID or DOM Reference of the element that the popover is shown at.
When using this attribute in a declarative way, you must only use the `id` (as a string) of the element at which you want to show the popover.
You can only set the `opener` attribute to a DOM Reference when using JavaScript.
        */
  opener!: HTMLElement | string | null | undefined;

  /**
     Fired when the user selects a color.
    */
  ui5ItemClick!: EventEmitter<ColorPalettePopoverItemClickEventDetail>;
  /**
     Fired when the `ui5-color-palette-popover` is closed due to user interaction.
    */
  ui5Close!: EventEmitter<void>;

  private elementRef: ElementRef<ColorPalettePopover> = inject(ElementRef);
  private zone = inject(NgZone);
  private cdr = inject(ChangeDetectorRef);

  get element(): ColorPalettePopover {
    return this.elementRef.nativeElement;
  }

  constructor() {
    this.cdr.detach();
  }
}
export { ColorPalettePopoverComponent };
