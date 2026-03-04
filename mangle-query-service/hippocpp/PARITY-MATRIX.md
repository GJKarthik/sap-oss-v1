# HippoCPP Parity Matrix

Generated: 2026-03-03 09:25:55 UTC

## Snapshot

- Kuzu source: `/Users/user/Documents/sap-oss/mangle-query-service/kuzu`
- HippoCPP source: `/Users/user/Documents/sap-oss/mangle-query-service/hippocpp`
- Upstream mirror parity: **PASS**
- Mirror detail: hippocpp/upstream/kuzu is byte-for-byte identical to kuzu.

## Zig Conversion Coverage

- Kuzu implementation files (`.cpp`): **735**
- HippoCPP Zig implementation files (`.zig`): **1251**
- Exact relative path matches: **735** (100.0%)
- Kuzu-only paths: **0**
- HippoCPP-only paths: **516**

## Module Matrix

| Module | Kuzu C++ | HippoCPP Zig | Delta (Zig-C++) | Exact path matches | Match % |
|---|---:|---:|---:|---:|---:|
| `binder` | 72 | 129 | 57 | 72 | 100.0 |
| `buffer_manager` | 0 | 1 | 1 | 0 | n/a |
| `c_api` | 10 | 15 | 5 | 10 | 100.0 |
| `catalog` | 14 | 41 | 27 | 14 | 100.0 |
| `common` | 78 | 137 | 59 | 78 | 100.0 |
| `evaluator` | 0 | 2 | 2 | 0 | n/a |
| `expression` | 0 | 1 | 1 | 0 | n/a |
| `expression_evaluator` | 11 | 19 | 8 | 11 | 100.0 |
| `extension` | 6 | 12 | 6 | 6 | 100.0 |
| `function` | 154 | 239 | 85 | 154 | 100.0 |
| `graph` | 5 | 6 | 1 | 5 | 100.0 |
| `main` | 16 | 19 | 3 | 16 | 100.0 |
| `native` | 0 | 1 | 1 | 0 | n/a |
| `optimizer` | 15 | 50 | 35 | 15 | 100.0 |
| `parser` | 31 | 59 | 28 | 31 | 100.0 |
| `planner` | 83 | 129 | 46 | 83 | 100.0 |
| `processor` | 164 | 230 | 66 | 164 | 100.0 |
| `root` | 0 | 1 | 1 | 0 | n/a |
| `storage` | 73 | 146 | 73 | 73 | 100.0 |
| `testing` | 0 | 2 | 2 | 0 | n/a |
| `transaction` | 3 | 12 | 9 | 3 | 100.0 |

## Kuzu-Only Gaps By Module

```text
```

## Sample Missing Kuzu Paths (first 120)

```text
```
