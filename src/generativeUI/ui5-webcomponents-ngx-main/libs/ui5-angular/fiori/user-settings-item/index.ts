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
import '@ui5/webcomponents-fiori/dist/UserSettingsItem.js';
import {
  default as UserSettingsItem,
  UserSettingsItemViewSelectEventDetail,
} from '@ui5/webcomponents-fiori/dist/UserSettingsItem.js';
import { ProxyInputs, ProxyOutputs } from '@ui5/webcomponents-ngx/utils';
@ProxyInputs([
  'text',
  'tooltip',
  'headerText',
  'selected',
  'disabled',
  'loading',
  'loadingReason',
  'icon',
  'accessibleName',
])
@ProxyOutputs(['selection-change: ui5SelectionChange'])
@Component({
  standalone: true,
  selector: 'ui5-user-settings-item',
  template: '<ng-content></ng-content>',
  inputs: [
    'text',
    'tooltip',
    'headerText',
    'selected',
    'disabled',
    'loading',
    'loadingReason',
    'icon',
    'accessibleName',
  ],
  outputs: ['ui5SelectionChange'],
  exportAs: 'ui5UserSettingsItem',
})
class UserSettingsItemComponent {
  /**
        Defines the text of the user settings item.
        */
  text!: string;
  /**
        Defines the tooltip of the component.

A tooltip attribute should be provided to represent the meaning or function when the component is collapsed and only the icon is visible.
        */
  tooltip!: string;
  /**
        Defines the headerText of the item.
        */
  headerText!: string | undefined;
  /**
        Shows item tab.
        */
  @InputDecorator({ transform: booleanAttribute })
  selected!: boolean;
  /**
        Defines whether the component is in disabled state.

**Note:** A disabled component is completely noninteractive.
        */
  @InputDecorator({ transform: booleanAttribute })
  disabled!: boolean;
  /**
        Indicates whether a loading indicator should be shown.
        */
  @InputDecorator({ transform: booleanAttribute })
  loading!: boolean;
  /**
        Indicates why the control is in loading state.
        */
  loadingReason!: string | undefined;
  /**
        Defines the icon of the component.
        */
  icon!: string;
  /**
        Defines the accessible ARIA name of the component.
        */
  accessibleName!: string | undefined;

  /**
     Fired when a selected view changed.
    */
  ui5SelectionChange!: EventEmitter<UserSettingsItemViewSelectEventDetail>;

  private elementRef: ElementRef<UserSettingsItem> = inject(ElementRef);
  private zone = inject(NgZone);
  private cdr = inject(ChangeDetectorRef);

  get element(): UserSettingsItem {
    return this.elementRef.nativeElement;
  }

  constructor() {
    this.cdr.detach();
  }
}
export { UserSettingsItemComponent };
