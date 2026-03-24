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
import '@ui5/webcomponents/dist/SegmentedButton.js';
import {
  default as SegmentedButton,
  SegmentedButtonSelectionChangeEventDetail,
} from '@ui5/webcomponents/dist/SegmentedButton.js';
@ProxyInputs([
  'accessibleName',
  'accessibleNameRef',
  'accessibleDescription',
  'accessibleDescriptionRef',
  'selectionMode',
  'itemsFitContent',
])
@ProxyOutputs(['selection-change: ui5SelectionChange'])
@Component({
  standalone: true,
  selector: 'ui5-segmented-button',
  template: '<ng-content></ng-content>',
  inputs: [
    'accessibleName',
    'accessibleNameRef',
    'accessibleDescription',
    'accessibleDescriptionRef',
    'selectionMode',
    'itemsFitContent',
  ],
  outputs: ['ui5SelectionChange'],
  exportAs: 'ui5SegmentedButton',
})
class SegmentedButtonComponent {
  /**
        Defines the accessible ARIA name of the component.
        */
  accessibleName!: string | undefined;
  /**
        Defines the IDs of the HTML Elements that label the component.
        */
  accessibleNameRef!: string | undefined;
  /**
        Defines the accessible description of the component.
        */
  accessibleDescription!: string | undefined;
  /**
        Defines the IDs of the HTML Elements that describe the component.
        */
  accessibleDescriptionRef!: string | undefined;
  /**
        Defines the component selection mode.
        */
  selectionMode!: 'Single' | 'Multiple';
  /**
        Determines whether the segmented button items should be sized to fit their content.

If set to `true`, each item will be sized to fit its content, with any extra space distributed after the last item.
If set to `false` (the default), all items will be equally sized to fill the available space.
        */
  @InputDecorator({ transform: booleanAttribute })
  itemsFitContent!: boolean;

  /**
     Fired when the selected item changes.
    */
  ui5SelectionChange!: EventEmitter<SegmentedButtonSelectionChangeEventDetail>;

  private elementRef: ElementRef<SegmentedButton> = inject(ElementRef);
  private zone = inject(NgZone);
  private cdr = inject(ChangeDetectorRef);

  get element(): SegmentedButton {
    return this.elementRef.nativeElement;
  }

  constructor() {
    this.cdr.detach();
  }
}
export { SegmentedButtonComponent };
