/**
 * SAC Input Module
 *
 * Angular module for SAC input control components.
 * Components derived from mangle/sac_widget.mg widget_category "input" facts.
 */

import { NgModule } from '@angular/core';
import { CommonModule } from '@angular/common';
import { FormsModule, ReactiveFormsModule } from '@angular/forms';

import { SacButtonComponent } from './components/sac-button.component';
import { SacDropdownComponent } from './components/sac-dropdown.component';
import { SacInputFieldComponent } from './components/sac-input-field.component';
import { SacDatePickerComponent } from './components/sac-date-picker.component';
import { SacSliderComponent } from './components/sac-slider.component';
import { SacCheckboxComponent } from './components/sac-checkbox.component';
import { SacRadioButtonComponent } from './components/sac-radio-button.component';

const INPUT_COMPONENTS = [
  SacButtonComponent,
  SacDropdownComponent,
  SacInputFieldComponent,
  SacDatePickerComponent,
  SacSliderComponent,
  SacCheckboxComponent,
  SacRadioButtonComponent,
];

@NgModule({
  imports: [
    CommonModule,
    FormsModule,
    ReactiveFormsModule,
  ],
  declarations: INPUT_COMPONENTS,
  exports: INPUT_COMPONENTS,
})
export class SacInputModule {}