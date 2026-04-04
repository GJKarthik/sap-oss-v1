// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2024 SAP SE

import type { CpnNetDefinition } from './types';
import { odpsCloseProcessNet } from './nets/odps-close-process';

export const BUILTIN_CPN_SCENARIOS: Record<string, CpnNetDefinition> = {
  odps_close_process: odpsCloseProcessNet,
  cpn_odps_close_process: odpsCloseProcessNet,
};

export function getBuiltinNet(scenario: string): CpnNetDefinition | undefined {
  return BUILTIN_CPN_SCENARIOS[scenario];
}
