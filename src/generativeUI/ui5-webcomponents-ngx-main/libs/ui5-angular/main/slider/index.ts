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
import '@ui5/webcomponents/dist/Slider.js';
import Slider from '@ui5/webcomponents/dist/Slider.js';
@ProxyInputs([
  'min',
  'max',
  'name',
  'step',
  'labelInterval',
  'showTickmarks',
  'showTooltip',
  'editableTooltip',
  'disabled',
  'accessibleName',
  'value',
])
@ProxyOutputs(['change: ui5Change', 'input: ui5Input'])
@Component({
  standalone: true,
  selector: 'ui5-slider',
  template: '<ng-content></ng-content>',
  inputs: [
    'min',
    'max',
    'name',
    'step',
    'labelInterval',
    'showTickmarks',
    'showTooltip',
    'editableTooltip',
    'disabled',
    'accessibleName',
    'value',
  ],
  outputs: ['ui5Change', 'ui5Input'],
  exportAs: 'ui5Slider',
  hostDirectives: [GenericControlValueAccessor],
  host: {
    '(change)': '_cva?.onChange?.(cvaValue);',
    '(input)': '_cva?.onChange?.(cvaValue);',
  },
})
class SliderComponent {
  /**
        Defines the minimum value of the slider.
        */
  min!: number;
  /**
        Defines the maximum value of the slider.
        */
  max!: number;
  /**
        Determines the name by which the component will be identified upon submission in an HTML form.

**Note:** This property is only applicable within the context of an HTML Form element.
        */
  name!: string | undefined;
  /**
        Defines the size of the slider's selection intervals (e.g. min = 0, max = 10, step = 5 would result in possible selection of the values 0, 5, 10).

**Note:** If set to 0 the slider handle movement is disabled. When negative number or value other than a number, the component fallbacks to its default value.
        */
  step!: number;
  /**
        Displays a label with a value on every N-th step.

**Note:** The step and tickmarks properties must be enabled.
Example - if the step value is set to 2 and the label interval is also specified to 2 - then every second
tickmark will be labelled, which means every 4th value number.
        */
  labelInterval!: number;
  /**
        Enables tickmarks visualization for each step.

**Note:** The step must be a positive number.
        */
  @InputDecorator({ transform: booleanAttribute })
  showTickmarks!: boolean;
  /**
        Enables handle tooltip displaying the current value.
        */
  @InputDecorator({ transform: booleanAttribute })
  showTooltip!: boolean;
  /**
        
Indicates whether input fields should be used as tooltips for the handles.

**Note:** Setting this option to true will only work if showTooltip is set to true.
**Note:** In order for the component to comply with the accessibility standard, it is recommended to set the editableTooltip property to true.
        */
  @InputDecorator({ transform: booleanAttribute })
  editableTooltip!: boolean;
  /**
        Defines whether the slider is in disabled state.
        */
  @InputDecorator({ transform: booleanAttribute })
  disabled!: boolean;
  /**
        Defines the accessible ARIA name of the component.
        */
  accessibleName!: string | undefined;
  /**
        Current value of the slider
        */
  value!: number;

  /**
     Fired when the value changes and the user has finished interacting with the slider.
    */
  ui5Change!: EventEmitter<void>;
  /**
     Fired when the value changes due to user interaction that is not yet finished - during mouse/touch dragging.
    */
  ui5Input!: EventEmitter<void>;

  private elementRef: ElementRef<Slider> = inject(ElementRef);
  private zone = inject(NgZone);
  private cdr = inject(ChangeDetectorRef);
  protected _cva = inject(GenericControlValueAccessor);

  get element(): Slider {
    return this.elementRef.nativeElement;
  }

  set cvaValue(val) {
    this.element.value = val;
    this.cdr.detectChanges();
  }
  get cvaValue() {
    return this.element.value;
  }

  constructor() {
    this.cdr.detach();
    this._cva.host = this;
  }
}
export { SliderComponent };
