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
      // Retry flaky network/port tests up to 2 times before failing
      retryTimes: 2,
      testTimeout: 15000,
    },
  ],
};
