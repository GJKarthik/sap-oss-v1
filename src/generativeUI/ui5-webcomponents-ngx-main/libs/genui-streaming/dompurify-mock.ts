// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2023 SAP SE
// Minimal DOMPurify mock for Jest — passes input through unchanged.
const DOMPurify = {
  sanitize: (input: string, _config?: unknown) => input,
  isValidAttribute: (_tag: string, _attr: string, _value: string) => true,
  addHook: (_name: string, _fn: unknown) => {},
  removeHook: (_name: string) => {},
  removeHooks: (_name: string) => {},
  setConfig: (_config: unknown) => {},
  clearConfig: () => {},
  version: '3.0.0',
  isSupported: true,
};
export default DOMPurify;
module.exports = DOMPurify;
module.exports.default = DOMPurify;
