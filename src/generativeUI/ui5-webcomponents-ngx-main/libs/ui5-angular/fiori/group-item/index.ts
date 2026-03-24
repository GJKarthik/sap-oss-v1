import {
  ChangeDetectorRef,
  Component,
  ElementRef,
  Input as InputDecorator,
  NgZone,
  booleanAttribute,
  inject,
} from '@angular/core';
import '@ui5/webcomponents-fiori/dist/GroupItem.js';
import GroupItem from '@ui5/webcomponents-fiori/dist/GroupItem.js';
import { ProxyInputs } from '@ui5/webcomponents-ngx/utils';
@ProxyInputs(['text', 'selected'])
@Component({
  standalone: true,
  selector: 'ui5-group-item',
  template: '<ng-content></ng-content>',
  inputs: ['text', 'selected'],
  exportAs: 'ui5GroupItem',
})
class GroupItemComponent {
  /**
        Defines the text of the group item.
        */
  text!: string | undefined;
  /**
        Defines if the group item is selected.
        */
  @InputDecorator({ transform: booleanAttribute })
  selected!: boolean;

  private elementRef: ElementRef<GroupItem> = inject(ElementRef);
  private zone = inject(NgZone);
  private cdr = inject(ChangeDetectorRef);

  get element(): GroupItem {
    return this.elementRef.nativeElement;
  }

  constructor() {
    this.cdr.detach();
  }
}
export { GroupItemComponent };
