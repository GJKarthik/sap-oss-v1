// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2023 SAP SE
/** @type {import('@commitlint/types').UserConfig} */
export default {
    extends: ['@commitlint/config-conventional'],
    rules: {
        'scope-enum': [
            2,
            'always',
            [
                'ng-generator', 'json-parser', 'wrapper', 'commit',
                'docs', 'e2e', 'release', 'deps', 'deps-dev', 'changelog', 'ci',
                'ag-ui-angular', 'genui-renderer', 'genui-streaming',
                'genui-collab', 'genui-governance', 'workspace', 'joule',
            ]
        ],
        'body-max-line-length': [2, 'always', 200],
        'footer-max-line-length': [2, 'always', 200],
        'header-max-length': [2, 'always', 200]
    }
};
