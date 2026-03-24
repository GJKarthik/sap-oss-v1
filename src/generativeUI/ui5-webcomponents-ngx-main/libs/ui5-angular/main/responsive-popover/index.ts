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
import { PopupBeforeCloseEventDetail } from '@ui5/webcomponents/dist/Popup.js';
import '@ui5/webcomponents/dist/ResponsivePopover.js';
import ResponsivePopover from '@ui5/webcomponents/dist/ResponsivePopover.js';
@ProxyInputs([
  'initialFocus',
  'preventFocusRestore',
  'accessibleName',
  'accessibleNameRef',
  'accessibleRole',
  'accessibleDescription',
  'accessibleDescriptionRef',
  'preventInitialFocus',
  'open',
  'headerText',
  'placement',
  'horizontalAlign',
  'verticalAlign',
  'modal',
  'hideArrow',
  'allowTargetOverlap',
  'opener',
])
@ProxyOutputs([
  'before-open: ui5BeforeOpen',
  'open: ui5Open',
  'before-close: ui5BeforeClose',
  'close: ui5Close',
])
@Component({
  standalone: true,
  selector: 'ui5-responsive-popover',
  template: '<ng-content></ng-content>',
  inputs: [
    'initialFocus',
    'preventFocusRestore',
    'accessibleName',
    'accessibleNameRef',
    'accessibleRole',
    'accessibleDescription',
    'accessibleDescriptionRef',
    'preventInitialFocus',
    'open',
    'headerText',
    'placement',
    'horizontalAlign',
    'verticalAlign',
    'modal',
    'hideArrow',
    'allowTargetOverlap',
    'opener',
  ],
  outputs: ['ui5BeforeOpen', 'ui5Open', 'ui5BeforeClose', 'ui5Close'],
  exportAs: 'ui5ResponsivePopover',
})
class ResponsivePopoverComponent {
  /**
        Defines the ID of the HTML Element, which will get the initial focus.

**Note:** If an element with `autofocus` attribute is added inside the component,
`initialFocus` won't take effect.
        */
  initialFocus!: string | undefined;
  /**
        Defines if the focus should be returned to the previously focused element,
when the popup closes.
        */
  @InputDecorator({ transform: booleanAttribute })
  preventFocusRestore!: boolean;
  /**
        Defines the accessible name of the component.
        */
  accessibleName!: string | undefined;
  /**
        Defines the IDs of the elements that label the component.
        */
  accessibleNameRef!: string | undefined;
  /**
        Allows setting a custom role.
        */
  accessibleRole!: 'None' | 'Dialog' | 'AlertDialog';
  /**
        Defines the accessible description of the component.
        */
  accessibleDescription!: string | undefined;
  /**
        Receives id(or many ids) of the elements that describe the component.
        */
  accessibleDescriptionRef!: string | undefined;
  /**
        Indicates whether initial focus should be prevented.
        */
  @InputDecorator({ transform: booleanAttribute })
  preventInitialFocus!: boolean;
  /**
        Indicates if the element is open
        */
  @InputDecorator({ transform: booleanAttribute })
  open!: boolean;
  /**
        Defines the header text.

**Note:** If `header` slot is provided, the `headerText` is ignored.
        */
  headerText!: string | undefined;
  /**
        Determines on which side the component is placed at.
        */
  placement!: 'Start' | 'End' | 'Top' | 'Bottom';
  /**
        Determines the horizontal alignment of the component.
        */
  horizontalAlign!: 'Center' | 'Start' | 'End' | 'Stretch';
  /**
        Determines the vertical alignment of the component.
        */
  verticalAlign!: 'Center' | 'Top' | 'Bottom' | 'Stretch';
  /**
        Defines whether the component should close when
clicking/tapping outside of the popover.
If enabled, it blocks any interaction with the background.
        */
  @InputDecorator({ transform: booleanAttribute })
  modal!: boolean;
  /**
        Determines whether the component arrow is hidden.
        */
  @InputDecorator({ transform: booleanAttribute })
  hideArrow!: boolean;
  /**
        Determines if there is no enough space, the component can be placed
over the target.
        */
  @InputDecorator({ transform: booleanAttribute })
  allowTargetOverlap!: boolean;
  /**
        Defines the ID or DOM Reference of the element at which the popover is shown.
When using this attribute in a declarative way, you must only use the `id` (as a string) of the element at which you want to show the popover.
You can only set the `opener` attribute to a DOM Reference when using JavaScript.
        */
  opener!: HTMLElement | string | null | undefined;

  /**
     Fired before the component is opened. This event can be cancelled, which will prevent the popup from opening.
    */
  ui5BeforeOpen!: EventEmitter<void>;
  /**
     Fired after the component is opened.
    */
  ui5Open!: EventEmitter<void>;
  /**
     Fired before the component is closed. This event can be cancelled, which will prevent the popup from closing.
    */
  ui5BeforeClose!: EventEmitter<PopupBeforeCloseEventDetail>;
  /**
     Fired after the component is closed.
    */
  ui5Close!: EventEmitter<void>;

  private elementRef: ElementRef<ResponsivePopover> = inject(ElementRef);
  private zone = inject(NgZone);
  private cdr = inject(ChangeDetectorRef);

  get element(): ResponsivePopover {
    return this.elementRef.nativeElement;
  }

  constructor() {
    this.cdr.detach();
  }
}
export { ResponsivePopoverComponent };
