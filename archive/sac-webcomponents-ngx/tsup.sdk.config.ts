import { defineConfig } from 'tsup';

export default defineConfig({
  entry: { index: 'libs/sac-sdk/index.ts' },
  format: ['esm'],
  outDir: 'dist/sac-sdk',
  target: 'es2022',
  dts: true,
  sourcemap: false,
  splitting: false,
  clean: true,
});
