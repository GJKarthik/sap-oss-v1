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
import '@ui5/webcomponents-fiori/dist/TimelineGroupItem.js';
import TimelineGroupItem from '@ui5/webcomponents-fiori/dist/TimelineGroupItem.js';
import { ProxyInputs, ProxyOutputs } from '@ui5/webcomponents-ngx/utils';
@ProxyInputs(['groupName', 'collapsed'])
@ProxyOutputs(['toggle: ui5Toggle'])
@Component({
  standalone: true,
  selector: 'ui5-timeline-group-item',
  template: '<ng-content></ng-content>',
  inputs: ['groupName', 'collapsed'],
  outputs: ['ui5Toggle'],
  exportAs: 'ui5TimelineGroupItem',
})
class TimelineGroupItemComponent {
  /**
        Defines the text of the button that expands and collapses the group.
        */
  groupName!: string | undefined;
  /**
        Determines if the group is collapsed or expanded.
        */
  @InputDecorator({ transform: booleanAttribute })
  collapsed!: boolean;

  /**
     Fired when the group item is expanded or collapsed.
    */
  ui5Toggle!: EventEmitter<void>;

  private elementRef: ElementRef<TimelineGroupItem> = inject(ElementRef);
  private zone = inject(NgZone);
  private cdr = inject(ChangeDetectorRef);

  get element(): TimelineGroupItem {
    return this.elementRef.nativeElement;
  }

  constructor() {
    this.cdr.detach();
  }
}
export { TimelineGroupItemComponent };
