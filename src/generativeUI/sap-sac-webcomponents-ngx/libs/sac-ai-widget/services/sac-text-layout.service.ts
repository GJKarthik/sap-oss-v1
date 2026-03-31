// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2024 SAP SE

import { layout, prepare } from '@chenglou/pretext';

type WhiteSpaceMode = 'normal' | 'pre-wrap';

export interface SacTextLayoutOptions {
  font: string;
  lineHeight: number;
  maxWidth: number;
  minLines?: number;
  maxLines?: number;
  whiteSpace?: WhiteSpaceMode;
}

const preparedCache = new Map<string, ReturnType<typeof prepare>>();

function parseFontSizePx(font: string): number {
  const match = font.match(/(\d+(?:\.\d+)?)px/);
  return match ? Number(match[1]) : 14;
}

function clamp(value: number, min: number, max?: number): number {
  if (max == null) {
    return Math.max(min, value);
  }
  return Math.max(min, Math.min(max, value));
}

function fallbackHeight(text: string, options: SacTextLayoutOptions): number {
  const lineHeight = options.lineHeight;
  const minLines = Math.max(1, options.minLines ?? 1);
  const maxLines = options.maxLines;

  const compact = text.replace(/\s+/g, ' ').trim();
  if (!compact) {
    return minLines * lineHeight;
  }

  const fontSize = parseFontSizePx(options.font);
  const avgCharWidth = fontSize * 0.56;
  const charsPerLine = Math.max(1, Math.floor(options.maxWidth / Math.max(1, avgCharWidth)));
  const lines = clamp(Math.ceil(compact.length / charsPerLine), minLines, maxLines);
  return Math.ceil(lines * lineHeight);
}

export function estimateTextHeight(text: string, options: SacTextLayoutOptions): number {
  const value = (text ?? '').trim();
  const minLines = Math.max(1, options.minLines ?? 1);
  const lineHeight = options.lineHeight;

  if (!value) {
    return Math.ceil(minLines * lineHeight);
  }

  const whiteSpace = options.whiteSpace ?? 'normal';
  const cacheKey = `${options.font}|${whiteSpace}|${value}`;

  try {
    const prepared = preparedCache.get(cacheKey)
      ?? prepare(value, options.font, { whiteSpace });
    if (!preparedCache.has(cacheKey)) {
      preparedCache.set(cacheKey, prepared);
    }

    const result = layout(prepared, options.maxWidth, lineHeight);
    const measuredLines = Math.max(1, Math.ceil(result.height / lineHeight));
    const lines = clamp(measuredLines, minLines, options.maxLines);
    return Math.ceil(lines * lineHeight);
  } catch {
    return fallbackHeight(value, options);
  }
}

export function clearTextLayoutCache(): void {
  preparedCache.clear();
}

