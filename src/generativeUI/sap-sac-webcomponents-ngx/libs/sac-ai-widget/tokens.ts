// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2024 SAP SE
import { InjectionToken } from '@angular/core';

/** URL of the CAP LLM Plugin backend (e.g. https://my-cap-app.cfapps.eu10.hana.ondemand.com) */
export const SAC_AI_BACKEND_URL = new InjectionToken<string>('SAC_AI_BACKEND_URL');

/** SAC tenant URL (e.g. https://my-tenant.sapanalytics.cloud) */
export const SAC_TENANT_URL = new InjectionToken<string>('SAC_TENANT_URL');

/** SAC model ID for the default datasource */
export const SAC_MODEL_ID = new InjectionToken<string>('SAC_MODEL_ID');
