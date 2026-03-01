// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2024 SAP SE
/**
 * Jest test setup for @sap-ai-sdk/vllm package.
 */

// Set test timeout
jest.setTimeout(10000);

// Mock console methods to reduce test output noise
const originalConsoleLog = console.log;
const originalConsoleError = console.error;

beforeAll(() => {
  // Suppress console output during tests unless DEBUG is set
  if (!process.env.DEBUG) {
    console.log = jest.fn();
    console.error = jest.fn();
  }
});

afterAll(() => {
  // Restore console methods
  console.log = originalConsoleLog;
  console.error = originalConsoleError;
});

// Global test utilities
declare global {
  // eslint-disable-next-line @typescript-eslint/no-namespace
  namespace NodeJS {
    interface Global {
      mockVllmEndpoint: string;
      mockVllmModel: string;
    }
  }
}

// Default mock values
(global as unknown as { mockVllmEndpoint: string }).mockVllmEndpoint = 'http://localhost:8000';
(global as unknown as { mockVllmModel: string }).mockVllmModel = 'meta-llama/Llama-3.1-70B-Instruct';