# AI Verify Zig/Mojo Migration

This document tracks the migration of `aiverify-main` from Python-first runtime
to Zig + Mojo with parity guarantees.

## Current Runtime Model

- `zig/src/main.zig` is the compatibility runtime entrypoint.
- Zig forwards execution to Python modules by component:
  - `aiverify_apigw`
  - `aiverify_test_engine`
  - `aiverify_test_engine_worker`
- `mojo/src/ffi_exports.mojo` contains deterministic primitives that can be
  called from Zig as parity-sensitive logic moves over.

This keeps behavior stable while component internals are ported incrementally.

## Layout

- `zig/`: compatibility runtime and Python bridge.
- `mojo/`: FFI-compatible utility primitives and smoke tests.
- `mangle/`: migration metadata and parity bridge declarations.
- `scripts/`: parity checks between direct Python execution and Zig bridge.

## Commands

Build and test Zig:

```bash
cd zig
zig build
zig build test
```

Run Zig compatibility runtime:

```bash
cd zig
zig build run -- components
zig build run -- test-engine-version
zig build run -- test-engine --help
zig build run -- run test-engine
zig build run -- apigw-config
zig build run -- apigw-validate-gid-cid "aiverify.stock_reports-01"
zig build run -- apigw validate-gid-cid "aiverify.stock_reports-01"
zig build run -- apigw-check-valid-filename "reports/stock-01.csv"
zig build run -- apigw check-valid-filename "reports/stock-01.csv"
zig build run -- apigw-sanitize-filename "report-v1?.zip"
zig build run -- apigw sanitize-filename "report-v1?.zip"
zig build run -- apigw-check-relative-to-base "/tmp/base" "/tmp/base/file.txt"
zig build run -- apigw check-relative-to-base "s3://bucket/prefix/" "child"
zig build run -- apigw-check-file-size 4294967296
zig build run -- apigw check-file-size 4294967297
zig build run -- apigw-append-filename "path/to/file.tar.gz" "_v2"
zig build run -- apigw append-filename "path/to/file.tar.gz" "_v2"
zig build run -- apigw-get-suffix "file.TXT"
zig build run -- apigw get-stem "path/to/file.tar.gz"
zig build run -- apigw-plugin-storage-layout local "/base/plugin" "aiverify.stock_reports-01" "algo-01"
zig build run -- apigw plugin-storage-layout prefix "base/plugin/" "aiverify.stock_reports-01" "algo-01"
zig build run -- apigw plugin-storage-layout s3 "s3://bucket/root/plugin/" "aiverify.stock_reports-01" "algo-01"
zig build run -- apigw-data-storage-layout local "/base/artifacts" "/base/models" "/base/datasets" "TR123" "nested/file.bin" "nlp"
zig build run -- apigw data-storage-layout s3 "s3://bucket/root/artifacts/" "s3://bucket/root/models/" "s3://bucket/root/datasets/" "BAD_ID" "nested/file.bin" "nlp"
zig build run -- apigw-save-artifact "/tmp/apigw-artifacts" "TR123" "nested/file.bin" "artifact_payload_01"
zig build run -- apigw-get-artifact "/tmp/apigw-artifacts" "TR123" "nested/file.bin"
zig build run -- apigw-save-model-local "/tmp/apigw-models" "/tmp/model_payload.bin"
zig build run -- apigw-get-model-local "/tmp/apigw-models" "model_payload.bin"
zig build run -- apigw-delete-model-local "/tmp/apigw-models" "model_payload.bin"
zig build run -- apigw-save-dataset-local "/tmp/apigw-datasets" "/tmp/dataset_payload.csv"
zig build run -- apigw-get-dataset-local "/tmp/apigw-datasets" "dataset_payload.csv"
zig build run -- apigw-delete-dataset-local "/tmp/apigw-datasets" "dataset_payload.csv"
zig build run -- apigw save-model-local "/tmp/apigw-models" "/tmp/model_payload.bin"
zig build run -- apigw get-dataset-local "/tmp/apigw-datasets" "dataset_payload.csv"
zig build run -- apigw-save-plugin-local "/tmp/apigw-plugins" "gid-01" "/tmp/plugin_source"
zig build run -- apigw-save-plugin-algorithm-local "/tmp/apigw-plugins" "gid-01" "cid-01" "/tmp/algo_source"
zig build run -- apigw-save-plugin-widgets-local "/tmp/apigw-plugins" "gid-01" "/tmp/widgets_source"
zig build run -- apigw-save-plugin-inputs-local "/tmp/apigw-plugins" "gid-01" "/tmp/inputs_source"
zig build run -- apigw-get-plugin-zip-local "/tmp/apigw-plugins" "gid-01"
zig build run -- apigw-get-plugin-algorithm-zip-local "/tmp/apigw-plugins" "gid-01" "cid-01"
zig build run -- apigw-save-plugin-mdx-bundles-local "/tmp/apigw-plugins" "gid-01" "/tmp/mdx_bundles_source"
zig build run -- apigw-get-plugin-mdx-bundle-local "/tmp/apigw-plugins" "gid-01" "cid-01"
zig build run -- apigw-get-plugin-mdx-summary-bundle-local "/tmp/apigw-plugins" "gid-01" "cid-01"
zig build run -- apigw-backup-plugin-local "/tmp/apigw-plugins" "gid-01" "/tmp/plugin_backup"
zig build run -- apigw-delete-plugin-local "/tmp/apigw-plugins" "gid-01"
zig build run -- apigw get-plugin-widgets-zip-local "/tmp/apigw-plugins" "gid-01"
zig build run -- apigw get-plugin-mdx-bundle-local "/tmp/apigw-plugins" "gid-01" "cid-01"
zig build run -- apigw backup-plugin-local "/tmp/apigw-plugins" "gid-01" "/tmp/plugin_backup"
zig build run -- worker-config
zig build run -- worker-once
zig build run -- worker-once --ack
zig build run -- worker-once --reclaim --min-idle-ms 1000 --start 0-0
zig build run -- metrics-gap 0.88 0.81
zig build run -- normalize-plugin-gid "AIVERIFY.Stock   Reports "
# optional explicit Mojo FFI shared library path:
AIVERIFY_MOJO_FFI_LIB=/abs/path/libaiverify_mojo_ffi.dylib zig build run -- metrics-gap 0.88 0.81
```

Run Mojo smoke tests:

```bash
mojo run mojo/tests/smoke.mojo
```

Run parity smoke:

```bash
./scripts/parity_smoke.sh test-engine-version
./scripts/parity_smoke.sh test-engine-version-flag
./scripts/parity_smoke.sh worker-config
./scripts/parity_smoke.sh apigw-config
./scripts/parity_smoke.sh apigw-config-hana
./scripts/parity_smoke.sh apigw-validate-gid-cid
./scripts/parity_smoke.sh apigw-check-valid-filename
./scripts/parity_smoke.sh apigw-sanitize-filename
./scripts/parity_smoke.sh apigw-check-relative-to-base
./scripts/parity_smoke.sh apigw-file-utils
./scripts/parity_smoke.sh apigw-plugin-storage-layout
./scripts/parity_smoke.sh apigw-data-storage-layout
./scripts/parity_smoke.sh apigw-artifact-io-local
./scripts/parity_smoke.sh apigw-model-dataset-io-local
./scripts/parity_smoke.sh apigw-plugin-archive-io-local
./scripts/parity_smoke.sh apigw-plugin-archive-io-local-hana
./scripts/parity_smoke.sh apigw-plugin-mdx-bundle-io-local
./scripts/parity_smoke.sh apigw-plugin-backup-local
./scripts/parity_smoke.sh worker-once-reclaim
./scripts/parity_smoke.sh worker-once-reclaim-ack
./scripts/parity_smoke.sh worker-once-reclaim-empty
./scripts/parity_smoke.sh worker-once-reclaim-invalid-start
./scripts/parity_smoke.sh metrics-gap
./scripts/parity_smoke.sh normalize-plugin-gid
```

For HANA queue-backed environments, skip valkey-stream reclaim smoke:

```bash
AIVERIFY_QUEUE_BACKEND=hana ./scripts/parity_smoke.sh worker-once-reclaim
```

Run APIGW config parity with a HANA URI profile:

```bash
AIVERIFY_HANA_DB_URI='hana+hdbcli://SYSTEM:Password123@hana.local:39041' ./scripts/parity_smoke.sh apigw-config-hana
```

Run APIGW plugin archive local I/O parity with a HANA URI profile:

```bash
AIVERIFY_HANA_DB_URI='hana+hdbcli://SYSTEM:Password123@hana.local:39041' ./scripts/parity_smoke.sh apigw-plugin-archive-io-local-hana
```

Run optional Mojo FFI-on smoke (requires shared library path):

```bash
./scripts/build_mojo_ffi.sh
AIVERIFY_MOJO_FFI_LIB=/abs/path/libaiverify_mojo_ffi.dylib ./scripts/mojo_ffi_smoke.sh
```

## Parity Tracker

| Module Area | Status | Runtime Path |
|---|---|---|
| Zig entrypoint + command routing | Ported (phase 1) | Zig |
| Python bridge execution per component | Ported (phase 1) | Zig -> Python |
| Test engine CLI handling (`test-engine`, `run test-engine`) | Ported (phase 2) | Zig |
| Test engine version parity smoke | Ported (phase 2) | Zig + Python |
| API gateway startup/config preflight (`apigw-config`) | Ported (phase 3) | Zig |
| API gateway HANA DB profile parity smoke (`apigw-config-hana`) | Ported (phase 8) | Zig + Python |
| APIGW gid/cid validator helper (`apigw validate-gid-cid`) | Ported (phase 11) | Zig |
| APIGW file/path safety helpers (`apigw check-valid-filename`, `apigw sanitize-filename`, `apigw check-relative-to-base`) | Ported (phase 12) | Zig |
| APIGW file utility helpers (`apigw check-file-size`, `apigw append-filename`, `apigw get-suffix`, `apigw get-stem`) | Ported (phase 13) | Zig |
| APIGW plugin storage layout helpers (`apigw plugin-storage-layout`) | Ported (phase 14) | Zig |
| APIGW data storage layout helpers (`apigw data-storage-layout`) | Ported (phase 15) | Zig |
| APIGW artifact save/get local I/O (`apigw save-artifact`, `apigw get-artifact`) | Ported (phase 16) | Zig |
| APIGW model/dataset save/get/delete local I/O (`apigw save-model-local`, `apigw get-model-local`, `apigw delete-model-local`, `apigw save-dataset-local`, `apigw get-dataset-local`, `apigw delete-dataset-local`) including directory zip/hash sidecars | Ported (phase 18) | Zig |
| APIGW plugin archive save/get/delete local I/O (`apigw save-plugin-local`, `apigw save-plugin-algorithm-local`, `apigw save-plugin-widgets-local`, `apigw save-plugin-inputs-local`, `apigw get-plugin-zip-local`, `apigw get-plugin-algorithm-zip-local`, `apigw get-plugin-widgets-zip-local`, `apigw get-plugin-inputs-zip-local`, `apigw delete-plugin-local`) | Ported (phase 19) | Zig |
| APIGW plugin archive local I/O HANA profile parity smoke (`apigw-plugin-archive-io-local-hana`) | Ported (phase 20) | Zig + Python |
| APIGW plugin MDX bundle save/get local I/O (`apigw save-plugin-mdx-bundles-local`, `apigw get-plugin-mdx-bundle-local`, `apigw get-plugin-mdx-summary-bundle-local`) | Ported (phase 21) | Zig |
| APIGW plugin backup local I/O (`apigw backup-plugin-local`) | Ported (phase 22) | Zig |
| APIGW plugin storage layout S3 mode (`apigw plugin-storage-layout s3`) | Ported (phase 23) | Zig + Python |
| Worker startup/config loading preflight (`worker-config`) | Ported (phase 3) | Zig |
| Worker single-cycle stream orchestration (`worker-once`) | Ported (phase 4) | Zig |
| Worker pending recovery/reclaim (`worker-once --reclaim`, `XAUTOCLAIM`) | Ported (phase 5) | Zig |
| Mojo deterministic primitives | Ported (initial) | Mojo |
| Metrics helper bridge (`metrics-gap`) | Ported (phase 6) | Zig -> Mojo FFI (fallback Zig native) |
| Plugin GID normalization bridge (`normalize-plugin-gid`) | Ported (phase 7) | Zig -> Mojo FFI (fallback Zig native) |
| Worker reclaim parity smoke matrix (`worker-once-reclaim`, `worker-once-reclaim-ack`, `worker-once-reclaim-empty`) | Ported (phase 8) | Zig + Python + Valkey |
| Worker reclaim invalid-start error-path parity smoke (`worker-once-reclaim-invalid-start`) | Ported (phase 10) | Zig + Python + Valkey |
| Deterministic helper parity smoke (`metrics-gap`, `normalize-plugin-gid`) | Ported (phase 7) | Zig + Python |
| Non-blocking parity smoke expansion (`worker-config`, `apigw-config`) | Ported (phase 7) | Zig + Python |
| CI Mojo FFI build + FFI-on smoke (`scripts/build_mojo_ffi.sh`, `scripts/mojo_ffi_smoke.sh`) | Ported (phase 9) | GitHub Actions + Mojo CLI |
| API gateway internals | Pending | Python |
| Test engine worker internals | Pending | Python |
| Test engine internals | Pending | Python |

## Next Porting Order

1. Continue APIGW storage operation migration for non-local backends (S3 plugin save/get/backup I/O bridge).
2. Expand HANA-specific parity coverage for remaining APIGW local storage operations.
