# patch-package Usage

## Overview

`patch-package` runs as part of `postinstall` (`yarn install`). It applies any
committed `.patch` files in `patches/` to `node_modules` after installation.

Currently there are **no committed patch files** — the `postinstall` step runs
`patch-package` harmlessly when `patches/` is absent.

The other `postinstall` step (`decorate:angular:cli`) symlinks `ng` → `nx` so
that `ng build/test/lint` routes through the Nx computation cache. See
`decorate-angular-cli.js` for implementation details.

---

## What is Patched (current)

| Package | Patched symbols | Reason | Patch file |
|---|---|---|---|
| *(none yet)* | — | — | — |

---

## Adding a New Patch

1. Edit the file directly in `node_modules/<package>/...`
2. Run `yarn patch-package <package-name>` — this writes `patches/<package-name>+<version>.patch`
3. Commit the `.patch` file
4. Verify the patch applies cleanly: `yarn install --frozen-lockfile` in CI

---

## Fragility Risks and Mitigations

| Risk | Mitigation |
|---|---|
| Patch fails after package upgrade | Pin the patched package in `package.json` with an exact version (`"<pkg>": "x.y.z"`) until the upstream fix lands |
| `@angular/cli` decoration breaks on major upgrade | `decorate-angular-cli.js` catches errors and exits 0; Nx 22 ships `nx/src/adapter/decorate-cli` which is stable across Angular CLI minor versions |
| `patch-package` postinstall silently skips missing patches dir | No action needed — by design |

---

## Pinned Versions (patch-related)

`@angular/cli` is pinned to `~20.3.0` in `package.json`. Do not widen this
range without verifying `decorate-angular-cli.js` compatibility.

---

## CI Verification

The `postinstall` script runs automatically in every `yarn install` in CI.
To verify explicitly:

```bash
yarn postinstall
```

Expected output: `Angular CLI has been decorated to enable computation caching.`
