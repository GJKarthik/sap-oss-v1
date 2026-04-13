// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2023 SAP SE
/* eslint-disable */
module.exports = {
  displayName: 'workspace',
  preset: '../../jest.preset.js',
  setupFilesAfterEnv: ['<rootDir>/src/test-setup.ts'],
  globals: {},
  coverageDirectory: '../../coverage/apps/workspace',
  transform: {
    '^.+\\.(ts|mjs|js|html)$': [
      'jest-preset-angular',
      {
        tsconfig: '<rootDir>/tsconfig.spec.json',
        stringifyContentPathRegex: '\\.(html|svg)$',
      },
    ],
  },
  // Default Nx pattern only transpiles .mjs under node_modules; @ui5 ships ESM as .js — allowlist @angular + @ui5 + lit.
  transformIgnorePatterns: [
    'node_modules/(?!(@angular\\/|@angular-devkit\\/|@ui5\\/|lit-html\\/|lit-element\\/|lit\\/|@lit\\/|@lit-labs\\/))',
  ],
  snapshotSerializers: [
    'jest-preset-angular/build/serializers/no-ng-attributes',
    'jest-preset-angular/build/serializers/ng-snapshot',
    'jest-preset-angular/build/serializers/html-comment',
  ],
};
