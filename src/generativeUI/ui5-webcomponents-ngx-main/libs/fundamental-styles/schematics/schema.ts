// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2023 SAP SE
export interface Schema {
  project: string;
  theming: boolean;
  defaultTheme: string;
  commonCss: string[];
}
