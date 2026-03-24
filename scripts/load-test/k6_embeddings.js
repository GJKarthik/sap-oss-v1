/**
 * k6 Load Test: /v1/embeddings
 *
 * Tests embedding generation throughput through the Zig gateway.
 * Embeddings are latency-sensitive (no generation loop) and expose
 * batching and KV cache behaviour differently from chat completions.
 *
 * Usage:
 *   k6 run scripts/load-test/k6_embeddings.js
 *   k6 run --vus 100 --duration 60s scripts/load-test/k6_embeddings.js
 *   k6 run --env BASE_URL=http://localhost:8080 scripts/load-test/k6_embeddings.js
 *
 * Scenarios:
 *   - single_input: 1 string per request (baseline)
 *   - batch_input:  16 strings per request (throughput test)
 *   - high_vus:     200 VUs, single inputs (concurrency ceiling)
 */

import http from "k6/http";
import { check, sleep } from "k6";
import { Rate, Trend, Counter } from "k6/metrics";

// ---------------------------------------------------------------------------
// Custom metrics
// ---------------------------------------------------------------------------
const errorRate = new Rate("embed_error_rate");
const latencyTrend = new Trend("embed_latency_ms", true);
const embeddingsThroughput = new Counter("total_embeddings_generated");

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------
const BASE_URL = __ENV.BASE_URL || "http://localhost:8000";
const API_KEY = __ENV.API_KEY || "";
const EMBED_MODEL = __ENV.EMBED_MODEL || "text-embedding-ada-002";

const HEADERS = {
  "Content-Type": "application/json",
  ...(API_KEY ? { Authorization: `Bearer ${API_KEY}` } : {}),
};

// ---------------------------------------------------------------------------
// Test scenarios
// ---------------------------------------------------------------------------
export const options = {
  scenarios: {
    single_input: {
      executor: "constant-vus",
      vus: 20,
      duration: "30s",
      startTime: "0s",
      tags: { scenario: "single_input" },
    },
    batch_input: {
      executor: "constant-vus",
      vus: 20,
      duration: "30s",
      startTime: "35s",
      tags: { scenario: "batch_input_16" },
    },
    high_vus: {
      executor: "ramping-vus",
      startVUs: 20,
      stages: [
        { duration: "10s", target: 200 },
        { duration: "20s", target: 200 },
        { duration: "10s", target: 0 },
      ],
      startTime: "70s",
      tags: { scenario: "high_vus" },
    },
  },
  thresholds: {
    embed_error_rate: ["rate<0.01"],
    embed_latency_ms: ["p(95)<2000"], // embeddings should be < 2s at p95
    http_req_failed: ["rate<0.01"],
    http_req_duration: ["p(50)<500", "p(95)<2000"],
  },
};

// ---------------------------------------------------------------------------
// Sample texts for embedding
// ---------------------------------------------------------------------------
const TEXTS = [
  "SAP HANA is an in-memory, column-oriented relational database management system.",
  "The transformer architecture uses self-attention to process sequences in parallel.",
  "Kubernetes orchestrates containerised workloads across a cluster of nodes.",
  "Vector similarity search enables semantic retrieval over embedding spaces.",
  "Flash Attention reduces memory complexity from O(N²) to O(N) using tiling.",
  "The Mangle rule engine derives routing decisions from Datalog-style predicates.",
  "Token-bucket rate limiting allows burst traffic while enforcing average throughput.",
  "PagedKV caching stores attention keys and values in fixed-size memory blocks.",
  "INT8 quantisation reduces model weights from 32-bit to 8-bit integers.",
  "The circuit breaker pattern prevents cascading failures in distributed systems.",
  "SAP AI Core provides managed inference infrastructure on SAP BTP.",
  "GGUF is a file format for storing quantised large language model weights.",
  "Continuous batching amortises inference setup cost across concurrent requests.",
  "SIMD vectorisation processes multiple data elements with a single CPU instruction.",
  "The OpenAI API format has become the de facto standard for LLM service interfaces.",
  "Retrieval-augmented generation grounds LLM responses in retrieved document chunks.",
];

// ---------------------------------------------------------------------------
// Single-input embedding request
// ---------------------------------------------------------------------------
export default function () {
  const scenario = __ENV.K6_SCENARIO_NAME || "single_input";
  let input;

  if (scenario === "batch_input_16") {
    // Batch of 16 texts
    input = TEXTS.slice(0, 16);
  } else {
    // Single text
    input = TEXTS[Math.floor(Math.random() * TEXTS.length)];
  }

  const payload = JSON.stringify({
    model: EMBED_MODEL,
    input: input,
  });

  const t0 = Date.now();
  const res = http.post(`${BASE_URL}/v1/embeddings`, payload, {
    headers: HEADERS,
    timeout: "30s",
  });
  const elapsed = Date.now() - t0;

  latencyTrend.add(elapsed);

  const ok = check(res, {
    "status 200": (r) => r.status === 200,
    "has data array": (r) => {
      try {
        const body = JSON.parse(r.body);
        return Array.isArray(body.data) && body.data.length > 0;
      } catch {
        return false;
      }
    },
    "embedding is float array": (r) => {
      try {
        const body = JSON.parse(r.body);
        return (
          Array.isArray(body.data[0].embedding) &&
          body.data[0].embedding.length > 0
        );
      } catch {
        return false;
      }
    },
  });

  errorRate.add(!ok);

  if (ok) {
    try {
      const body = JSON.parse(res.body);
      embeddingsThroughput.add(body.data.length);
    } catch {
      // non-fatal
    }
  }

  sleep(0.05); // 50ms think time — embeddings are fast
}

// ---------------------------------------------------------------------------
// Setup and teardown
// ---------------------------------------------------------------------------
export function setup() {
  const res = http.get(`${BASE_URL}/health`, { timeout: "10s" });
  if (res.status !== 200) {
    console.error(`Health check failed at ${BASE_URL}/health`);
  }
  const modelsRes = http.get(`${BASE_URL}/v1/models`, {
    headers: HEADERS,
    timeout: "10s",
  });
  console.log(`Available models: ${modelsRes.body}`);
  return { baseUrl: BASE_URL };
}

export function teardown(data) {
  console.log(`Embeddings load test complete against ${data.baseUrl}`);
}
