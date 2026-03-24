// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2023 SAP SE
import { Component } from "@angular/core";
import { Router } from "@angular/router";

@Component({
    templateUrl: './main.component.html',
    standalone: false
})
export class MainComponent {
  constructor(private router: Router) {}

  navigateForms(): void { this.router.navigate(['/forms']); }
  navigateJoule(): void { this.router.navigate(['/joule']); }
  navigateCollab(): void { this.router.navigate(['/collab']); }
}
