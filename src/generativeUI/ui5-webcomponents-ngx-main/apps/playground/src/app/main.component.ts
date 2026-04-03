// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2023 SAP SE
import { Component } from "@angular/core";
import { Router } from "@angular/router";

@Component({
    templateUrl: './main.component.html',
    styleUrls: ['./main.component.scss'],
    standalone: false
})
export class MainComponent {
  constructor(private router: Router) {}

  navigateForms(): void { this.router.navigate(['/forms']); }
  navigateJoule(): void { this.router.navigate(['/joule']); }
  navigateCollab(): void { this.router.navigate(['/collab']); }
  navigateGenerative(): void { this.router.navigate(['/generative']); }
  navigateComponents(): void { this.router.navigate(['/components']); }
  navigateMcp(): void { this.router.navigate(['/mcp']); }
  navigateOcr(): void { this.router.navigate(['/ocr']); }
  navigateReadiness(): void { this.router.navigate(['/readiness']); }
}
