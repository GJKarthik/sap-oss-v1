// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2023 SAP SE
const DOMPurify = {
  sanitize: (dirty: string, _config?: unknown): string => dirty,
  addHook: (_hook: string, _callback: unknown): void => { /* noop */ },
  removeHook: (_hook: string): void => { /* noop */ },
  isValidAttribute: (_tag: string, _attr: string, _value: string): boolean => true,
};

export default DOMPurify;
export { DOMPurify };
