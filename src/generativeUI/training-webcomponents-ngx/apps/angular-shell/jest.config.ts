export default {
  displayName: 'angular-shell',
  preset: '../../jest.preset.js',
  setupFilesAfterEnv: ['<rootDir>/src/test-setup.ts'],
  coverageDirectory: '../../coverage/apps/angular-shell',
  transform: {
    '^.+\\.(ts|mjs|js|html)$': [
      'jest-preset-angular',
      {
        tsconfig: '<rootDir>/tsconfig.spec.json',
        stringifyContentPathRegex: '\\.(html|svg)$',
      },
    ],
  },
  transformIgnorePatterns: ['node_modules/(?!(@ui5|lit|@lit).*|.*\\.mjs$)'],
  moduleNameMapper: {
    '^@messageformat/core$': '<rootDir>/src/testing/messageformat-core.mock.ts',
    '^@ui5/webcomponents-ngx$': '<rootDir>/src/testing/ui5-webcomponents-ngx.mock.ts',
  },
  snapshotSerializers: [
    'jest-preset-angular/build/serializers/no-ng-attributes',
    'jest-preset-angular/build/serializers/ng-snapshot',
    'jest-preset-angular/build/serializers/html-comment',
  ],
};
