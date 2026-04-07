// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2023 SAP SE
import { Component } from "@angular/core";
import { Router } from "@angular/router";
import { WorkspaceService } from "./core/workspace.service";
import { NavLinkDatum } from "./core/workspace.types";

@Component({
    templateUrl: './main.component.html',
    styleUrls: ['./main.component.scss'],
    standalone: false
})
export class MainComponent {
  constructor(
    private router: Router,
    private workspaceService: WorkspaceService,
  ) {}

  get homeCards(): NavLinkDatum[] {
    return this.workspaceService.visibleHomeCards();
  }

  navigateTo(path: string): void {
    this.router.navigate([path]);
  }

  trackByPath(_index: number, card: NavLinkDatum): string {
    return card.path;
  }
}
