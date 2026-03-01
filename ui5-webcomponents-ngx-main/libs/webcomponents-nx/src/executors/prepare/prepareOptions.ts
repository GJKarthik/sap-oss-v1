// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2023 SAP SE
import {SchematicsOptions} from "./schematicsOptions";

export interface PrepareOptions {
  schematics?: SchematicsOptions;
  distPath: string;
}
