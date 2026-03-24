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
import '@ui5/webcomponents/dist/Tag.js';
import Tag from '@ui5/webcomponents/dist/Tag.js';
@ProxyInputs([
  'design',
  'colorScheme',
  'hideStateIcon',
  'interactive',
  'wrappingType',
  'size',
])
@ProxyOutputs(['click: ui5Click'])
@Component({
  standalone: true,
  selector: 'ui5-tag',
  template: '<ng-content></ng-content>',
  inputs: [
    'design',
    'colorScheme',
    'hideStateIcon',
    'interactive',
    'wrappingType',
    'size',
  ],
  outputs: ['ui5Click'],
  exportAs: 'ui5Tag',
})
class TagComponent {
  /**
        Defines the design type of the component.
        */
  design!:
    | 'Set1'
    | 'Set2'
    | 'Neutral'
    | 'Information'
    | 'Positive'
    | 'Negative'
    | 'Critical';
  /**
        Defines the color scheme of the component.
There are 10 predefined schemes.
To use one you can set a number from `"1"` to `"10"`. The `colorScheme` `"1"` will be set by default.
        */
  colorScheme!: string;
  /**
        Defines if the default state icon is shown.
        */
  @InputDecorator({ transform: booleanAttribute })
  hideStateIcon!: boolean;
  /**
        Defines if the component is interactive (focusable and pressable).
        */
  @InputDecorator({ transform: booleanAttribute })
  interactive!: boolean;
  /**
        Defines how the text of a component will be displayed when there is not enough space.

**Note:** For option "Normal" the text will wrap and the
words will not be broken based on hyphenation.
        */
  wrappingType!: 'None' | 'Normal';
  /**
        Defines predefined size of the component.
        */
  size!: 'S' | 'L';

  /**
     Fired when the user clicks on an interactive tag.

**Note:** The event will be fired if the `interactive` property is `true`
    */
  ui5Click!: EventEmitter<void>;

  private elementRef: ElementRef<Tag> = inject(ElementRef);
  private zone = inject(NgZone);
  private cdr = inject(ChangeDetectorRef);

  get element(): Tag {
    return this.elementRef.nativeElement;
  }

  constructor() {
    this.cdr.detach();
  }
}
export { TagComponent };
