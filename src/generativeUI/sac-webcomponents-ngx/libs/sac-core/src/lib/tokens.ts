/**
 * SAC Core Injection Tokens
 *
 * DI tokens for SAC configuration and services.
 */

import { InjectionToken } from '@angular/core';
import { SacConfig } from './types/config.types';

/** Injection token for SAC configuration */
export const SAC_CONFIG = new InjectionToken<SacConfig>('SAC_CONFIG');

/** Injection token for SAC API base URL */
export const SAC_API_URL = new InjectionToken<string>('SAC_API_URL');

/** Injection token for SAC auth token */
export const SAC_AUTH_TOKEN = new InjectionToken<string>('SAC_AUTH_TOKEN');