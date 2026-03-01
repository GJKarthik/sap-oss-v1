# SAP AI Suite — Software Bill of Materials (SBOM)

> Generated: 2026-03-01  
> Scope: vendored / embedded dependencies that are **not** managed by a package manager.  
> Package-manager-resolved deps (npm, Go modules, Gradle) are covered by their respective lock files.

---

## 1. ai-core-streaming — Zig vendored deps

### 1.1 `deps/llama/llama.zig`

| Field | Value |
|---|---|
| **Name** | Custom Zig LLaMA inference engine |
| **Origin** | SAP-internal port of llama.cpp concepts to Zig |
| **GGUF format version** | 2–3 (constants `GGUF_VERSION_3 = 3`) |
| **Architectures supported** | LLaMA, Mistral, Phi, Gemma, Qwen, DeepSeek, CodeLlama |
| **License** | Apache-2.0 (see `REUSE.toml`) |
| **SPDX-ID** | `LicenseRef-SAP-internal` |
| **Upstream reference** | Algorithmic parity with [ggerganov/llama.cpp](https://github.com/ggerganov/llama.cpp) (MIT) |
| **Known CVEs** | None at time of inventory |
| **Notes** | Pure-Zig CPU kernels; Metal/CUDA offload via `deps/cuda/cuda_kernels.h`. No binary blobs. |

### 1.2 `deps/cuda/cuda_kernels.h`

| Field | Value |
|---|---|
| **Name** | CUDA CPU-fallback kernel header |
| **Origin** | SAP-internal; CPU-only `static inline` implementations |
| **CUDA toolkit version targeted** | 12.x (SM architecture probing returns 0 on CPU path) |
| **License** | Apache-2.0 (see `REUSE.toml`) |
| **SPDX-ID** | `LicenseRef-SAP-internal` |
| **Upstream reference** | API surface mirrors NVIDIA CUDA Runtime API 12.x |
| **Known CVEs** | N/A — CPU fallback only; no NVIDIA binary linked |
| **Notes** | Header-only; no `.cu` translation unit required. NCCL-compatible tensor-parallel stubs included. |

---

## 2. ai-core-pal — Mojo stdlib dependency

### 2.1 Mojo standard library (implicit)

| Field | Value |
|---|---|
| **Name** | Mojo standard library |
| **Version** | Determined at build time by `magic` / `modular` toolchain version |
| **License** | [Modular Community License](https://www.modular.com/legal/licenses) |
| **SPDX-ID** | `LicenseRef-Modular-Community` |
| **Modules used** | `collections.Dict`, `python.Python`, `sys.env_get_string` |
| **Source files** | `mojo/src/toonspy/*.mojo`, `mojo/src/ffi_exports.mojo` |
| **Known CVEs** | None at time of inventory |
| **Notes** | No vendored copy; resolved by Mojo toolchain at compile time. Pin toolchain version in CI. |

### 2.2 Python interop (via `python.Python`)

| Field | Value |
|---|---|
| **Name** | CPython runtime (embedded via Mojo FFI) |
| **Version** | ≥ 3.10 (required by Mojo Python interop) |
| **License** | PSF-2.0 |
| **SPDX-ID** | `PSF-2.0` |
| **Notes** | Not vendored; must be present in the execution environment. |

---

## 3. elasticsearch-main — Gradle-managed deps (key subset)

> Full dependency graph is in `build-tools/src/main/resources/org/elasticsearch/gradle/VersionProperties.properties`.

| Component | Version | License | SPDX-ID |
|---|---|---|---|
| Elasticsearch | 9.4.0 | Elastic License 2.0 / AGPL-3.0-only / SSPL-1.0 | `LicenseRef-Elastic-2.0` |
| Apache Lucene | 10.3.2 | Apache-2.0 | `Apache-2.0` |
| OpenJDK (bundled JDK) | 25.0.2+10 (Adoptium) | GPL-2.0-with-classpath-exception | `GPL-2.0-with-classpath-exception` |
| Jackson Databind | 2.15.0 | Apache-2.0 | `Apache-2.0` |
| SnakeYAML | 2.0 | Apache-2.0 | `Apache-2.0` |
| Spatial4j | 0.7 | Apache-2.0 | `Apache-2.0` |
| JTS Topology Suite | 1.20.0 | EPL-2.0 | `EPL-2.0` |

---

## 4. Action items

| Priority | Item |
|---|---|
| HIGH | Pin Mojo toolchain version in `ai-core-pal/Dockerfile` and CI workflow |
| HIGH | Add `LICENSES/` directory to `ai-core-streaming/zig/deps/` per REUSE spec |
| MEDIUM | Run `reuse lint` on all repos to verify SPDX headers |
| MEDIUM | Subscribe to Elastic security advisories for Elasticsearch 9.x |
| LOW | Evaluate upgrading Jackson to 2.17.x (CVE-2024-* fixes) |

