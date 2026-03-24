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
import { SearchFieldScopeSelectionChangeDetails } from '@ui5/webcomponents-fiori/dist/SearchField.js';
import '@ui5/webcomponents-fiori/dist/ShellBarSearch.js';
import ShellBarSearch from '@ui5/webcomponents-fiori/dist/ShellBarSearch.js';
import { ProxyInputs, ProxyOutputs } from '@ui5/webcomponents-ngx/utils';
@ProxyInputs([
  'loading',
  'noTypeahead',
  'open',
  'showClearIcon',
  'value',
  'placeholder',
  'accessibleName',
  'accessibleDescription',
  'scopeValue',
  'autoOpen',
])
@ProxyOutputs([
  'open: ui5Open',
  'close: ui5Close',
  'input: ui5Input',
  'scope-change: ui5ScopeChange',
  'search: ui5Search',
])
@Component({
  standalone: true,
  selector: 'ui5-shellbar-search',
  template: '<ng-content></ng-content>',
  inputs: [
    'loading',
    'noTypeahead',
    'open',
    'showClearIcon',
    'value',
    'placeholder',
    'accessibleName',
    'accessibleDescription',
    'scopeValue',
    'autoOpen',
  ],
  outputs: ['ui5Open', 'ui5Close', 'ui5Input', 'ui5ScopeChange', 'ui5Search'],
  exportAs: 'ui5ShellbarSearch',
})
class ShellBarSearchComponent {
  /**
        Indicates whether a loading indicator should be shown in the popup.
        */
  @InputDecorator({ transform: booleanAttribute })
  loading!: boolean;
  /**
        Defines whether the value will be autcompleted to match an item.
        */
  @InputDecorator({ transform: booleanAttribute })
  noTypeahead!: boolean;
  /**
        Indicates whether the items picker is open.
        */
  @InputDecorator({ transform: booleanAttribute })
  open!: boolean;
  /**
        Defines whether the clear icon of the search will be shown.
        */
  @InputDecorator({ transform: booleanAttribute })
  showClearIcon!: boolean;
  /**
        Defines the value of the component.

**Note:** The property is updated upon typing.
        */
  value!: string;
  /**
        Defines a short hint intended to aid the user with data entry when the
component has no value.
        */
  placeholder!: string | undefined;
  /**
        Defines the accessible ARIA name of the component.
        */
  accessibleName!: string | undefined;
  /**
        Defines the accessible ARIA description of the field.
        */
  accessibleDescription!: string | undefined;
  /**
        Defines the value of the component:

Applications are responsible for setting the correct scope value.

**Note:** If the given value does not match any existing scopes,
no scope will be selected and the SearchField scope component will be displayed as empty.
        */
  scopeValue!: string | undefined;
  /**
        Indicates whether the suggestions popover should be opened on focus.
        */
  @InputDecorator({ transform: booleanAttribute })
  autoOpen!: boolean;

  /**
     Fired when the popup is opened.
    */
  ui5Open!: EventEmitter<void>;
  /**
     Fired when the popup is closed.
    */
  ui5Close!: EventEmitter<void>;
  /**
     Fired when typing in input or clear icon is pressed.
    */
  ui5Input!: EventEmitter<void>;
  /**
     Fired when the scope has changed.
    */
  ui5ScopeChange!: EventEmitter<SearchFieldScopeSelectionChangeDetails>;
  /**
     Fired when the user has triggered search with Enter key or Search Button press.
    */
  ui5Search!: EventEmitter<void>;

  private elementRef: ElementRef<ShellBarSearch> = inject(ElementRef);
  private zone = inject(NgZone);
  private cdr = inject(ChangeDetectorRef);

  get element(): ShellBarSearch {
    return this.elementRef.nativeElement;
  }

  constructor() {
    this.cdr.detach();
  }
}
export { ShellBarSearchComponent };
