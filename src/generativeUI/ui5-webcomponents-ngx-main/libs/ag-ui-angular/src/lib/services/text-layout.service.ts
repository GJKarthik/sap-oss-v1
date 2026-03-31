// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2024 SAP SE

type WhiteSpaceMode = 'normal' | 'pre-wrap';

export interface TextLayoutOptions {
  font: string;
  lineHeight: number;
  maxWidth: number;
  minLines?: number;
  maxLines?: number;
  whiteSpace?: WhiteSpaceMode;
}

interface LayoutResult {
  height: number;
}

interface PretextModule {
  prepare: (text: string, font: string, options?: { whiteSpace?: WhiteSpaceMode }) => unknown;
  layout: (prepared: unknown, maxWidth: number, lineHeight: number) => LayoutResult;
}

let pretextModule: PretextModule | null = null;
let pretextLoadStarted = false;
const preparedCache = new Map<string, unknown>();

function clamp(value: number, min: number, max?: number): number {
  if (max == null) {
    return Math.max(min, value);
  }
  return Math.max(min, Math.min(max, value));
}

function parseFontSizePx(font: string): number {
  const match = font.match(/(\d+(?:\.\d+)?)px/);
  return match ? Number(match[1]) : 14;
}

function fallbackHeight(text: string, options: TextLayoutOptions): number {
  const compact = text.replace(/\s+/g, ' ').trim();
  const lineHeight = options.lineHeight;
  const minLines = Math.max(1, options.minLines ?? 1);
  const maxLines = options.maxLines;

  if (!compact) {
    return Math.ceil(minLines * lineHeight);
  }

  const fontSize = parseFontSizePx(options.font);
  const avgCharWidth = fontSize * 0.56;
  const charsPerLine = Math.max(1, Math.floor(options.maxWidth / Math.max(1, avgCharWidth)));
  const estimatedLines = Math.ceil(compact.length / charsPerLine);
  const lines = clamp(estimatedLines, minLines, maxLines);
  return Math.ceil(lines * lineHeight);
}

function ensurePretextLoaded(): void {
  if (pretextLoadStarted) {
    return;
  }

  pretextLoadStarted = true;
  void import('@chenglou/pretext')
    .then((module: unknown) => {
      pretextModule = module as PretextModule;
    })
    .catch(() => {
      pretextModule = null;
    });
}

export function measureTextHeight(text: string, options: TextLayoutOptions): number {
  const value = (text ?? '').trim();
  const minLines = Math.max(1, options.minLines ?? 1);
  const lineHeight = options.lineHeight;
  const whiteSpace = options.whiteSpace ?? 'normal';

  if (!value) {
    return Math.ceil(minLines * lineHeight);
  }

  ensurePretextLoaded();

  if (!pretextModule) {
    return fallbackHeight(value, options);
  }

  try {
    const cacheKey = `${options.font}|${whiteSpace}|${value}`;
    const prepared = preparedCache.get(cacheKey)
      ?? pretextModule.prepare(value, options.font, { whiteSpace });
    if (!preparedCache.has(cacheKey)) {
      preparedCache.set(cacheKey, prepared);
    }

    const measured = pretextModule.layout(prepared, options.maxWidth, lineHeight);
    const measuredLines = Math.max(1, Math.ceil(measured.height / lineHeight));
    const lines = clamp(measuredLines, minLines, options.maxLines);
    return Math.ceil(lines * lineHeight);
  } catch {
    return fallbackHeight(value, options);
  }
}

export function warmTextLayout(): void {
  ensurePretextLoaded();
}

