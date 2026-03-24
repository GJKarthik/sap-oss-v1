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
import '@ui5/webcomponents-fiori/dist/UserSettingsAppearanceView.js';
import {
  default as UserSettingsAppearanceView,
  UserSettingsAppearanceViewItemSelectEventDetail,
} from '@ui5/webcomponents-fiori/dist/UserSettingsAppearanceView.js';
import { ProxyInputs, ProxyOutputs } from '@ui5/webcomponents-ngx/utils';
@ProxyInputs(['text', 'selected', 'secondary'])
@ProxyOutputs(['selection-change: ui5SelectionChange'])
@Component({
  standalone: true,
  selector: 'ui5-user-settings-appearance-view',
  template: '<ng-content></ng-content>',
  inputs: ['text', 'selected', 'secondary'],
  outputs: ['ui5SelectionChange'],
  exportAs: 'ui5UserSettingsAppearanceView',
})
class UserSettingsAppearanceViewComponent {
  /**
        Defines the title text of the user settings view.
        */
  text!: string | undefined;
  /**
        Defines whether the view is selected. There can be just one selected view at a time.
        */
  @InputDecorator({ transform: booleanAttribute })
  selected!: boolean;
  /**
        Indicates whether the view is secondary. It is relevant only if the view is used in `pages` slot of `ui5-user-settings-item`
and controls the visibility of the back button.
        */
  @InputDecorator({ transform: booleanAttribute })
  secondary!: boolean;

  /**
     Fired when an item is selected.
    */
  ui5SelectionChange!: EventEmitter<UserSettingsAppearanceViewItemSelectEventDetail>;

  private elementRef: ElementRef<UserSettingsAppearanceView> =
    inject(ElementRef);
  private zone = inject(NgZone);
  private cdr = inject(ChangeDetectorRef);

  get element(): UserSettingsAppearanceView {
    return this.elementRef.nativeElement;
  }

  constructor() {
    this.cdr.detach();
  }
}
export { UserSettingsAppearanceViewComponent };
