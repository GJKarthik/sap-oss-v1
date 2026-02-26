const js = require("@eslint/js");

module.exports = [
  js.configs.recommended,
  {
    languageOptions: {
      ecmaVersion: 2022,
      sourceType: "commonjs",
      globals: {
        require: "readonly",
        module: "readonly",
        exports: "readonly",
        __dirname: "readonly",
        __filename: "readonly",
        process: "readonly",
        console: "readonly",
        global: "readonly",
        cds: "readonly",
      },
    },
    rules: {
      "no-unused-vars": ["warn", { argsIgnorePattern: "^_" }],
      "no-console": "off",
      "no-prototype-builtins": "off",
    },
  },
  {
    files: ["tests/**/*.js"],
    languageOptions: {
      globals: {
        jest: "readonly",
        describe: "readonly",
        test: "readonly",
        expect: "readonly",
        beforeEach: "readonly",
        afterEach: "readonly",
        beforeAll: "readonly",
        afterAll: "readonly",
        fetch: "readonly",
      },
    },
  },
  {
    ignores: [
      "node_modules/",
      "coverage/",
      "generated/",
      "*.d.ts",
      "cds-plugin.js",
      "srv/cap-llm-plugin.js",
      "lib/anonymization-helper.js",
      "src/**/*.js",
      "src/**/*.js.map",
    ],
  },
];
