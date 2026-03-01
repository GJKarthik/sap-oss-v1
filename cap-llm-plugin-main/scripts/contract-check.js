#!/usr/bin/env node
// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2023 SAP SE

/**
 * Contract drift detection script.
 *
 * Validates that:
 * 1. The CDS service definition compiles without errors.
 * 2. Every action in the CDS CSN has a corresponding path in the OpenAPI spec.
 * 3. Every path in the OpenAPI spec has a corresponding action in the CDS CSN.
 * 4. The Angular client models.ts exports match the OpenAPI component schemas.
 *
 * Usage: node scripts/contract-check.js
 * Exit code 0 = in sync, 1 = drift detected.
 */

const { execSync } = require("child_process");
const fs = require("fs");
const path = require("path");

const ROOT = path.resolve(__dirname, "..");
let exitCode = 0;

function fail(msg) {
  console.error(`❌ ${msg}`);
  exitCode = 1;
}

function pass(msg) {
  console.log(`✅ ${msg}`);
}

// ── 1. Validate CDS compiles ────────────────────────────────────────
console.log("\n── CDS Compilation ──");
let csn;
try {
  const csnJson = execSync("npx cdsc toCsn srv/llm-service.cds 2>/dev/null", {
    cwd: ROOT,
    encoding: "utf-8",
  });
  csn = JSON.parse(csnJson);
  pass("CDS definition compiles successfully");
} catch (e) {
  fail("CDS definition failed to compile: " + e.message);
  process.exit(1);
}

// ── 2. Extract CDS actions ──────────────────────────────────────────
const SERVICE_PREFIX = "CAPLLMPluginService.";
const cdsActions = Object.keys(csn.definitions)
  .filter(
    (k) =>
      k.startsWith(SERVICE_PREFIX) &&
      csn.definitions[k].kind === "action",
  )
  .map((k) => k.replace(SERVICE_PREFIX, ""));

console.log(`\n── CDS Actions (${cdsActions.length}) ──`);
cdsActions.forEach((a) => console.log(`   ${a}`));

// ── 3. Load OpenAPI spec ────────────────────────────────────────────
console.log("\n── OpenAPI Spec ──");
const openapiPath = path.join(ROOT, "docs/api/openapi.yaml");
if (!fs.existsSync(openapiPath)) {
  fail("OpenAPI spec not found at docs/api/openapi.yaml");
  process.exit(1);
}

const openapiContent = fs.readFileSync(openapiPath, "utf-8");

// Simple YAML path extraction (paths start with /)
const openapiPaths = [];
for (const line of openapiContent.split("\n")) {
  const match = line.match(/^\s{2}\/([\w]+):/);
  if (match) {
    openapiPaths.push(match[1]);
  }
}

console.log(`OpenAPI paths (${openapiPaths.length}):`);
openapiPaths.forEach((p) => console.log(`   /${p}`));

// ── 4. Cross-check CDS ↔ OpenAPI ───────────────────────────────────
console.log("\n── Cross-check ──");

for (const action of cdsActions) {
  if (openapiPaths.includes(action)) {
    pass(`CDS action "${action}" has OpenAPI path`);
  } else {
    fail(`CDS action "${action}" missing from OpenAPI spec`);
  }
}

for (const p of openapiPaths) {
  if (cdsActions.includes(p)) {
    pass(`OpenAPI path "/${p}" has CDS action`);
  } else {
    fail(`OpenAPI path "/${p}" has no CDS action`);
  }
}

// ── 5. Check Angular client models exist ────────────────────────────
console.log("\n── Angular Client ──");
const clientDir = path.join(ROOT, "generated/angular-client");
const requiredFiles = ["models.ts", "cap-llm-plugin.service.ts", "index.ts"];

for (const file of requiredFiles) {
  const filePath = path.join(clientDir, file);
  if (fs.existsSync(filePath)) {
    pass(`Angular client file: ${file}`);
  } else {
    fail(`Angular client file missing: ${file}`);
  }
}

// Check that every OpenAPI schema has a matching interface in models.ts
const modelsPath = path.join(clientDir, "models.ts");
if (fs.existsSync(modelsPath)) {
  const modelsContent = fs.readFileSync(modelsPath, "utf-8");
  const openapiSchemas = [];
  let inSchemas = false;
  for (const line of openapiContent.split("\n")) {
    if (line.match(/^\s{2}schemas:/)) {
      inSchemas = true;
      continue;
    }
    if (inSchemas) {
      const schemaMatch = line.match(/^\s{4}(\w+):/);
      if (schemaMatch) {
        openapiSchemas.push(schemaMatch[1]);
      }
      if (line.match(/^\s{2}\w/) && !line.match(/^\s{4}/)) {
        inSchemas = false;
      }
    }
  }

  for (const schema of openapiSchemas) {
    if (modelsContent.includes(`export interface ${schema}`)) {
      pass(`Schema "${schema}" found in Angular models`);
    } else {
      fail(`Schema "${schema}" missing from Angular models`);
    }
  }
}

// ── Summary ─────────────────────────────────────────────────────────
console.log("\n── Result ──");
if (exitCode === 0) {
  console.log("✅ All contract checks passed — CDS, OpenAPI, and Angular client are in sync.\n");
} else {
  console.error("❌ Contract drift detected. Update the specs and client to match.\n");
}

process.exit(exitCode);
