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

const server = http.createServer(async (req, res) => {
  if (req.url === "/health") {
    return json(res, 200, {
      status: requireConfig() ? "healthy" : "degraded",
      service: "cap-llm-openai-server",
      configReady: Boolean(requireConfig()),
    });
  }

  if (!requireConfig()) {
    return json(res, 503, { error: { message: "AI Core config missing", type: "config_error", code: 503 } });
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
      return json(res, 502, { error: { message: String(e.message || e), type: "api_error", code: 502 } });
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
      return json(res, 502, { error: { message: String(e.message || e), type: "api_error", code: 502 } });
    }
  }

  return json(res, 404, { error: "Not found" });
});

server.listen(PORT, () => {
  console.log(`CAP OpenAI server on :${PORT}`);
});
