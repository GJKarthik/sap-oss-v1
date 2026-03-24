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
import { GenericControlValueAccessor } from '@ui5/webcomponents-ngx/generic-cva';
import { ProxyInputs, ProxyOutputs } from '@ui5/webcomponents-ngx/utils';
import '@ui5/webcomponents/dist/Switch.js';
import Switch from '@ui5/webcomponents/dist/Switch.js';
@ProxyInputs([
  'design',
  'checked',
  'disabled',
  'textOn',
  'textOff',
  'accessibleName',
  'accessibleNameRef',
  'tooltip',
  'required',
  'name',
  'value',
])
@ProxyOutputs(['change: ui5Change'])
@Component({
  standalone: true,
  selector: 'ui5-switch',
  template: '<ng-content></ng-content>',
  inputs: [
    'design',
    'checked',
    'disabled',
    'textOn',
    'textOff',
    'accessibleName',
    'accessibleNameRef',
    'tooltip',
    'required',
    'name',
    'value',
  ],
  outputs: ['ui5Change'],
  exportAs: 'ui5Switch',
  hostDirectives: [GenericControlValueAccessor],
  host: { '(change)': '_cva?.onChange?.(cvaValue);' },
})
class SwitchComponent {
  /**
        Defines the component design.

**Note:** If `Graphical` type is set,
positive and negative icons will replace the `textOn` and `textOff`.
        */
  design!: 'Textual' | 'Graphical';
  /**
        Defines if the component is checked.

**Note:** The property can be changed with user interaction,
either by cliking the component, or by pressing the `Enter` or `Space` key.
        */
  @InputDecorator({ transform: booleanAttribute })
  checked!: boolean;
  /**
        Defines whether the component is disabled.

**Note:** A disabled component is noninteractive.
        */
  @InputDecorator({ transform: booleanAttribute })
  disabled!: boolean;
  /**
        Defines the text, displayed when the component is checked.

**Note:** We recommend using short texts, up to 3 letters (larger texts would be cut off).
        */
  textOn!: string | undefined;
  /**
        Defines the text, displayed when the component is not checked.

**Note:** We recommend using short texts, up to 3 letters (larger texts would be cut off).
        */
  textOff!: string | undefined;
  /**
        Sets the accessible ARIA name of the component.

**Note**: We recommend that you set an accessibleNameRef pointing to an external label or at least an `accessibleName`.
Providing an `accessibleNameRef` or an `accessibleName` is mandatory in the cases when `textOn` and `textOff` properties aren't set.
        */
  accessibleName!: string | undefined;
  /**
        Receives id(or many ids) of the elements that label the component.

**Note**: We recommend that you set an accessibleNameRef pointing to an external label or at least an `accessibleName`.
Providing an `accessibleNameRef` or an `accessibleName` is mandatory in the cases when `textOn` and `textOff` properties aren't set.
        */
  accessibleNameRef!: string | undefined;
  /**
        Defines the tooltip of the component.

**Note:** If applicable an external label reference should always be the preferred option to provide context to the `ui5-switch` component over a tooltip.
        */
  tooltip!: string | undefined;
  /**
        Defines whether the component is required.
        */
  @InputDecorator({ transform: booleanAttribute })
  required!: boolean;
  /**
        Determines the name by which the component will be identified upon submission in an HTML form.

**Note:** This property is only applicable within the context of an HTML Form element.
        */
  name!: string | undefined;
  /**
        Defines the form value of the component.
        */
  value!: string;

  /**
     Fired when the component checked state changes.
    */
  ui5Change!: EventEmitter<void>;

  private elementRef: ElementRef<Switch> = inject(ElementRef);
  private zone = inject(NgZone);
  private cdr = inject(ChangeDetectorRef);
  protected _cva = inject(GenericControlValueAccessor);

  get element(): Switch {
    return this.elementRef.nativeElement;
  }

  set cvaValue(val) {
    this.element.checked = val;
    this.cdr.detectChanges();
  }
  get cvaValue() {
    return this.element.checked;
  }

  constructor() {
    this.cdr.detach();
    this._cva.host = this;
  }
}
export { SwitchComponent };
