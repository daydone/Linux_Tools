# Production Port-Forward Setup

## Problem
Production services (API, Display, UI) need external access via port-forwarding on worker node 10.0.96.26 because:
- Ingress/LoadBalancer services not working reliably
- Need stable external access to: API (3000), Display (3001), UI (3002)

## Solution
Run persistent port-forward keeper script on worker node that auto-restarts them if they die.

## Setup on Worker Node 10.0.96.26

### Port-Forward Keeper Script
Location: `/tmp/pf-keeper-final.sh`

```bash
#!/bin/bash
export KUBECONFIG=/tmp/kubeconfig
NAMESPACE="prod"

while true; do
  # Check and restart API port-forward
  if ! netstat -tuln 2>/dev/null | grep -q ":3000 "; then
    echo "[$(date)] Restarting API port-forward..."
    lsof -i :3000 -sTCP:LISTEN -t 2>/dev/null | xargs kill -9 2>/dev/null || true
    nohup kubectl -n $NAMESPACE port-forward svc/noctel-prod-api-service 3000:3000 --address 0.0.0.0 > /tmp/api-pf.log 2>&1 &
  fi

  # Check and restart Display port-forward
  if ! netstat -tuln 2>/dev/null | grep -q ":3001 "; then
    echo "[$(date)] Restarting Display port-forward..."
    lsof -i :3001 -sTCP:LISTEN -t 2>/dev/null | xargs kill -9 2>/dev/null || true
    nohup kubectl -n $NAMESPACE port-forward svc/noctel-prod-display-service 3001:3001 --address 0.0.0.0 > /tmp/display-pf.log 2>&1 &
  fi

  # Check and restart UI port-forward (fixed: 3002:3002 not 3002:8080)
  if ! netstat -tuln 2>/dev/null | grep -q ":3002 "; then
    echo "[$(date)] Restarting UI port-forward..."
    lsof -i :3002 -sTCP:LISTEN -t 2>/dev/null | xargs kill -9 2>/dev/null || true
    nohup kubectl -n $NAMESPACE port-forward svc/noctel-prod-ui-service 3002:3002 --address 0.0.0.0 > /tmp/ui-pf.log 2>&1 &
  fi

  sleep 10
done
```

### To Start
```bash
ssh 10.0.96.26
nohup /tmp/pf-keeper-final.sh > /tmp/pf-keeper-run.log 2>&1 &
```

### To Verify
```bash
# Check if keeper is running
ps aux | grep pf-keeper | grep -v grep

# Check if port-forwards are listening
netstat -tuln | grep -E ":3000|:3001|:3002"

# Test connectivity
curl http://10.0.96.26:3000/health
curl http://10.0.96.26:3001/
curl http://10.0.96.26:3002/
```

## Services Available
- **API**: http://10.0.96.26:3000 → noctel-prod-api-service:3000
- **Display**: http://10.0.96.26:3001 → noctel-prod-display-service:3001
- **UI/Portal**: http://10.0.96.26:3002 → noctel-prod-ui-service:3002

## Known Issues

### ETCD Cluster Health
The cluster has been experiencing etcd failures that cause cascading pod restarts:
- Symptom: Pods timing out trying to reach API server at 10.43.0.1:443
- Root cause: etcd becoming unresponsive (HDD saturation issue noted 2026-03-29)
- Workaround: Scale down non-critical namespaces to reduce API load

### API Server Connectivity
Pods trying to reach service IP 10.43.0.1:443 timeout due to Cilium routing issues. Local connections via node IPs (10.0.96.22/23/24:6443) work fine.

## Cluster Cleanup Done
- Scaled dev/qa deployments and statefulsets to 0
- Disabled Rancher monitoring/fleet/CAPI components (high restart churn)
- Disabled cert-manager and metallb
- Disabled prometheus-node-exporter daemonset (641 restarts)
- Result: Reduced from 600+ restarts cluster-wide to stable state

## Future Work
- Fix etcd cluster stability (investigate 2026-03-29 SSD upgrade requirement)
- Fix Cilium service IP routing to allow pods to reach 10.43.0.1:443
- Restore Rancher/monitoring components once API is stable
