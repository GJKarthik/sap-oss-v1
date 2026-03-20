/** @type {import('@commitlint/types').UserConfig} */
export default {
  extends: ['@commitlint/config-conventional'],
  rules: {
    'scope-enum': [
      2,
      'always',
      [
        'workspace',
        'angular-shell',
        'shell',
        'mcp-client',
        'ui-components',
        'api-server',
        'deps',
        'ci'
      ]
    ],
    'body-max-line-length': [2, 'always', 200],
    'footer-max-line-length': [2, 'always', 200],
    'header-max-length': [2, 'always', 200]
  }
};
