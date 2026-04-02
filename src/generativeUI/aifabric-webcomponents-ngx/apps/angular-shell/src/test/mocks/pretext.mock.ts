export function prepare(text: string, font: string, options?: { whiteSpace?: 'normal' | 'pre-wrap' }): object {
  void text;
  void font;
  void options;
  return { mocked: true };
}

export function layout(prepared: object, maxWidth: number, lineHeight: number): { height: number; lineCount: number } {
  void prepared;
  void maxWidth;
  void lineHeight;
  return { height: 20, lineCount: 1 };
}

export function clearCache(): void {
  // no-op mock for unit tests
}

