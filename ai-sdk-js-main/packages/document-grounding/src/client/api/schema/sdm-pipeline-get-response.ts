// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2024 SAP SE
/*
 * Copyright (c) 2026 SAP SE or an SAP affiliate company. All rights reserved.
 *
 * This is a generated file powered by the SAP Cloud SDK for JavaScript.
 */
import type { BasePipelineResponse } from './base-pipeline-response.js';
import type { MetaData } from './meta-data.js';
/**
 * Representation of the 'SDMPipelineGetResponse' schema.
 */
export type SDMPipelineGetResponse = BasePipelineResponse & {
  type?: 'SDM';
  metadata: MetaData;
} & Record<string, any>;
