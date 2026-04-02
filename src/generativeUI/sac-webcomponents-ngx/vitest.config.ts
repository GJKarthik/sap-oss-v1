import path from 'node:path';

import { defineConfig } from 'vitest/config';

export default defineConfig({
  resolve: {
    alias: {
      '@sap-oss/sac-sdk': path.resolve(__dirname, 'libs/sac-sdk/index.ts'),
      '@sap-oss/sac-ngx/core': path.resolve(__dirname, 'libs/sac-core/src/index.ts'),
      '@sap-oss/sac-ngx-core': path.resolve(__dirname, 'libs/sac-core/src/index.ts'),
      '@sap-oss/sac-webcomponents-ngx/sdk': path.resolve(__dirname, 'libs/sac-sdk/index.ts'),
      '@sap-oss/sac-webcomponents-ngx/core': path.resolve(__dirname, 'libs/sac-core/src/index.ts'),
      '@sap-oss/sac-webcomponents-ngx/chart': path.resolve(__dirname, 'libs/sac-chart/src/index.ts'),
      '@sap-oss/sac-webcomponents-ngx/table': path.resolve(__dirname, 'libs/sac-table/src/index.ts'),
      '@sap-oss/sac-webcomponents-ngx/input': path.resolve(__dirname, 'libs/sac-input/src/index.ts'),
      '@sap-oss/sac-webcomponents-ngx/planning': path.resolve(__dirname, 'libs/sac-planning/src/index.ts'),
      '@sap-oss/sac-webcomponents-ngx/datasource': path.resolve(__dirname, 'libs/sac-datasource/src/index.ts'),
      '@sap-oss/sac-webcomponents-ngx/widgets': path.resolve(__dirname, 'libs/sac-widgets/src/index.ts'),
      '@sap-oss/sac-webcomponents-ngx/advanced': path.resolve(__dirname, 'libs/sac-advanced/src/index.ts'),
      '@sap-oss/sac-webcomponents-ngx/builtins': path.resolve(__dirname, 'libs/sac-builtins/src/index.ts'),
      '@sap-oss/sac-webcomponents-ngx/calendar': path.resolve(__dirname, 'libs/sac-calendar/src/index.ts'),
    },
  },
  test: {
    include: ['tests/**/*.spec.ts'],
    environment: 'node',
    globals: true,
    setupFiles: ['tests/setup-angular.ts'],
    clearMocks: true,
    restoreMocks: true,
    unstubGlobals: true,
  },
});
