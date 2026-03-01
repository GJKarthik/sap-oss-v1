// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2023 SAP SE
export function pascalCase(string: string): string {
  return `${string}`
    .toLowerCase()
    .replace(new RegExp(/[-_.]+/, 'g'), ' ')
    .replace(new RegExp(/[^\w\s]/, 'g'), '')
    .replace(
      new RegExp(/\s+(.)(\w*)/, 'g'),
      ($1, $2, $3) => `${$2.toUpperCase() + $3}`
    )
    .replace(new RegExp(/\w/), (s) => s.toUpperCase());
}
