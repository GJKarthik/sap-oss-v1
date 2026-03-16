# Third-Party Licenses

This repository contains three distinct software components under different licenses.
The boundaries are described below.

---

## 1. Upstream Elasticsearch (Java)

**Directories:** `server/`, `modules/`, `plugins/`, `libs/`, `x-pack/`, `qa/`,
`distribution/`, `rest-api-spec/`, `build-conventions/`, `build-tools/`,
`build-tools-internal/`, `docs/`, `benchmarks/`, `client/`, `test/`, `gradle/`

**License:**

- Files **outside** `x-pack/` are available under any of:
  - **Elastic License 2.0** (`licenses/ELASTIC-LICENSE-2.0.txt`)
  - **Server Side Public License v1 (SSPL)** (`licenses/SSPL-1.0+.txt`)
  - **GNU Affero General Public License v3 (AGPL v3)** (`licenses/AGPL-3.0.txt`)
- Files **inside** `x-pack/` are available under **Elastic License 2.0 only**.

Refer to the license header at the top of each source file for the exact
applicable license. The canonical license texts are in the `licenses/` directory.

Upstream copyright: © Elasticsearch B.V.

---

## 2. SAP Python Layer (Apache-2.0)

**Directories:** `mcp_server/`, `sap_openai_server/`, `agent/`, `middleware/`,
`mangle/`, `data_products/`, `scripts/`

**Top-level files:** `Dockerfile.sap`

**License:** Apache License, Version 2.0

```
Copyright 2024 SAP SE or an SAP affiliate company

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
```

---

## 3. KùzuDB Embedded Graph Database (MIT)

**Directory:** `kuzu/`

**License:** MIT License

```
Copyright (c) 2022 Kùzu Authors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

The full license text is also available at `kuzu/LICENSE`.

---

## License Compatibility Summary

| Component | License | Can be combined? |
|---|---|---|
| Elasticsearch (outside x-pack) | ELv2 / SSPL / AGPL v3 | SAP layer communicates over REST API only; no Java source modification |
| Elasticsearch (x-pack) | Elastic License 2.0 | Same — no source modification |
| SAP Python layer | Apache-2.0 | Compatible with MIT (KùzuDB); SAP layer imports kuzu via the `kuzu` PyPI package |
| KùzuDB | MIT | Compatible with Apache-2.0 |

The SAP Python container (`Dockerfile.sap`) does **not** bundle any Elasticsearch
Java bytecode; it communicates with a separately-deployed Elasticsearch cluster
over its standard HTTP REST API. The `kuzu` Python package (MIT) is installed
as a pip dependency and used in-process by `mcp_server/server.py` and
`graph/kuzu_store.py`.
