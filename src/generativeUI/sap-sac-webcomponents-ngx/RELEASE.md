# Release Checklist

Use this checklist before publishing the package or uploading a SAC widget artifact.

## Preconditions

- Use Node.js 18 or newer.
- Start from a clean working tree or review any intentional local changes.

## Verification

Run the full local gate:

```bash
npm ci
npm run release:check
```

Equivalent manual sequence:

```bash
npm run lint
npm test
npm run build
npm run build:widget
npm run verify:pack
npm run package
```

## Artifacts

Verify these outputs before release:

| Artifact | Path |
| --- | --- |
| npm package dry-run contents | `npm pack --dry-run` output |
| Angular and SDK build output | `dist/` |
| SAC widget upload package | `dist/releases/widget.zip` |

## Publish Notes

- Publish only the root package `@sap-oss/sac-webcomponents-ngx`.
- Secondary entry points are exposed through the root package exports.
- Upload `dist/releases/widget.zip` to SAC Designer for the custom-widget deployment path.
