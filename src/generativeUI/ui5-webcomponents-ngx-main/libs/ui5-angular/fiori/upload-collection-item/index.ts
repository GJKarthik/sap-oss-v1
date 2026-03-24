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
import '@ui5/webcomponents-fiori/dist/UploadCollectionItem.js';
import UploadCollectionItem from '@ui5/webcomponents-fiori/dist/UploadCollectionItem.js';
import { ProxyInputs, ProxyOutputs } from '@ui5/webcomponents-ngx/utils';
import { ListItemAccessibilityAttributes } from '@ui5/webcomponents/dist/ListItem.js';
@ProxyInputs([
  'type',
  'accessibilityAttributes',
  'navigated',
  'tooltip',
  'highlight',
  'selected',
  'file',
  'fileName',
  'fileNameClickable',
  'disableDeleteButton',
  'hideDeleteButton',
  'hideRetryButton',
  'hideTerminateButton',
  'progress',
  'uploadState',
])
@ProxyOutputs([
  'detail-click: ui5DetailClick',
  'file-name-click: ui5FileNameClick',
  'rename: ui5Rename',
  'terminate: ui5Terminate',
  'retry: ui5Retry',
])
@Component({
  standalone: true,
  selector: 'ui5-upload-collection-item',
  template: '<ng-content></ng-content>',
  inputs: [
    'type',
    'accessibilityAttributes',
    'navigated',
    'tooltip',
    'highlight',
    'selected',
    'file',
    'fileName',
    'fileNameClickable',
    'disableDeleteButton',
    'hideDeleteButton',
    'hideRetryButton',
    'hideTerminateButton',
    'progress',
    'uploadState',
  ],
  outputs: [
    'ui5DetailClick',
    'ui5FileNameClick',
    'ui5Rename',
    'ui5Terminate',
    'ui5Retry',
  ],
  exportAs: 'ui5UploadCollectionItem',
})
class UploadCollectionItemComponent {
  /**
        Defines the visual indication and behavior of the list items.
Available options are `Active` (by default), `Inactive`, `Detail` and `Navigation`.

**Note:** When set to `Active` or `Navigation`, the item will provide visual response upon press and hover,
while with type `Inactive` and `Detail` - will not.
        */
  type!: 'Inactive' | 'Active' | 'Detail' | 'Navigation';
  /**
        Defines the additional accessibility attributes that will be applied to the component.
The following fields are supported:

- **ariaSetsize**: Defines the number of items in the current set  when not all items in the set are present in the DOM.
**Note:** The value is an integer reflecting the number of items in the complete set. If the size of the entire set is unknown, set `-1`.

	- **ariaPosinset**: Defines an element's number or position in the current set when not all items are present in the DOM.
	**Note:** The value is an integer greater than or equal to 1, and less than or equal to the size of the set when that size is known.
        */
  accessibilityAttributes!: ListItemAccessibilityAttributes;
  /**
        The navigated state of the list item.
If set to `true`, a navigation indicator is displayed at the end of the list item.
        */
  @InputDecorator({ transform: booleanAttribute })
  navigated!: boolean;
  /**
        Defines the text of the tooltip that would be displayed for the list item.
        */
  tooltip!: string | undefined;
  /**
        Defines the highlight state of the list items.
Available options are: `"None"` (by default), `"Positive"`, `"Critical"`, `"Information"` and `"Negative"`.
        */
  highlight!: 'None' | 'Positive' | 'Critical' | 'Negative' | 'Information';
  /**
        Defines the selected state of the component.
        */
  @InputDecorator({ transform: booleanAttribute })
  selected!: boolean;
  /**
        Holds an instance of `File` associated with this item.
        */
  file!: File | null;
  /**
        The name of the file.
        */
  fileName!: string;
  /**
        If set to `true` the file name will be clickable and it will fire `file-name-click` event upon click.
        */
  @InputDecorator({ transform: booleanAttribute })
  fileNameClickable!: boolean;
  /**
        Disables the delete button.
        */
  @InputDecorator({ transform: booleanAttribute })
  disableDeleteButton!: boolean;
  /**
        Hides the delete button.
        */
  @InputDecorator({ transform: booleanAttribute })
  hideDeleteButton!: boolean;
  /**
        Hides the retry button when `uploadState` property is `Error`.
        */
  @InputDecorator({ transform: booleanAttribute })
  hideRetryButton!: boolean;
  /**
        Hides the terminate button when `uploadState` property is `Uploading`.
        */
  @InputDecorator({ transform: booleanAttribute })
  hideTerminateButton!: boolean;
  /**
        The upload progress in percentage.

**Note:** Expected values are in the interval [0, 100].
        */
  progress!: number;
  /**
        Upload state.

Depending on this property, the item displays the following:

- `Ready` - progress indicator is displayed.
- `Uploading` - progress indicator and terminate button are displayed. When the terminate button is pressed, `terminate` event is fired.
- `Error` - progress indicator and retry button are displayed. When the retry button is pressed, `retry` event is fired.
- `Complete` - progress indicator is not displayed.
        */
  uploadState!: 'Complete' | 'Error' | 'Ready' | 'Uploading';

  /**
     Fired when the user clicks on the detail button when type is `Detail`.
    */
  ui5DetailClick!: EventEmitter<void>;
  /**
     Fired when the file name is clicked.

**Note:** This event is only available when `fileNameClickable` property is `true`.
    */
  ui5FileNameClick!: EventEmitter<void>;
  /**
     Fired when the `fileName` property gets changed.

**Note:** An edit button is displayed on each item,
when the `ui5-upload-collection-item` `type` property is set to `Detail`.
    */
  ui5Rename!: EventEmitter<void>;
  /**
     Fired when the terminate button is pressed.

**Note:** Terminate button is displayed when `uploadState` property is set to `Uploading`.
    */
  ui5Terminate!: EventEmitter<void>;
  /**
     Fired when the retry button is pressed.

**Note:** Retry button is displayed when `uploadState` property is set to `Error`.
    */
  ui5Retry!: EventEmitter<void>;

  private elementRef: ElementRef<UploadCollectionItem> = inject(ElementRef);
  private zone = inject(NgZone);
  private cdr = inject(ChangeDetectorRef);

  get element(): UploadCollectionItem {
    return this.elementRef.nativeElement;
  }

  constructor() {
    this.cdr.detach();
  }
}
export { UploadCollectionItemComponent };
