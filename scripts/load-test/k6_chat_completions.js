/**
 * k6 Load Test: /v1/chat/completions
 *
 * Tests the full chat-completion path through the Zig gateway:
 *   nginx (8000) → vllm (8080) → TOON inference → response
 *
 * Usage:
 *   k6 run scripts/load-test/k6_chat_completions.js
 *   k6 run --vus 50 --duration 60s scripts/load-test/k6_chat_completions.js
 *   k6 run --env BASE_URL=http://localhost:8080 scripts/load-test/k6_chat_completions.js
 *
 * Scenarios (default):
 *   - 10 VUs for 30s  (baseline / warm-up)
 *   - 50 VUs for 60s  (moderate load)
 *   - 200 VUs for 30s (peak / stress)
 */

import http from "k6/http";
import { check, sleep } from "k6";
import { Rate, Trend, Counter } from "k6/metrics";

// ---------------------------------------------------------------------------
// Custom metrics
// ---------------------------------------------------------------------------
const errorRate = new Rate("chat_error_rate");
const ttftTrend = new Trend("time_to_first_token_ms", true); // ms
const e2eLatency = new Trend("e2e_latency_ms", true);
const tokensThroughput = new Counter("total_tokens_generated");

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------
const BASE_URL = __ENV.BASE_URL || "http://localhost:8000";
const API_KEY = __ENV.API_KEY || "";
const MODEL = __ENV.MODEL || "default";

const HEADERS = {
  "Content-Type": "application/json",
  ...(API_KEY ? { Authorization: `Bearer ${API_KEY}` } : {}),
};

// ---------------------------------------------------------------------------
// Test scenarios
// ---------------------------------------------------------------------------
export const options = {
  scenarios: {
    baseline: {
      executor: "constant-vus",
      vus: 10,
      duration: "30s",
      startTime: "0s",
      tags: { scenario: "baseline" },
    },
    moderate: {
      executor: "constant-vus",
      vus: 50,
      duration: "60s",
      startTime: "35s",
      tags: { scenario: "moderate" },
    },
    stress: {
      executor: "ramping-vus",
      startVUs: 50,
      stages: [
        { duration: "15s", target: 200 },
        { duration: "15s", target: 200 },
        { duration: "10s", target: 0 },
      ],
      startTime: "100s",
      tags: { scenario: "stress" },
    },
  },
  thresholds: {
    // P0 thresholds — any breach indicates a scalability problem
    chat_error_rate: ["rate<0.01"], // < 1% errors
    e2e_latency_ms: ["p(95)<30000"], // 95th percentile < 30s (LLM can be slow)
    http_req_failed: ["rate<0.01"],
    http_req_duration: ["p(50)<15000", "p(95)<30000"],
  },
};

// ---------------------------------------------------------------------------
// Sample prompts — varied to avoid KV prefix cache trivialising the test
// ---------------------------------------------------------------------------
const PROMPTS = [
  "What is the capital of France?",
  "Explain the difference between REST and GraphQL in one paragraph.",
  "Write a Python function to compute fibonacci numbers.",
  "What are the main benefits of using Kubernetes for microservice deployments?",
  "Summarize the key principles of the CAP theorem.",
  "How does Flash Attention reduce memory complexity in transformer models?",
  "What is SAP HANA and what makes it different from traditional databases?",
  "Describe the token-bucket rate limiting algorithm.",
  "What is the difference between INT8 and FP16 quantisation for LLM inference?",
  "Explain the circuit breaker pattern in distributed systems.",
];

// ---------------------------------------------------------------------------
// Main test function
// ---------------------------------------------------------------------------
export default function () {
  const prompt = PROMPTS[Math.floor(Math.random() * PROMPTS.length)];
  const maxTokens = Math.floor(Math.random() * 100) + 50; // 50–150 tokens

  const payload = JSON.stringify({
    model: MODEL,
    messages: [{ role: "user", content: prompt }],
    max_tokens: maxTokens,
    temperature: 0.7,
    stream: false,
  });

  const t0 = Date.now();
  const res = http.post(`${BASE_URL}/v1/chat/completions`, payload, {
    headers: HEADERS,
    timeout: "60s",
  });
  const elapsed = Date.now() - t0;

  e2eLatency.add(elapsed);

  const ok = check(res, {
    "status 200": (r) => r.status === 200,
    "has choices": (r) => {
      try {
        const body = JSON.parse(r.body);
        return Array.isArray(body.choices) && body.choices.length > 0;
      } catch {
        return false;
      }
    },
    "has content": (r) => {
      try {
        const body = JSON.parse(r.body);
        return (
          body.choices[0].message &&
          body.choices[0].message.content &&
          body.choices[0].message.content.length > 0
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
      if (body.usage && body.usage.completion_tokens) {
        tokensThroughput.add(body.usage.completion_tokens);
      }
    } catch {
      // non-fatal
    }
  }

  sleep(0.1); // 100ms think time between requests
}

// ---------------------------------------------------------------------------
// Health check before load test
// ---------------------------------------------------------------------------
export function setup() {
  const res = http.get(`${BASE_URL}/health`, { timeout: "10s" });
  if (res.status !== 200) {
    console.error(
      `Health check failed: ${res.status} ${res.body}. Is the gateway running at ${BASE_URL}?`
    );
  }
  console.log(`Load test target: ${BASE_URL}`);
  console.log(`Model: ${MODEL}`);
  return { baseUrl: BASE_URL };
}

export function teardown(data) {
  console.log(`Load test complete against ${data.baseUrl}`);
  console.log(
    "Check Prometheus metrics at http://localhost:9090/metrics for gateway telemetry."
  );
}
