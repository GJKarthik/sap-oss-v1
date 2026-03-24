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
import '@ui5/webcomponents-fiori/dist/UploadCollection.js';
import {
  default as UploadCollection,
  UploadCollectionItemDeleteEventDetail,
  UploadCollectionSelectionChangeEventDetail,
} from '@ui5/webcomponents-fiori/dist/UploadCollection.js';
import { ProxyInputs, ProxyOutputs } from '@ui5/webcomponents-ngx/utils';
@ProxyInputs([
  'selectionMode',
  'noDataDescription',
  'noDataText',
  'noDataHeaderLevel',
  'hideDragOverlay',
  'accessibleName',
])
@ProxyOutputs([
  'item-delete: ui5ItemDelete',
  'selection-change: ui5SelectionChange',
])
@Component({
  standalone: true,
  selector: 'ui5-upload-collection',
  template: '<ng-content></ng-content>',
  inputs: [
    'selectionMode',
    'noDataDescription',
    'noDataText',
    'noDataHeaderLevel',
    'hideDragOverlay',
    'accessibleName',
  ],
  outputs: ['ui5ItemDelete', 'ui5SelectionChange'],
  exportAs: 'ui5UploadCollection',
})
class UploadCollectionComponent {
  /**
        Defines the selection mode of the `ui5-upload-collection`.
        */
  selectionMode!:
    | 'None'
    | 'Single'
    | 'SingleStart'
    | 'SingleEnd'
    | 'SingleAuto'
    | 'Multiple';
  /**
        Allows you to set your own text for the 'No data' description.
        */
  noDataDescription!: string | undefined;
  /**
        Allows you to set your own text for the 'No data' text.
        */
  noDataText!: string | undefined;
  /**
        Defines the header level of the 'No data' text.
        */
  noDataHeaderLevel!: 'H1' | 'H2' | 'H3' | 'H4' | 'H5' | 'H6';
  /**
        By default there will be drag and drop overlay shown over the `ui5-upload-collection` when files
are dragged. If you don't intend to use drag and drop, set this property.

**Note:** It is up to the application developer to add handler for `drop` event and handle it.
`ui5-upload-collection` only displays an overlay.
        */
  @InputDecorator({ transform: booleanAttribute })
  hideDragOverlay!: boolean;
  /**
        Defines the accessible ARIA name of the component.
        */
  accessibleName!: string | undefined;

  /**
     Fired when an element is dropped inside the drag and drop overlay.

**Note:** The `drop` event is fired only when elements are dropped within the drag and drop overlay and ignored for the other parts of the `ui5-upload-collection`.
    */
  ui5ItemDelete!: EventEmitter<UploadCollectionItemDeleteEventDetail>;
  /**
     Fired when selection is changed by user interaction
in `Single` and `Multiple` modes.
    */
  ui5SelectionChange!: EventEmitter<UploadCollectionSelectionChangeEventDetail>;

  private elementRef: ElementRef<UploadCollection> = inject(ElementRef);
  private zone = inject(NgZone);
  private cdr = inject(ChangeDetectorRef);

  get element(): UploadCollection {
    return this.elementRef.nativeElement;
  }

  constructor() {
    this.cdr.detach();
  }
}
export { UploadCollectionComponent };
