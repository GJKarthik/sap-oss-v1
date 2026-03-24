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
import '@ui5/webcomponents-fiori/dist/Timeline.js';
import Timeline from '@ui5/webcomponents-fiori/dist/Timeline.js';
import { ProxyInputs, ProxyOutputs } from '@ui5/webcomponents-ngx/utils';
@ProxyInputs(['layout', 'accessibleName', 'loading', 'loadingDelay', 'growing'])
@ProxyOutputs(['load-more: ui5LoadMore'])
@Component({
  standalone: true,
  selector: 'ui5-timeline',
  template: '<ng-content></ng-content>',
  inputs: ['layout', 'accessibleName', 'loading', 'loadingDelay', 'growing'],
  outputs: ['ui5LoadMore'],
  exportAs: 'ui5Timeline',
})
class TimelineComponent {
  /**
        Defines the items orientation.
        */
  layout!: 'Vertical' | 'Horizontal';
  /**
        Defines the accessible ARIA name of the component.
        */
  accessibleName!: string | undefined;
  /**
        Defines if the component should display a loading indicator over the Timeline.
        */
  @InputDecorator({ transform: booleanAttribute })
  loading!: boolean;
  /**
        Defines the delay in milliseconds, after which the loading indicator will show up for this component.
        */
  loadingDelay!: number;
  /**
        Defines whether the Timeline will have growing capability either by pressing a "More" button,
or via user scroll. In both cases a `load-more` event is fired.

Available options:

`Button` - Displays a button at the end of the Timeline, which when pressed triggers the `load-more` event.

`Scroll` -Triggers the `load-more` event when the user scrolls to the end of the Timeline.

`None` (default) - The growing functionality is off.
        */
  growing!: 'Button' | 'Scroll' | 'None';

  /**
     Fired when the user presses the `More` button or scrolls to the Timeline's end.

**Note:** The event will be fired if `growing` is set to `Button` or `Scroll`.
    */
  ui5LoadMore!: EventEmitter<void>;

  private elementRef: ElementRef<Timeline> = inject(ElementRef);
  private zone = inject(NgZone);
  private cdr = inject(ChangeDetectorRef);

  get element(): Timeline {
    return this.elementRef.nativeElement;
  }

  constructor() {
    this.cdr.detach();
  }
}
export { TimelineComponent };
