// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2024 SAP SE
import { HttpDestination } from '@sap-cloud-sdk/connectivity';
import { expectType } from 'tsd';
import { getAiCoreDestination } from '@sap-ai-sdk/core';

expectType<Promise<HttpDestination>>(getAiCoreDestination());
