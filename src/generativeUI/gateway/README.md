# Gateway

Edge layer for the generativeUI suite. Consists of an **nginx reverse proxy**, a **FastAPI health aggregator**, and static **placeholder pages**.

## Components

| Path | Role |
|------|------|
| `nginx.conf.template` | nginx config with env-var substitution for upstream routing |
| `health/` | FastAPI service that polls upstream health endpoints and reports aggregate status |
| `placeholders/sac/` | Static stub page served when the SAC app is not deployed |
| `placeholders/ui5/` | Static stub page served when the UI5 workspace is not deployed |

## Running

The gateway is started via the root `docker-compose.yml` as the `suite-gateway` service. It is not intended to run standalone.

```bash
# From src/generativeUI/
docker compose up suite-gateway
```

## Health Aggregator

The `health/` directory contains a minimal FastAPI app (`main.py`) that:
- Accepts a list of upstream health URLs via environment variables.
- Polls each URL periodically.
- Exposes `/health` returning the aggregate result.

### Dependencies

See `health/requirements.txt`: FastAPI, uvicorn, httpx.
