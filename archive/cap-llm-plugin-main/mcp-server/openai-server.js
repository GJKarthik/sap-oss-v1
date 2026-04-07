const http = require("http");
const https = require("https");

const PORT = Number(process.env.PORT || 8080);
const cfg = {
  clientId: process.env.AICORE_CLIENT_ID || "",
  clientSecret: process.env.AICORE_CLIENT_SECRET || "",
  authUrl: process.env.AICORE_AUTH_URL || "",
  baseUrl: process.env.AICORE_BASE_URL || process.env.AICORE_SERVICE_URL || "",
  resourceGroup: process.env.AICORE_RESOURCE_GROUP || "default",
  chatDeploymentId: process.env.AICORE_CHAT_DEPLOYMENT_ID || "",
  embeddingDeploymentId: process.env.AICORE_EMBEDDING_DEPLOYMENT_ID || "",
};

let cached = { token: null, exp: 0 };
let cachedDeployments = null;
const PROBE_INTERVAL_MS = Number(process.env.AICORE_PROBE_INTERVAL_MS || 300000);
const ENFORCE_PROBE_READY = String(process.env.AICORE_ENFORCE_PROBE_READY || "true") === "true";
const entitlementProbe = {
  ready: false,
  status: "starting",
  message: "Probe not completed yet.",
  checkedAt: null,
  details: {},
};

function json(res, code, body) {
  res.writeHead(code, { "content-type": "application/json" });
  res.end(JSON.stringify(body));
}

function parseBody(req) {
  return new Promise((resolve) => {
    let data = "";
    req.on("data", (chunk) => (data += chunk));
    req.on("end", () => {
      try {
        resolve(JSON.parse(data || "{}"));
      } catch {
        resolve({});
      }
    });
  });
}

function requireConfig() {
  return cfg.clientId && cfg.clientSecret && cfg.authUrl && cfg.baseUrl;
}

function classifyAiCoreError(error) {
  const raw = String(error && error.message ? error.message : error || "");
  if (raw.includes("HTTP 403")) {
    return {
      type: "rbac_denied",
      statusCode: 503,
      message:
        "AI Core entitlement check failed (RBAC denied). Validate service key roles, resource group, and deployment access.",
      raw,
    };
  }
  if (raw.includes("HTTP 401")) {
    return {
      type: "auth_failed",
      statusCode: 503,
      message: "AI Core authentication failed. Verify client id/secret and auth URL.",
      raw,
    };
  }
  if (raw.includes("HTTP 404")) {
    return {
      type: "deployment_or_endpoint_missing",
      statusCode: 503,
      message: "AI Core deployment or endpoint was not found. Verify deployment IDs and base URL.",
      raw,
    };
  }
  return {
    type: "upstream_error",
    statusCode: 502,
    message: "AI Core request failed.",
    raw,
  };
}

function requestJson(urlString, options, body) {
  const url = new URL(urlString);
  const lib = url.protocol === "https:" ? https : http;
  return new Promise((resolve, reject) => {
    const req = lib.request(
      {
        hostname: url.hostname,
        port: url.port || (url.protocol === "https:" ? 443 : 80),
        path: `${url.pathname}${url.search}`,
        method: options.method || "GET",
        headers: options.headers || {},
      },
      (res) => {
        let data = "";
        res.on("data", (chunk) => (data += chunk));
        res.on("end", () => {
          let parsed = data;
          try {
            parsed = JSON.parse(data);
          } catch {}
          if (!res.statusCode || res.statusCode < 200 || res.statusCode >= 300) {
            return reject(new Error(`HTTP ${res.statusCode}: ${typeof parsed === "string" ? parsed : JSON.stringify(parsed)}`));
          }
          resolve(parsed);
        });
      }
    );
    req.on("error", reject);
    if (body !== undefined) {
      if (typeof body === "string") req.write(body);
      else req.write(JSON.stringify(body));
    }
    req.end();
  });
}

async function getToken() {
  if (cached.token && Date.now() < cached.exp) return cached.token;
  const auth = Buffer.from(`${cfg.clientId}:${cfg.clientSecret}`).toString("base64");
  const tokenRes = await requestJson(cfg.authUrl, {
    method: "POST",
    headers: {
      authorization: `Basic ${auth}`,
      "content-type": "application/x-www-form-urlencoded",
    },
  }, "grant_type=client_credentials");
  const expiresIn = tokenRes.expires_in || 3600;
  cached = { token: tokenRes.access_token, exp: Date.now() + (expiresIn - 60) * 1000 };
  return cached.token;
}

async function aiCore(path, method, body) {
  const token = await getToken();
  return requestJson(new URL(path, cfg.baseUrl).toString(), {
    method,
    headers: {
      authorization: `Bearer ${token}`,
      "AI-Resource-Group": cfg.resourceGroup,
      "content-type": "application/json",
    },
  }, body);
}

async function getDeployments() {
  if (cachedDeployments) return cachedDeployments;
  const out = await aiCore("/v2/lm/deployments", "GET");
  cachedDeployments = out.resources || [];
  return cachedDeployments;
}

function pickDeployment(deployments, preferred) {
  if (preferred) {
    const exact = deployments.find((d) => d.id === preferred);
    if (exact) return exact;
  }
  return deployments[0];
}

async function runEntitlementProbe() {
  const now = new Date().toISOString();
  if (!requireConfig()) {
    entitlementProbe.ready = false;
    entitlementProbe.status = "config_missing";
    entitlementProbe.message = "AI Core configuration is incomplete.";
    entitlementProbe.checkedAt = now;
    entitlementProbe.details = {
      configReady: false,
    };
    return;
  }

  try {
    cachedDeployments = null;
    const deployments = await getDeployments();
    const deploymentIds = deployments.map((d) => d.id);
    const missingPreferred = [];
    if (cfg.chatDeploymentId && !deploymentIds.includes(cfg.chatDeploymentId)) {
      missingPreferred.push({ kind: "chat", id: cfg.chatDeploymentId });
    }
    if (cfg.embeddingDeploymentId && !deploymentIds.includes(cfg.embeddingDeploymentId)) {
      missingPreferred.push({ kind: "embedding", id: cfg.embeddingDeploymentId });
    }

    const deployment = pickDeployment(deployments, cfg.chatDeploymentId);
    let inferenceProbe = { attempted: false, ok: false, deploymentId: deployment ? deployment.id : null, note: "" };
    if (deployment) {
      try {
        inferenceProbe.attempted = true;
        await aiCore(`/v2/inference/deployments/${deployment.id}/chat/completions`, "POST", {
          messages: [{ role: "user", content: "healthcheck" }],
          max_tokens: 1,
        });
        inferenceProbe.ok = true;
        inferenceProbe.note = "Inference entitlement probe passed.";
      } catch (probeError) {
        const classified = classifyAiCoreError(probeError);
        inferenceProbe.ok = false;
        inferenceProbe.note = `${classified.message} ${classified.raw}`;
      }
    } else {
      inferenceProbe.note = "No deployment available for inference probe.";
    }

    entitlementProbe.ready = missingPreferred.length === 0 && deployments.length > 0 && inferenceProbe.ok;
    entitlementProbe.status = entitlementProbe.ready
      ? "ok"
      : (missingPreferred.length > 0 ? "deployment_mismatch" : "inference_entitlement_failed");
    entitlementProbe.message = entitlementProbe.ready
      ? "AI Core entitlement probe passed."
      : (missingPreferred.length > 0
        ? "Configured deployment IDs are not available in AI Core."
        : "AI Core deployment is discoverable but inference entitlement failed.");
    entitlementProbe.checkedAt = now;
    entitlementProbe.details = {
      configReady: true,
      deploymentCount: deployments.length,
      missingPreferred,
      inferenceProbe,
    };
  } catch (error) {
    const classified = classifyAiCoreError(error);
    entitlementProbe.ready = false;
    entitlementProbe.status = classified.type;
    entitlementProbe.message = classified.message;
    entitlementProbe.checkedAt = now;
    entitlementProbe.details = {
      configReady: true,
      lastError: classified.raw,
    };
  }
}

const server = http.createServer(async (req, res) => {
  if (req.url === "/health") {
    return json(res, 200, {
      status: requireConfig() ? "healthy" : "degraded",
      service: "cap-llm-openai-server",
      configReady: Boolean(requireConfig()),
      entitlementReady: entitlementProbe.ready,
      entitlementStatus: entitlementProbe.status,
      entitlementMessage: entitlementProbe.message,
      entitlementCheckedAt: entitlementProbe.checkedAt,
    });
  }

  if (req.url === "/health/details") {
    return json(res, 200, {
      status: requireConfig() ? "healthy" : "degraded",
      service: "cap-llm-openai-server",
      config: {
        configReady: Boolean(requireConfig()),
        chatDeploymentConfigured: Boolean(cfg.chatDeploymentId),
        embeddingDeploymentConfigured: Boolean(cfg.embeddingDeploymentId),
      },
      entitlementProbe,
    });
  }

  if (!requireConfig()) {
    return json(res, 503, { error: { message: "AI Core config missing", type: "config_error", code: 503 } });
  }

  if (ENFORCE_PROBE_READY && !entitlementProbe.ready) {
    return json(res, 503, {
      error: {
        message: `${entitlementProbe.message} Check /health/details for diagnostics.`,
        type: "entitlement_error",
        code: 503,
      },
    });
  }

  if (req.url === "/v1/chat/completions" && req.method === "POST") {
    try {
      const body = await parseBody(req);
      const deployments = await getDeployments();
      const deployment = pickDeployment(deployments, cfg.chatDeploymentId || body.model);
      if (!deployment) return json(res, 400, { error: { message: "No deployment available", type: "api_error", code: 400 } });
      const result = await aiCore(`/v2/inference/deployments/${deployment.id}/chat/completions`, "POST", body);
      return json(res, 200, result);
    } catch (e) {
      const classified = classifyAiCoreError(e);
      return json(res, classified.statusCode, {
        error: { message: `${classified.message} ${classified.raw}`, type: "api_error", code: classified.statusCode },
      });
    }
  }

  if (req.url === "/v1/embeddings" && req.method === "POST") {
    try {
      const body = await parseBody(req);
      const deployments = await getDeployments();
      const deployment = pickDeployment(deployments, cfg.embeddingDeploymentId || body.model);
      if (!deployment) return json(res, 400, { error: { message: "No embedding deployment available", type: "api_error", code: 400 } });
      const result = await aiCore(`/v2/inference/deployments/${deployment.id}/embeddings`, "POST", body);
      return json(res, 200, result);
    } catch (e) {
      const classified = classifyAiCoreError(e);
      return json(res, classified.statusCode, {
        error: { message: `${classified.message} ${classified.raw}`, type: "api_error", code: classified.statusCode },
      });
    }
  }

  return json(res, 404, { error: "Not found" });
});

server.listen(PORT, () => {
  console.log(`CAP OpenAI server on :${PORT}`);
});

runEntitlementProbe().catch(() => {});
setInterval(() => {
  runEntitlementProbe().catch(() => {});
}, PROBE_INTERVAL_MS);
