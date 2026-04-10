# Training Workbench on SAP BTP Kyma

This manifest set deploys the `training-webcomponents-ngx` product as one public
origin behind a Kyma APIRule:

- `training-gateway` is the only public entrypoint
- `training-web` serves the Angular application
- `training-api` serves the FastAPI backend
- `/api/*`, `/ws/*`, and `/ocr/*` stay same-origin through the gateway

## Files

- `training-runtime-secrets.template.yaml`
- `training-stack.yaml`
- `training-edge-auth-secrets.template.yaml`
- `training-edge-auth-overlay.yaml`

## Prerequisites

1. Push the application images to your registry:
   - `ghcr.io/your-org/sap-oss-angular-shell:latest`
   - `ghcr.io/your-org/sap-oss-api-server:latest`
2. Create an image pull secret named `sap-oss-registry` in `sap-ai-services`.
3. Ensure these internal dependency services exist in the same namespace, or update the URLs in `training-stack.yaml`:
   - `vllm` on port `8080`
   - `model-optimizer` on port `8001`
   - `arabic-ocr` on port `8060`

Example image pull secret:

```bash
kubectl create namespace sap-ai-services
kubectl create secret docker-registry sap-oss-registry \
  --namespace sap-ai-services \
  --docker-server=ghcr.io \
  --docker-username="$GITHUB_USERNAME" \
  --docker-password="$GITHUB_TOKEN"
```

## Deploy

```bash
kubectl apply -f training-runtime-secrets.template.yaml
kubectl apply -f training-stack.yaml
kubectl rollout status deployment/training-api -n sap-ai-services
kubectl rollout status deployment/training-web -n sap-ai-services
kubectl rollout status deployment/training-gateway -n sap-ai-services
```

## Secure Browser Access on BTP

For SAP BTP browser access, use the edge-auth overlay after the base stack.
This keeps the SPA same-origin and lets IAS or XSUAA handle sign-in at the edge.

```bash
kubectl apply -f training-edge-auth-secrets.template.yaml
kubectl apply -f training-edge-auth-overlay.yaml
kubectl rollout status deployment/training-edge-auth -n sap-ai-services
```

Before applying:

1. Replace placeholder values in `training-runtime-secrets.template.yaml`.
2. Replace these placeholders in `training-stack.yaml`:
   - `YOUR_KYMA_DOMAIN`
   - `your-hana-instance.hanacloud.ondemand.com`
   - `https://your-auth-url/oauth/token`
   - `https://your-ai-core-base-url`
   - image names if you use a different registry
3. Set the frontend runtime contract in `training-web-runtime-config`:
   - `apiBaseUrl: '/api'` for same-origin through the gateway
   - `requireAuth: false` for open access, or `true` if you front this with your own auth flow
4. For the edge-auth overlay, replace these placeholders in `training-edge-auth-*`:
   - `YOUR_IDENTITY_ISSUER`
   - `YOUR_KYMA_DOMAIN`
   - client credentials and cookie secret

## Notes

- The API uses a PVC named `training-api-data` for the SQLite operational store.
- HANA and AI Core secrets are injected from Kubernetes Secret refs, not baked into manifests.
- The frontend runtime config is mounted from a ConfigMap so you can change `apiBaseUrl` and `requireAuth` without rebuilding the image.
- The secure overlay changes the runtime contract to `authMode: 'edge'` and moves browser sign-in/out to `/oauth2/*`.
- Use an IAS or XSUAA OIDC issuer URL for `OAUTH2_PROXY_OIDC_ISSUER_URL`.
