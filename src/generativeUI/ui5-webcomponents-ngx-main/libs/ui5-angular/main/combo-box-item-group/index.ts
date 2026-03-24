import {
  ChangeDetectorRef,
  Component,
  ElementRef,
  EventEmitter,
  NgZone,
  inject,
} from '@angular/core';
import { ProxyInputs, ProxyOutputs } from '@ui5/webcomponents-ngx/utils';
import '@ui5/webcomponents/dist/ComboBoxItemGroup.js';
import ComboBoxItemGroup from '@ui5/webcomponents/dist/ComboBoxItemGroup.js';
import { ListItemGroupMoveEventDetail } from '@ui5/webcomponents/dist/ListItemGroup.js';
@ProxyInputs(['headerText', 'headerAccessibleName', 'wrappingType'])
@ProxyOutputs(['move-over: ui5MoveOver', 'move: ui5Move'])
@Component({
  standalone: true,
  selector: 'ui5-cb-item-group',
  template: '<ng-content></ng-content>',
  inputs: ['headerText', 'headerAccessibleName', 'wrappingType'],
  outputs: ['ui5MoveOver', 'ui5Move'],
  exportAs: 'ui5CbItemGroup',
})
class ComboBoxItemGroupComponent {
  /**
        Defines the header text of the <code>ui5-li-group</code>.
        */
  headerText!: string | undefined;
  /**
        Defines the accessible name of the header.
        */
  headerAccessibleName!: string | undefined;
  /**
        Defines if the text of the component should wrap when it's too long.
When set to "Normal", the content (title, description) will be wrapped
using the `ui5-expandable-text` component.<br/>

The text can wrap up to 100 characters on small screens (size S) and
up to 300 characters on larger screens (size M and above). When text exceeds
these limits, it truncates with an ellipsis followed by a text expansion trigger.

Available options are:
- `None` (default) - The text will truncate with an ellipsis.
- `Normal` - The text will wrap (without truncation).
        */
  wrappingType!: 'None' | 'Normal';

  /**
     Fired when a movable list item is moved over a potential drop target during a dragging operation.

If the new position is valid, prevent the default action of the event using `preventDefault()`.
    */
  ui5MoveOver!: EventEmitter<ListItemGroupMoveEventDetail>;
  /**
     Fired when a movable list item is dropped onto a drop target.

**Note:** `move` event is fired only if there was a preceding `move-over` with prevented default action.
    */
  ui5Move!: EventEmitter<ListItemGroupMoveEventDetail>;

  private elementRef: ElementRef<ComboBoxItemGroup> = inject(ElementRef);
  private zone = inject(NgZone);
  private cdr = inject(ChangeDetectorRef);

  get element(): ComboBoxItemGroup {
    return this.elementRef.nativeElement;
  }

  constructor() {
    this.cdr.detach();
  }
}
export { ComboBoxItemGroupComponent };
