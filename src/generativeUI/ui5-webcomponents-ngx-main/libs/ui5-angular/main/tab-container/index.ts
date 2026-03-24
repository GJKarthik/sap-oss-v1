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
import '@ui5/webcomponents/dist/TabContainer.js';
import {
  default as TabContainer,
  TabContainerMoveEventDetail,
  TabContainerTabSelectEventDetail,
} from '@ui5/webcomponents/dist/TabContainer.js';
@ProxyInputs([
  'collapsed',
  'tabLayout',
  'overflowMode',
  'headerBackgroundDesign',
  'contentBackgroundDesign',
  'noAutoSelection',
])
@ProxyOutputs([
  'tab-select: ui5TabSelect',
  'move-over: ui5MoveOver',
  'move: ui5Move',
])
@Component({
  standalone: true,
  selector: 'ui5-tabcontainer',
  template: '<ng-content></ng-content>',
  inputs: [
    'collapsed',
    'tabLayout',
    'overflowMode',
    'headerBackgroundDesign',
    'contentBackgroundDesign',
    'noAutoSelection',
  ],
  outputs: ['ui5TabSelect', 'ui5MoveOver', 'ui5Move'],
  exportAs: 'ui5Tabcontainer',
})
class TabContainerComponent {
  /**
        Defines whether the tab content is collapsed.
        */
  @InputDecorator({ transform: booleanAttribute })
  collapsed!: boolean;
  /**
        Defines the alignment of the content and the `additionalText` of a tab.

**Note:**
The content and the `additionalText` would be displayed vertically by default,
but when set to `Inline`, they would be displayed horizontally.
        */
  tabLayout!: 'Inline' | 'Standard';
  /**
        Defines the overflow mode of the header (the tab strip). If you have a large number of tabs, only the tabs that can fit on screen will be visible.
All other tabs that can 't fit on the screen are available in an overflow tab "More".

**Note:**
Only one overflow at the end would be displayed by default,
but when set to `StartAndEnd`, there will be two overflows on both ends, and tab order will not change on tab selection.
        */
  overflowMode!: 'End' | 'StartAndEnd';
  /**
        Sets the background color of the Tab Container's header as `Solid`, `Transparent`, or `Translucent`.
        */
  headerBackgroundDesign!: 'Solid' | 'Transparent' | 'Translucent';
  /**
        Sets the background color of the Tab Container's content as `Solid`, `Transparent`, or `Translucent`.
        */
  contentBackgroundDesign!: 'Solid' | 'Transparent' | 'Translucent';
  /**
        Defines if automatic tab selection is deactivated.

**Note:** By default, if none of the child tabs have the `selected` property set, the first tab will be automatically selected.
Setting this property to `true` allows preventing this behavior.
        */
  @InputDecorator({ transform: booleanAttribute })
  noAutoSelection!: boolean;

  /**
     Fired when a tab is selected.
    */
  ui5TabSelect!: EventEmitter<TabContainerTabSelectEventDetail>;
  /**
     Fired when element is being moved over the tab container.

If the new position is valid, prevent the default action of the event using `preventDefault()`.
    */
  ui5MoveOver!: EventEmitter<TabContainerMoveEventDetail>;
  /**
     Fired when element is moved to the tab container.

**Note:** `move` event is fired only if there was a preceding `move-over` with prevented default action.
    */
  ui5Move!: EventEmitter<TabContainerMoveEventDetail>;

  private elementRef: ElementRef<TabContainer> = inject(ElementRef);
  private zone = inject(NgZone);
  private cdr = inject(ChangeDetectorRef);

  get element(): TabContainer {
    return this.elementRef.nativeElement;
  }

  constructor() {
    this.cdr.detach();
  }
}
export { TabContainerComponent };
