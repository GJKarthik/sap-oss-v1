// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2024 SAP SE
export const UPSTREAM_TIMEOUT_MS = 5_000;
export const REDIS_TTL_SECONDS = 86_400;          // 24 h
export const DECISIONS_KEY = 'audit:decisions';    // Redis sorted-set (score = timestamp ms)
export const MAX_DECISIONS_STORED = 10_000;
export const SUMMARY_CACHE_KEY = 'audit:summary';
export const SUMMARY_CACHE_TTL = 60;              // 1 min

