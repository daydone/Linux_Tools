# Validating Production Ingress Connectivity

Quick guide to validate that production ingresses are responding correctly.

## Critical Endpoints

### Production
- **API Health**: `https://pdx1-prod-api.telnoc.com/health` (should return HTTP 200)
- **Desk UI**: `https://pdx1-prod-desk.telnoc.com/` (should return HTTP 200)
- **Chirpstack Gateway Bridge**: `ws://10.0.99.80:3001/` (should return WebSocket 101 upgrade)

### QA
- **Display UI**: `https://pdx1-qa-display.telnoc.com/` (should return HTTP 200)
- **Chirpstack Gateway Bridge**: `ws://10.0.98.80:3001/` (should return WebSocket 101 upgrade)

## Validate Chirpstack WebSocket on 3001

The chirpstack gateway bridge runs on an external IP (LoadBalancer) rather than a standard ingress. To test the WebSocket connection:

```bash
# Test prod chirpstack (10.0.99.80:3001)
curl -i -N \
  -H "Connection: upgrade" \
  -H "Upgrade: websocket" \
  -H "Sec-WebSocket-Key: SGVsbG8sIHdvcmxkIQ==" \
  -H "Sec-WebSocket-Version: 13" \
  "http://10.0.99.80:3001/"

# Expected response (HTTP 101 Switching Protocols)
# HTTP/1.1 101 Switching Protocols
# Upgrade: websocket
# Connection: Upgrade
# Sec-WebSocket-Accept: <hash>
```

If you get HTTP 101 with the upgrade headers, the WebSocket endpoint is healthy.

## Run Full Validation

Use the automated validation script:

```bash
./scripts/validate-ingress-connectivity.sh
```

This tests all critical endpoints and returns exit code 0 if all pass, exit code 1 if any fail.

## Troubleshooting

If an ingress is down:

```bash
# Check ingress definitions
kubectl get ingress -n prod -n qa

# Check Traefik pods and logs
kubectl get pods -n ingress-traefik
kubectl logs -n ingress-traefik -l app=traefik --tail=50

# Check LoadBalancer services
kubectl get svc -A | grep 10.0.99.80
kubectl get svc -A | grep 10.0.98.80

# Describe the service to see endpoints
kubectl describe svc -n prod <service-name>
```
