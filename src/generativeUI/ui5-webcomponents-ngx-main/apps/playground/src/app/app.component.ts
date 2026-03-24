// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2023 SAP SE
import { Component, OnInit } from '@angular/core';
import { Router } from '@angular/router';
import { FormControl, FormGroup, Validators } from "@angular/forms";

@Component({
    selector: 'ui-angular-root',
    templateUrl: './app.component.html',
    styleUrls: ['./app.component.scss'],
    standalone: false
})
export class AppComponent implements OnInit {
  currentTheme = 'sap_horizon';

  radioControl = new FormControl('Option 2');
  selectControl = new FormControl('desktop');
  inpControl = new FormControl('test');
  dpControl = new FormControl('17 мая 2024 г.');
  cbControl = new FormControl(false);

  profileForm = new FormGroup({
    name: new FormControl('', Validators.required),
    email: new FormControl('', Validators.required),
  });

  constructor(private router: Router) {}

  ngOnInit(): void {
    const saved = localStorage.getItem('ui5-theme');
    if (saved) {
      this.currentTheme = saved;
      this.applyTheme(saved);
    }
  }

  navigateTo(path: string): void {
    this.router.navigate([path]);
  }

  onMenuItemClick(event: Event): void {
    const detail = (event as CustomEvent).detail;
    if (detail?.item?.text) {
      const map: Record<string, string> = {
        'Home': '/',
        'Forms Demo': '/forms',
        'Joule AI': '/joule',
        'Collaboration': '/collab',
      };
      const path = map[detail.item.text];
      if (path) this.router.navigate([path]);
    }
  }

  onThemeChange(event: Event): void {
    const theme = (event as CustomEvent).detail?.selectedOption?.value;
    if (theme) {
      this.currentTheme = theme;
      this.applyTheme(theme);
      localStorage.setItem('ui5-theme', theme);
    }
  }

  private applyTheme(theme: string): void {
    document.documentElement.setAttribute('data-sap-theme', theme);
  }

  updateSelectFormModel() {
    this.selectControl.setValue("phone");
  }
  updateRadioFormModel() {
    this.radioControl.setValue("Option 1");
  }

  updateDPFormModel() {
    this.dpControl.setValue("29 мая 2024 г.");
  }

  updateCbFormModel() {
    this.cbControl.setValue(true);
  }
  updateInpFormModel() {
    this.inpControl.setValue("form updated");
  }

  handleSubmit() {
    alert(
      this.profileForm.value.name + ' | ' + this.profileForm.value.email
    );
  }
}
