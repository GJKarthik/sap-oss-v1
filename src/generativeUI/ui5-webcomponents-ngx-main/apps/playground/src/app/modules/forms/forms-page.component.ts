// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2023 SAP SE
import { Component } from '@angular/core';
import { FormControl, FormGroup, Validators } from '@angular/forms';

@Component({
  selector: 'app-forms-page',
  templateUrl: './forms-page.component.html',
  standalone: false,
})
export class FormsPageComponent {
  radioControl = new FormControl('Option 2');
  selectControl = new FormControl('desktop');
  inpControl = new FormControl('test');
  dpControl = new FormControl('17 мая 2024 г.');
  cbControl = new FormControl(false);

  profileForm = new FormGroup({
    name: new FormControl('', Validators.required),
    email: new FormControl('', [Validators.required, Validators.email]),
  });

  submitted = false;
  submittedData: { name: string | null | undefined; email: string | null | undefined } | null = null;

  updateSelectFormModel(): void { this.selectControl.setValue('phone'); }
  updateRadioFormModel(): void { this.radioControl.setValue('Option 1'); }
  updateDPFormModel(): void { this.dpControl.setValue('29 мая 2024 г.'); }
  updateCbFormModel(): void { this.cbControl.setValue(true); }
  updateInpFormModel(): void { this.inpControl.setValue('form updated'); }

  handleSubmit(): void {
    if (this.profileForm.valid) {
      this.submitted = true;
      this.submittedData = {
        name: this.profileForm.value.name,
        email: this.profileForm.value.email,
      };
    } else {
      this.profileForm.markAllAsTouched();
    }
  }

  resetForm(): void {
    this.profileForm.reset();
    this.submitted = false;
    this.submittedData = null;
  }
}
