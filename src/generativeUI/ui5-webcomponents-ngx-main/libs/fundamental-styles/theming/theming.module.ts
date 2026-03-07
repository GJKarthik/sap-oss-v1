// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2023 SAP SE
import {NgModule} from "@angular/core";
import {Ui5FundamentalThemingService} from "./theming.service";

@NgModule({
  providers: [Ui5FundamentalThemingService]
})
export class Ui5FundamentalThemingModule {
  constructor(service: Ui5FundamentalThemingService) {
  }
}
