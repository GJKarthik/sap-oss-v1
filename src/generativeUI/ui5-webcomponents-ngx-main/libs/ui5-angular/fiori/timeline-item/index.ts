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
import '@ui5/webcomponents-fiori/dist/TimelineItem.js';
import TimelineItem from '@ui5/webcomponents-fiori/dist/TimelineItem.js';
import { ProxyInputs, ProxyOutputs } from '@ui5/webcomponents-ngx/utils';
@ProxyInputs([
  'icon',
  'name',
  'nameClickable',
  'titleText',
  'subtitleText',
  'state',
])
@ProxyOutputs(['name-click: ui5NameClick'])
@Component({
  standalone: true,
  selector: 'ui5-timeline-item',
  template: '<ng-content></ng-content>',
  inputs: [
    'icon',
    'name',
    'nameClickable',
    'titleText',
    'subtitleText',
    'state',
  ],
  outputs: ['ui5NameClick'],
  exportAs: 'ui5TimelineItem',
})
class TimelineItemComponent {
  /**
        Defines the icon to be displayed as graphical element within the `ui5-timeline-item`.
SAP-icons font provides numerous options.

See all the available icons in the [Icon Explorer](https://sdk.openui5.org/test-resources/sap/m/demokit/iconExplorer/webapp/index.html).
        */
  icon!: string | undefined;
  /**
        Defines the name of the item, displayed before the `title-text`.
        */
  name!: string | undefined;
  /**
        Defines if the `name` is clickable.
        */
  @InputDecorator({ transform: booleanAttribute })
  nameClickable!: boolean;
  /**
        Defines the title text of the component.
        */
  titleText!: string | undefined;
  /**
        Defines the subtitle text of the component.
        */
  subtitleText!: string | undefined;
  /**
        Defines the state of the icon displayed in the `ui5-timeline-item`.
        */
  state!: 'None' | 'Positive' | 'Critical' | 'Negative' | 'Information';

  /**
     Fired when the item name is pressed either with a
click/tap or by using the Enter or Space key.

**Note:** The event will not be fired if the `name-clickable`
attribute is not set.
    */
  ui5NameClick!: EventEmitter<void>;

  private elementRef: ElementRef<TimelineItem> = inject(ElementRef);
  private zone = inject(NgZone);
  private cdr = inject(ChangeDetectorRef);

  get element(): TimelineItem {
    return this.elementRef.nativeElement;
  }

  constructor() {
    this.cdr.detach();
  }
}
export { TimelineItemComponent };
