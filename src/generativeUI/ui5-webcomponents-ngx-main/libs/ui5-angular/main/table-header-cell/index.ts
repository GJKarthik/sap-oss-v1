import {
  ChangeDetectorRef,
  Component,
  ElementRef,
  Input as InputDecorator,
  NgZone,
  booleanAttribute,
  inject,
} from '@angular/core';
import { ProxyInputs } from '@ui5/webcomponents-ngx/utils';
import '@ui5/webcomponents/dist/TableHeaderCell.js';
import TableHeaderCell from '@ui5/webcomponents/dist/TableHeaderCell.js';
@ProxyInputs([
  'horizontalAlign',
  'width',
  'minWidth',
  'importance',
  'popinText',
  'sortIndicator',
  'popinHidden',
])
@Component({
  standalone: true,
  selector: 'ui5-table-header-cell',
  template: '<ng-content></ng-content>',
  inputs: [
    'horizontalAlign',
    'width',
    'minWidth',
    'importance',
    'popinText',
    'sortIndicator',
    'popinHidden',
  ],
  exportAs: 'ui5TableHeaderCell',
})
class TableHeaderCellComponent {
  /**
        Determines the horizontal alignment of table cells.
        */
  horizontalAlign!: 'Left' | 'Start' | 'Right' | 'End' | 'Center' | undefined;
  /**
        Defines the width of the column.

By default, the column will grow and shrink according to the available space.
This will distribute the space proportionally among all columns with no specific width set.

See [\<length\>](https://developer.mozilla.org/en-US/docs/Web/CSS/length) and
[\<percentage\>](https://developer.mozilla.org/en-US/docs/Web/CSS/percentage) for possible width values.
        */
  width!: string | undefined;
  /**
        Defines the minimum width of the column.

If the table is in `Popin` mode and the minimum width does not fit anymore,
the column will move into the popin.

By default, the table prevents the column from becoming too small.
Changing this value to a small value might lead to accessibility issues.

**Note:** This property only takes effect for columns with a [\<percentage\>](https://developer.mozilla.org/en-US/docs/Web/CSS/percentage) value
or the default width.
        */
  minWidth!: string | undefined;
  /**
        Defines the importance of the column.

This property affects the popin behaviour.
Columns with higher importance will move into the popin area later then less important
columns.
        */
  importance!: number;
  /**
        The text for the column when it pops in.
        */
  popinText!: string | undefined;
  /**
        Defines the sort indicator of the column.
        */
  sortIndicator!: 'None' | 'Ascending' | 'Descending';
  /**
        Defines if the column is hidden in the popin.

**Note:** Please be aware that hiding the column in the popin might lead to accessibility issues as
users might not be able to access the content of the column on small screens.
        */
  @InputDecorator({ transform: booleanAttribute })
  popinHidden!: boolean;

  private elementRef: ElementRef<TableHeaderCell> = inject(ElementRef);
  private zone = inject(NgZone);
  private cdr = inject(ChangeDetectorRef);

  get element(): TableHeaderCell {
    return this.elementRef.nativeElement;
  }

  constructor() {
    this.cdr.detach();
  }
}
export { TableHeaderCellComponent };
