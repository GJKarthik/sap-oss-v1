import { Injectable } from '@angular/core';
import { clearCache, layout, prepare } from '@chenglou/pretext';

type WhiteSpaceMode = 'normal' | 'pre-wrap';

export interface TextLayoutOptions {
  maxWidth: number;
  lineHeight: number;
  font?: string;
  whiteSpace?: WhiteSpaceMode;
  minLines?: number;
  maxLines?: number;
}

@Injectable({
  providedIn: 'root',
})
export class TextLayoutService {
  private readonly defaultFont = '14px "72", Arial, sans-serif';
  private readonly preparedCache = new Map<string, unknown>();

  measureHeight(text: string, options: TextLayoutOptions): number {
    const safeText = (text || '').trim();
    const safeWidth = Math.max(1, Math.floor(options.maxWidth));
    const safeLineHeight = Math.max(1, Math.floor(options.lineHeight));
    const minLines = Math.max(1, options.minLines ?? 1);
    const maxLines = Math.max(minLines, options.maxLines ?? Number.MAX_SAFE_INTEGER);
    const font = options.font || this.defaultFont;
    const whiteSpace = options.whiteSpace || 'normal';

    if (!safeText) {
      return minLines * safeLineHeight;
    }

    const key = `${font}::${whiteSpace}::${safeText}`;
    let prepared = this.preparedCache.get(key);
    if (!prepared) {
      try {
        prepared = prepare(safeText, font, { whiteSpace });
        this.preparedCache.set(key, prepared);
      } catch {
        return this.fallbackHeight(safeText, safeWidth, safeLineHeight, minLines, maxLines);
      }
    }

    try {
      const result = layout(prepared as never, safeWidth, safeLineHeight);
      const boundedLines = Math.max(minLines, Math.min(maxLines, result.lineCount));
      return boundedLines * safeLineHeight;
    } catch {
      return this.fallbackHeight(safeText, safeWidth, safeLineHeight, minLines, maxLines);
    }
  }

  clear(): void {
    this.preparedCache.clear();
    clearCache();
  }

  private fallbackHeight(
    text: string,
    maxWidth: number,
    lineHeight: number,
    minLines: number,
    maxLines: number
  ): number {
    const approxCharsPerLine = Math.max(8, Math.floor(maxWidth / 7));
    const estimatedLines = Math.max(1, Math.ceil(text.length / approxCharsPerLine));
    const boundedLines = Math.max(minLines, Math.min(maxLines, estimatedLines));
    return boundedLines * lineHeight;
  }
}

