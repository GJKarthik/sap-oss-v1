# Security Guide — Model Optimizer Service

## Authentication

The API supports Bearer token authentication via the `Authorization` header.

| Environment Variable     | Default | Description                                    |
|--------------------------|---------|------------------------------------------------|
| `MODELOPT_API_KEY`       | *(empty)* | Default API key for the service              |
| `MODELOPT_REQUIRE_AUTH`  | `false` | Set to `true` to enforce authentication        |

When `MODELOPT_REQUIRE_AUTH=true`, every request must include a valid API key:

```bash
curl -H "Authorization: Bearer $MODELOPT_API_KEY" http://localhost:8001/health
```

## Secrets Management

### Development

Use a `.env` file (never committed — listed in `.gitignore`):

```bash
cp ../../.env.example .env
# Edit .env with your values
```

### Production

**Do not use `.env` files in production.** Use one of:

| Method                  | When to use                          |
|-------------------------|--------------------------------------|
| **Kubernetes Secrets**  | K8s deployments                      |
| **HashiCorp Vault**     | Multi-service / enterprise           |
| **AWS Secrets Manager** | AWS-hosted deployments               |
| **Docker secrets**      | Docker Swarm deployments             |
| **Environment variables** | Simple single-host deployments     |

Example with Kubernetes:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: modelopt-secrets
type: Opaque
stringData:
  MODELOPT_API_KEY: "mo-your-secret-key-here"
  HF_TOKEN: "hf_your-token-here"
```

## CORS

Origins are restricted to an explicit allowlist (required when `allow_credentials=True`).

Configure via the `ALLOWED_ORIGINS` environment variable:

```bash
# Comma-separated list of allowed origins
ALLOWED_ORIGINS=http://localhost:4200,https://your-domain.com
```

## Rate Limiting

Built-in rate limiting is applied to mutating endpoints (`POST /jobs`, `DELETE /jobs/{id}`).
Default: **60 requests per minute** per client IP.

## Request Tracking

Every response includes an `X-Request-ID` header. Pass your own `X-Request-ID` in the
request to correlate logs across services, or one will be generated automatically.

## API Key Storage (Frontend)

The Angular UI stores API keys in `sessionStorage` (not `localStorage`), so keys are:
- Scoped to the current browser tab
- Cleared when the tab is closed
- Not shared across tabs

This limits the exposure window from XSS attacks. For higher security, consider
implementing HTTP-only cookie-based sessions with a backend-for-frontend (BFF) pattern.

## Checklist

- [ ] `MODELOPT_REQUIRE_AUTH=true` in production
- [ ] API key rotated regularly
- [ ] `ALLOWED_ORIGINS` set to your actual domain(s)
- [ ] TLS termination configured (nginx, cloud LB, or `--ssl-keyfile` flag)
- [ ] No secrets in source code or Docker images
- [ ] `HF_TOKEN` set only if downloading gated models

