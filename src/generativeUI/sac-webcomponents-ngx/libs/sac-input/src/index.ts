/**
 * @sap-oss/sac-webcomponents-ngx/input
 *
 * Angular Input Controls Module for SAP Analytics Cloud.
 * Components derived from mangle/sac_widget.mg widget_category "input" facts.
 */

// ---------------------------------------------------------------------------
// Module
// ---------------------------------------------------------------------------

export { SacInputModule } from './lib/sac-input.module';

// ---------------------------------------------------------------------------
// Components (from mangle widget_category "input")
// ---------------------------------------------------------------------------

export { SacButtonComponent } from './lib/components/sac-button.component';
export { SacDropdownComponent } from './lib/components/sac-dropdown.component';
export { SacInputFieldComponent } from './lib/components/sac-input-field.component';
export { SacDatePickerComponent } from './lib/components/sac-date-picker.component';
export { SacSliderComponent } from './lib/components/sac-slider.component';
export { SacCheckboxComponent } from './lib/components/sac-checkbox.component';
export { SacRadioButtonComponent } from './lib/components/sac-radio-button.component';

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

export type {
  SelectionItem,
  ButtonConfig,
  DropdownConfig,
  InputFieldConfig,
  DatePickerConfig,
  SliderConfig,
} from './lib/types/input.types';

// ---------------------------------------------------------------------------
// Events
// ---------------------------------------------------------------------------

export type {
  ButtonClickEvent,
  DropdownChangeEvent,
  InputFieldChangeEvent,
  DatePickerChangeEvent,
  SliderChangeEvent,
} from './lib/types/input-events.types';
