// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2023 SAP SE
module.exports = {
  projects: [
    {
      displayName: "unit+integration",
      testEnvironment: "node",
      testMatch: ["**/tests/**/*.test.js"],
      testPathIgnorePatterns: ["tests/e2e/"],
      collectCoverageFrom: ["srv/**/*.js", "lib/**/*.js", "cds-plugin.js", "!**/node_modules/**", "!**/errors/**"],
      coverageDirectory: "coverage",
      coverageThreshold: {
        global: {
          lines: 70,
          branches: 70,
        },
      },
    },
    {
      displayName: "e2e",
      testEnvironment: "node",
      testMatch: ["**/tests/e2e/**/*.test.js"],
      // Single retry only; prefer fixing flaky tests over masking with retries
      retryTimes: 1,
      testTimeout: 15000,
    },
  ],
};
