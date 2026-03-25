// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2024 SAP SE
/**
 * FormsPageComponent unit tests
 *
 * Covers:
 * - Initial FormControl values
 * - setValue() helpers update each control
 * - profileForm validation: invalid when empty, valid with correct data
 * - handleSubmit() sets submitted/submittedData on valid form
 * - handleSubmit() marks all touched on invalid form without submitting
 * - resetForm() resets submitted state and form
 */

import { FormsPageComponent } from './forms-page.component';

function createComponent() {
  const component = new FormsPageComponent();
  return { component };
}

// ---------------------------------------------------------------------------
// Initial state
// ---------------------------------------------------------------------------

describe('FormsPageComponent — initial state', () => {
  it('radioControl starts with Option 2', () => {
    const { component } = createComponent();
    expect(component.radioControl.value).toBe('Option 2');
  });

  it('selectControl starts with desktop', () => {
    const { component } = createComponent();
    expect(component.selectControl.value).toBe('desktop');
  });

  it('inpControl starts with test', () => {
    const { component } = createComponent();
    expect(component.inpControl.value).toBe('test');
  });

  it('cbControl starts false', () => {
    const { component } = createComponent();
    expect(component.cbControl.value).toBe(false);
  });

  it('profileForm starts invalid (empty required fields)', () => {
    const { component } = createComponent();
    expect(component.profileForm.valid).toBe(false);
  });

  it('submitted starts false', () => {
    const { component } = createComponent();
    expect(component.submitted).toBe(false);
    expect(component.submittedData).toBeNull();
  });
});

// ---------------------------------------------------------------------------
// FormControl setValue helpers
// ---------------------------------------------------------------------------

describe('FormsPageComponent — setValue helpers', () => {
  it('updateSelectFormModel() sets selectControl to phone', () => {
    const { component } = createComponent();
    component.updateSelectFormModel();
    expect(component.selectControl.value).toBe('phone');
  });

  it('updateRadioFormModel() sets radioControl to Option 1', () => {
    const { component } = createComponent();
    component.updateRadioFormModel();
    expect(component.radioControl.value).toBe('Option 1');
  });

  it('updateCbFormModel() sets cbControl to true', () => {
    const { component } = createComponent();
    component.updateCbFormModel();
    expect(component.cbControl.value).toBe(true);
  });

  it('updateInpFormModel() sets inpControl to "form updated"', () => {
    const { component } = createComponent();
    component.updateInpFormModel();
    expect(component.inpControl.value).toBe('form updated');
  });
});

// ---------------------------------------------------------------------------
// Profile form validation
// ---------------------------------------------------------------------------

describe('FormsPageComponent — profile form validation', () => {
  it('name is required', () => {
    const { component } = createComponent();
    component.profileForm.controls.name.setValue('');
    expect(component.profileForm.controls.name.valid).toBe(false);
    expect(component.profileForm.controls.name.errors?.['required']).toBeTruthy();
  });

  it('email must be a valid email', () => {
    const { component } = createComponent();
    component.profileForm.controls.name.setValue('Alice');
    component.profileForm.controls.email.setValue('not-an-email');
    expect(component.profileForm.controls.email.errors?.['email']).toBeTruthy();
  });

  it('form is valid with name and valid email', () => {
    const { component } = createComponent();
    component.profileForm.controls.name.setValue('Alice');
    component.profileForm.controls.email.setValue('alice@example.com');
    expect(component.profileForm.valid).toBe(true);
  });
});

// ---------------------------------------------------------------------------
// Submit / reset
// ---------------------------------------------------------------------------

describe('FormsPageComponent — handleSubmit', () => {
  it('sets submitted and submittedData on valid form', () => {
    const { component } = createComponent();
    component.profileForm.controls.name.setValue('Bob');
    component.profileForm.controls.email.setValue('bob@example.com');
    component.handleSubmit();
    expect(component.submitted).toBe(true);
    expect(component.submittedData?.name).toBe('Bob');
    expect(component.submittedData?.email).toBe('bob@example.com');
  });

  it('does not submit on invalid form and marks all touched', () => {
    const { component } = createComponent();
    component.handleSubmit();
    expect(component.submitted).toBe(false);
    expect(component.submittedData).toBeNull();
    expect(component.profileForm.controls.name.touched).toBe(true);
    expect(component.profileForm.controls.email.touched).toBe(true);
  });
});

describe('FormsPageComponent — resetForm', () => {
  it('clears submitted state and resets the form', () => {
    const { component } = createComponent();
    component.profileForm.controls.name.setValue('Charlie');
    component.profileForm.controls.email.setValue('charlie@example.com');
    component.handleSubmit();
    expect(component.submitted).toBe(true);

    component.resetForm();
    expect(component.submitted).toBe(false);
    expect(component.submittedData).toBeNull();
    expect(component.profileForm.controls.name.value).toBeNull();
  });
});
