import { defineConfig } from 'tsup';

export default defineConfig([
  {
    entry: { widget: 'libs/sac-ai-widget/sac-ai-widget.entry.ts' },
    format: ['iife'],
    globalName: 'SacAiWidget',
    outDir: 'dist/sac-ai-widget',
    outExtension: () => ({ js: '.js' }),
    splitting: false,
    sourcemap: false,
    dts: false,
    minify: false,
    target: 'es2022',
    tsconfig: 'tsconfig.json',
  },
]);
