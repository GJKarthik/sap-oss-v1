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
  transformIgnorePatterns: ['node_modules/(?!(.*\\.mjs$|@ui5/|@ngrx/|@sap-theming/|@sap-ui5/|lit/|@lit/))'],
  moduleNameMapper: {
    '@ui5/webcomponents-ngx': '<rootDir>/src/__mocks__/ui5-webcomponents-ngx.ts',
    '@ui5/webcomponents-icons/dist/AllIcons.js': '<rootDir>/src/__mocks__/ui5-webcomponents-ngx.ts',
  },
  snapshotSerializers: [
    'jest-preset-angular/build/serializers/no-ng-attributes',
    'jest-preset-angular/build/serializers/ng-snapshot',
    'jest-preset-angular/build/serializers/html-comment',
  ],
};
