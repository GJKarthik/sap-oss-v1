# Deployment Runbook

This runbook provides step-by-step procedures for deploying, operating, and troubleshooting the SAP OSS AI Platform.

---

## Table of Contents

1. [Prerequisites](#prerequisites)
2. [Deployment Procedures](#deployment-procedures)
3. [Health Checks](#health-checks)
4. [Monitoring & Alerting](#monitoring--alerting)
5. [Troubleshooting](#troubleshooting)
6. [Rollback Procedures](#rollback-procedures)
7. [Scaling Operations](#scaling-operations)
8. [Security Operations](#security-operations)
9. [Backup & Recovery](#backup--recovery)

---

## Prerequisites

### Required Access
- [ ] SAP BTP Cloud Foundry space with `SpaceDeveloper` role
- [ ] Kubernetes cluster access (kubectl configured)
- [ ] Docker registry push access
- [ ] XSUAA service instance credentials
- [ ] HANA Cloud connection credentials

### Required Tools
```bash
# Verify tool versions
cf --version        # >= 8.0
kubectl version     # >= 1.28
docker --version    # >= 24.0
helm version        # >= 3.12
```

### Environment Variables
```bash
export BTP_SUBDOMAIN="your-subdomain"
export CF_API="https://api.cf.${BTP_REGION}.hana.ondemand.com"
export KUBECONFIG="/path/to/kubeconfig"
export DOCKER_REGISTRY="your-registry.io"
```

---

## Deployment Procedures

### 1. Pre-Deployment Checklist

```bash
# 1. Verify all tests pass
cd ai-core-streaming
zig build test

# 2. Check for security vulnerabilities
# (Snyk integration - requires API key)
# snyk test

# 3. Validate configuration
cat conf/production.yaml | yq eval '.' -

# 4. Verify XSUAA binding
cf services | grep xsuaa
```

### 2. Docker Image Build

```bash
# Build production image
docker build \
  --build-arg VERSION=$(git describe --tags) \
  --build-arg BUILD_DATE=$(date -u +"%Y-%m-%dT%H:%M:%SZ") \
  -t ${DOCKER_REGISTRY}/ai-core-streaming:$(git describe --tags) \
  -f Dockerfile .

# Push to registry
docker push ${DOCKER_REGISTRY}/ai-core-streaming:$(git describe --tags)
```

### 3. Kubernetes Deployment

```bash
# Create namespace if needed
kubectl create namespace ai-platform --dry-run=client -o yaml | kubectl apply -f -

# Apply secrets
kubectl create secret generic xsuaa-credentials \
  --from-file=credentials.json=/path/to/xsuaa-credentials.json \
  --namespace ai-platform \
  --dry-run=client -o yaml | kubectl apply -f -

# Deploy using Helm
helm upgrade --install ai-core-streaming ./deploy/helm \
  --namespace ai-platform \
  --set image.tag=$(git describe --tags) \
  --set replicas=3 \
  --set resources.requests.memory=2Gi \
  --set resources.requests.cpu=1000m \
  --wait \
  --timeout 10m
```

### 4. Cloud Foundry Deployment

```bash
# Login to CF
cf login -a ${CF_API} -o ${CF_ORG} -s ${CF_SPACE}

# Push application
cf push ai-core-streaming \
  -f manifest.yml \
  --var version=$(git describe --tags)

# Bind services
cf bind-service ai-core-streaming xsuaa-ai-platform
cf bind-service ai-core-streaming hana-cloud-ai

# Restart to pick up bindings
cf restart ai-core-streaming
```

### 5. Post-Deployment Verification

```bash
# Check health endpoints
curl -s https://${APP_URL}/health | jq .
curl -s https://${APP_URL}/ready | jq .

# Verify authentication
TOKEN=$(cf oauth-token | awk '{print $2}')
curl -H "Authorization: Bearer ${TOKEN}" https://${APP_URL}/api/v1/status

# Check logs for errors
cf logs ai-core-streaming --recent | grep -i error
kubectl logs -l app=ai-core-streaming -n ai-platform --tail=100
```

---

## Health Checks

### Endpoints

| Endpoint | Purpose | Expected Response |
|----------|---------|-------------------|
| `/health` | Liveness probe | `{"status":"healthy"}` |
| `/ready` | Readiness probe | `{"status":"healthy","components":[...]}` |
| `/metrics` | Prometheus metrics | Text format metrics |

### Health Check Commands

```bash
# Quick health check
curl -sf http://localhost:8080/health && echo "OK" || echo "FAIL"

# Detailed readiness check
curl -s http://localhost:8080/ready | jq '.components[] | select(.status != "healthy")'

# Check all replicas
kubectl get pods -l app=ai-core-streaming -n ai-platform \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.phase}{"\n"}{end}'
```

### Kubernetes Probes Configuration

```yaml
livenessProbe:
  httpGet:
    path: /health
    port: 8080
  initialDelaySeconds: 10
  periodSeconds: 15
  failureThreshold: 3

readinessProbe:
  httpGet:
    path: /ready
    port: 8080
  initialDelaySeconds: 5
  periodSeconds: 10
  failureThreshold: 3
```

---

## Monitoring & Alerting

### Key Metrics to Monitor

| Metric | Warning Threshold | Critical Threshold |
|--------|-------------------|-------------------|
| Request latency P99 | > 500ms | > 2000ms |
| Error rate | > 1% | > 5% |
| Memory usage | > 70% | > 90% |
| CPU usage | > 70% | > 90% |
| Rate limit rejections | > 100/min | > 1000/min |

### Prometheus Queries

```promql
# Request rate
sum(rate(http_requests_total{app="ai-core-streaming"}[5m]))

# Error rate
sum(rate(http_requests_total{app="ai-core-streaming",status=~"5.."}[5m])) 
/ sum(rate(http_requests_total{app="ai-core-streaming"}[5m]))

# Latency P99
histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket{app="ai-core-streaming"}[5m])) by (le))

# Memory usage
container_memory_usage_bytes{container="ai-core-streaming"} 
/ container_spec_memory_limit_bytes{container="ai-core-streaming"}
```

### Alerting Rules

```yaml
groups:
  - name: ai-core-streaming
    rules:
      - alert: HighErrorRate
        expr: |
          sum(rate(http_requests_total{app="ai-core-streaming",status=~"5.."}[5m])) 
          / sum(rate(http_requests_total{app="ai-core-streaming"}[5m])) > 0.05
        for: 5m
        labels:
          severity: critical
        annotations:
          summary: "High error rate detected"
          description: "Error rate is {{ $value | humanizePercentage }}"

      - alert: HighLatency
        expr: |
          histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket{app="ai-core-streaming"}[5m])) by (le)) > 2
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "High latency detected"
```

---

## Troubleshooting

### Common Issues

#### 1. Pod CrashLoopBackOff

```bash
# Check pod events
kubectl describe pod <pod-name> -n ai-platform

# Check logs
kubectl logs <pod-name> -n ai-platform --previous

# Common causes:
# - Missing XSUAA credentials
# - Invalid configuration
# - OOM (Out of Memory)
```

#### 2. Authentication Failures

```bash
# Verify XSUAA binding
cf env ai-core-streaming | grep -A 20 VCAP_SERVICES

# Test token validation
curl -v -H "Authorization: Bearer <token>" https://${APP_URL}/api/v1/test

# Check JWKS endpoint
curl -s https://${XSUAA_URL}/token_keys | jq .
```

#### 3. Rate Limiting Issues

```bash
# Check rate limit headers
curl -i https://${APP_URL}/api/v1/endpoint | grep X-RateLimit

# Expected headers:
# X-RateLimit-Limit: 100
# X-RateLimit-Remaining: 95
# X-RateLimit-Reset: 60
```

#### 4. Memory Issues

```bash
# Check memory usage
kubectl top pods -l app=ai-core-streaming -n ai-platform

# Check for OOMKilled
kubectl get pods -n ai-platform -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.containerStatuses[0].lastState.terminated.reason}{"\n"}{end}'

# Increase memory limits if needed
kubectl patch deployment ai-core-streaming -n ai-platform --patch '
spec:
  template:
    spec:
      containers:
      - name: ai-core-streaming
        resources:
          limits:
            memory: 4Gi
'
```

#### 5. Connection Timeouts

```bash
# Check network policies
kubectl get networkpolicies -n ai-platform

# Test connectivity
kubectl run test-pod --rm -it --image=curlimages/curl -- sh
# Inside pod: curl -v http://ai-core-streaming:8080/health

# Check service endpoints
kubectl get endpoints ai-core-streaming -n ai-platform
```

---

## Rollback Procedures

### Kubernetes Rollback

```bash
# Check deployment history
kubectl rollout history deployment/ai-core-streaming -n ai-platform

# Rollback to previous version
kubectl rollout undo deployment/ai-core-streaming -n ai-platform

# Rollback to specific revision
kubectl rollout undo deployment/ai-core-streaming -n ai-platform --to-revision=3

# Verify rollback
kubectl rollout status deployment/ai-core-streaming -n ai-platform
```

### Helm Rollback

```bash
# List releases
helm history ai-core-streaming -n ai-platform

# Rollback to previous
helm rollback ai-core-streaming -n ai-platform

# Rollback to specific revision
helm rollback ai-core-streaming 3 -n ai-platform
```

### Cloud Foundry Rollback

```bash
# List recent deployments
cf revisions ai-core-streaming

# Rollback
cf rollback ai-core-streaming --version <revision>
```

---

## Scaling Operations

### Horizontal Scaling

```bash
# Scale replicas
kubectl scale deployment ai-core-streaming -n ai-platform --replicas=5

# Auto-scaling based on CPU
kubectl autoscale deployment ai-core-streaming -n ai-platform \
  --min=2 --max=10 --cpu-percent=70
```

### Vertical Scaling

```bash
# Update resource requests/limits
kubectl patch deployment ai-core-streaming -n ai-platform --patch '
spec:
  template:
    spec:
      containers:
      - name: ai-core-streaming
        resources:
          requests:
            memory: 4Gi
            cpu: 2000m
          limits:
            memory: 8Gi
            cpu: 4000m
'
```

---

## Security Operations

### Rotate Secrets

```bash
# Generate new credentials
# (Usually done through SAP BTP cockpit for XSUAA)

# Update Kubernetes secret
kubectl create secret generic xsuaa-credentials \
  --from-file=credentials.json=/path/to/new-credentials.json \
  --namespace ai-platform \
  --dry-run=client -o yaml | kubectl apply -f -

# Trigger rolling restart
kubectl rollout restart deployment/ai-core-streaming -n ai-platform
```

### Audit Logs

```bash
# View auth-related logs
kubectl logs -l app=ai-core-streaming -n ai-platform | grep -i "auth\|jwt\|token"

# Export audit logs
kubectl logs -l app=ai-core-streaming -n ai-platform --since=24h > audit-$(date +%Y%m%d).log
```

---

## Backup & Recovery

### Configuration Backup

```bash
# Backup Helm values
helm get values ai-core-streaming -n ai-platform > backup/helm-values-$(date +%Y%m%d).yaml

# Backup secrets
kubectl get secret xsuaa-credentials -n ai-platform -o yaml > backup/secrets-$(date +%Y%m%d).yaml
```

### Disaster Recovery

```bash
# Full namespace restore
kubectl apply -f backup/namespace-backup.yaml

# Verify restoration
kubectl get all -n ai-platform
```

---

## Contacts

| Role | Contact | Escalation Time |
|------|---------|-----------------|
| On-Call Engineer | oncall@example.com | Immediate |
| Platform Team | platform-team@example.com | 15 minutes |
| Security Team | security@example.com | 30 minutes |

---

## Revision History

| Date | Version | Author | Changes |
|------|---------|--------|---------|
| 2026-03-01 | 1.0.0 | AI Platform Team | Initial release |