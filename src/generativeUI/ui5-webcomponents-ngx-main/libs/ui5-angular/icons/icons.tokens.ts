// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2023 SAP SE
import {InjectionToken} from "@angular/core";

export const Ui5AngularSelectedIconsToLoad = new InjectionToken<() => Promise<any>>('Icons, that should be loaded by the Ui5AngularIconsModule.');
