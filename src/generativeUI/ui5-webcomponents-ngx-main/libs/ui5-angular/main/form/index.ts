import {
  ChangeDetectorRef,
  Component,
  ElementRef,
  NgZone,
  inject,
} from '@angular/core';
import { ProxyInputs } from '@ui5/webcomponents-ngx/utils';
import '@ui5/webcomponents/dist/Form.js';
import Form from '@ui5/webcomponents/dist/Form.js';
@ProxyInputs([
  'accessibleName',
  'accessibleNameRef',
  'accessibleMode',
  'layout',
  'labelSpan',
  'emptySpan',
  'headerText',
  'headerLevel',
  'itemSpacing',
])
@Component({
  standalone: true,
  selector: 'ui5-form',
  template: '<ng-content></ng-content>',
  inputs: [
    'accessibleName',
    'accessibleNameRef',
    'accessibleMode',
    'layout',
    'labelSpan',
    'emptySpan',
    'headerText',
    'headerLevel',
    'itemSpacing',
  ],
  exportAs: 'ui5Form',
})
class FormComponent {
  /**
        Defines the accessible ARIA name of the component.
        */
  accessibleName!: string | undefined;
  /**
        Defines id (or many ids) of the element (or elements) that label the component.
        */
  accessibleNameRef!: string | undefined;
  /**
        Defines the accessibility mode of the component in "edit" and "display" use-cases.

Based on the mode, the component renders different HTML elements and ARIA attributes,
which are appropriate for the use-case.

**Usage:**
- Set this property to "Display", when the form consists of non-editable (e.g. texts) form items.
- Set this property to "Edit", when the form consists of editable (e.g. input fields) form items.
        */
  accessibleMode!: 'Display' | 'Edit';
  /**
        Defines the number of columns to distribute the form content by breakpoint.

Supported values:
- `S` - 1 column by default (1 column is recommended)
- `M` - 1 column by default (up to 2 columns are recommended)
- `L` - 2 columns by default (up to 3 columns are recommended)
- `XL` - 3 columns by default (up to 6 columns  are recommended)
        */
  layout!: string;
  /**
        Defines the width proportion of the labels and fields of a form item by breakpoint.

By default, the labels take 4/12 (or 1/3) of the form item in M,L and XL sizes,
and 12/12 in S size, e.g in S the label is on top of its associated field.

The supported values are between 1 and 12. Greater the number, more space the label will use.

**Note:** If "12" is set, the label will be displayed on top of its assosiated field.
        */
  labelSpan!: string;
  /**
        Defines the number of cells that are empty at the end of each form item, configurable by breakpoint.

By default, a form item spans 12 cells, fully divided between its label (4 cells) and field (8 cells), with no empty space at the end.
The `emptySpan` provides additional layout flexibility by defining empty space at the form item’s end.

**Note:**
- The maximum allowable empty space is 10 cells. At least 1 cell each must remain for the label and the field.
- When `emptySpan` is specified (greater than 0), ensure that the combined value of `emptySpan` and `labelSpan` does not exceed 11. This guarantees a minimum of 1 cell for the field.
        */
  emptySpan!: string;
  /**
        Defines the header text of the component.

**Note:** The property gets overridden by the `header` slot.
        */
  headerText!: string | undefined;
  /**
        Defines the compoennt heading level,
set by the `headerText`.
        */
  headerLevel!: 'H1' | 'H2' | 'H3' | 'H4' | 'H5' | 'H6';
  /**
        Defines the vertical spacing between form items.

**Note:** If the Form is meant to be switched between "display"("non-edit") and "edit" modes,
we recommend using "Large" item spacing in "display"("non-edit") mode, and "Normal" - for "edit" mode,
to avoid "jumping" effect, caused by the hight difference between texts in "display"("non-edit") mode and the input fields in "edit" mode.
        */
  itemSpacing!: 'Normal' | 'Large';

  private elementRef: ElementRef<Form> = inject(ElementRef);
  private zone = inject(NgZone);
  private cdr = inject(ChangeDetectorRef);

  get element(): Form {
    return this.elementRef.nativeElement;
  }

  constructor() {
    this.cdr.detach();
  }
}
export { FormComponent };
