// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2024 SAP SE

import type { CpnNetDefinition } from '../types';

/** ODPS "close process" stages S01→S02→S03 as a linear CPN (aligns with odps_compliance.mg petri_stage). */
export const odpsCloseProcessNet: CpnNetDefinition = {
  id: 'odps_close_process_v1',
  places: ['opened', 'after_maker_checker', 'closed'],
  transitions: [
    {
      id: 'advance_S01_to_S02',
      inputArcs: [{ place: 'opened', weight: 1 }],
      outputArcs: [
        {
          place: 'after_maker_checker',
          weight: 1,
          payloadPatch: { stage: 'S02' },
        },
      ],
      guard: {
        all: [{ path: 'stage', op: 'eq', value: 'S01' }],
      },
    },
    {
      id: 'advance_S02_to_S03',
      inputArcs: [{ place: 'after_maker_checker', weight: 1 }],
      outputArcs: [
        {
          place: 'closed',
          weight: 1,
          payloadPatch: { stage: 'S03' },
        },
      ],
      guard: {
        all: [{ path: 'stage', op: 'eq', value: 'S02' }],
      },
    },
  ],
  initialMarking: {
    opened: [{ payload: { stage: 'S01' } }],
  },
};
