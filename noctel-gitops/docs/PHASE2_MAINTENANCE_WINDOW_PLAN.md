# Phase 2: Hardening Implementation Plan — Maintenance Window

**Status:** Ready for scheduling  
**Last Updated:** 2026-06-01  
**Execution Model:** One item per maintenance window (non-disruptive rollout)

---

## Overview

Phase 2 implements remaining hardening items identified in the PDX1 production audit. Items are sequenced for **independent execution** — each can be deployed in isolation during a maintenance window without blocking others.

**Total Items:** 7 hardening changes  
**Estimated Duration:** 30 min per item + 15 min validation  
**Risk Level:** LOW-MEDIUM (all non-disruptive, changes can be rolled back)

---

## Hardening Items (Execution Order)

### 1. 🔒 RabbitMQ Credential Rotation (CRITICAL — C3)

**Purpose:** Rotate from default `admin`/`admin123` to strong random credentials  
**Impact:** Medium (all worker/notify/API pods restart during sync)  
**Rollback:** Revert commit, services auto-restart with old credentials

**Files to Create/Update:**
- `rabbitmq/environments/pdx1-prod-values.yaml` — new password
- All `noctel-worker-*/environments/pdx1-prod-values.yaml` — RABBITMQ_URL
- All `noctel-notify-*/environments/pdx1-prod-values.yaml` — RABBITMQ_URL
- All `noctel-api-*/environments/pdx1-prod-values.yaml` — RABBITMQ_URL (if applicable)

**Procedure:**
```bash
# 1. Generate password
NEW_PASS=$(openssl rand -base64 32 | tr -d '=' | cut -c1-24)
echo "New password: $NEW_PASS"

# 2. Update rabbitmq/environments/pdx1-prod-values.yaml
auth:
  username: admin
  password: $NEW_PASS

# 3. Update RABBITMQ_URL in all affected services
# Find all: grep -r "RABBITMQ_URL" --include="*.yaml" manifests/noctel-*
# Replace: amqp://admin:admin123@ → amqp://admin:$NEW_PASS@

# 4. Commit and push
git add rabbitmq/ manifests/noctel-*/
git commit -m "Rotate RabbitMQ credentials from default admin/admin123 to secure random"
git push

# 5. Watch ArgoCD sync (3-5 min) and verify logs
kubectl logs -n prod -l app=noctel-worker-cleanup -f | grep -i "amqp\|connected"
```

**Validation:**
- ✅ All worker/notify pods Running after sync
- ✅ No AMQP connection errors in logs
- ✅ Queue depth stays healthy (no backlog)

---

### 2. 🛡️ Add LimitRange for Namespace Resource Defaults (HIGH — H3.1)

**Purpose:** Set default CPU/memory requests & limits to prevent OOMKill and throttling  
**Impact:** Low (no pod restarts, affects only newly created pods initially)  
**Rollback:** Delete LimitRange, existing pods unaffected

**Files to Create:**
- `networking/pdx1/prod/prod-limitrange.yaml`
- `networking/pdx1/qa/qa-limitrange.yaml`
- `networking/pdx1/dev/dev-limitrange.yaml`

**Template (prod):**
```yaml
apiVersion: v1
kind: LimitRange
metadata:
  name: default-limits
  namespace: prod
spec:
  limits:
  - type: Container
    default:
      cpu: 500m
      memory: 512Mi
    defaultRequest:
      cpu: 100m
      memory: 128Mi
    max:
      cpu: 4000m
      memory: 4Gi
    min:
      cpu: 10m
      memory: 32Mi
  - type: Pod
    max:
      cpu: 8000m
      memory: 8Gi
```

**Procedure:**
```bash
# 1. Create LimitRange files for prod, qa, dev (use templates above)
# 2. Commit
git add networking/pdx1/prod/prod-limitrange.yaml \
         networking/pdx1/qa/qa-limitrange.yaml \
         networking/pdx1/dev/dev-limitrange.yaml
git commit -m "Add LimitRange with default CPU/memory requests and limits"
git push

# 3. Verify
kubectl get limitrange -n prod,qa,dev
kubectl describe limitrange -n prod default-limits
```

**Validation:**
- ✅ LimitRange exists in all 3 namespaces
- ✅ New pods created after this have resource requests/limits applied
- ✅ Existing pods unaffected (no restart)

---

### 3. 🚨 Add NetworkPolicy: Default Deny Ingress (MEDIUM — M1.1)

**Purpose:** Implement least-privilege network access (default deny, then explicit allows)  
**Impact:** Medium (risk: blocks unplanned pod-to-pod traffic)  
**Rollback:** Delete NetworkPolicy, traffic restores immediately

**Files to Create:**
- `networking/pdx1/prod/default-deny-ingress.yaml`
- `networking/pdx1/qa/qa-default-deny-ingress.yaml`
- `networking/pdx1/dev/dev-default-deny-ingress.yaml`

**Template (prod):**
```yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: default-deny-ingress
  namespace: prod
spec:
  description: "Deny all ingress traffic unless explicitly allowed"
  endpointSelector: {}  # Applies to all pods
  policyTypes:
  - Ingress
```

**Procedure:**
```bash
# 1. Create default-deny-ingress files
# 2. Deploy to DEV FIRST (lowest risk)
git add networking/pdx1/dev/dev-default-deny-ingress.yaml
git commit -m "Add NetworkPolicy: default-deny-ingress to dev namespace"
git push

# 3. Wait 5 min, verify no traffic breaks
kubectl get pods -n dev  # All should be Running
kubectl logs -n dev <any-pod> | grep -i "connection refused\|network"  # No new connection errors

# 4. If dev is healthy, deploy to QA
git add networking/pdx1/qa/qa-default-deny-ingress.yaml
git commit -m "Add NetworkPolicy: default-deny-ingress to qa namespace"
git push

# 5. Wait 5 min, verify no traffic breaks
# 6. Finally deploy to PROD
git add networking/pdx1/prod/default-deny-ingress.yaml
git commit -m "Add NetworkPolicy: default-deny-ingress to prod namespace"
git push
```

**Validation:**
- ✅ Default-deny policies exist in all 3 namespaces
- ✅ No unexpected connection errors in pod logs
- ✅ Existing service-to-service traffic still works (was already working before policy)

---

### 4. 🔐 Add Security Contexts to Deployment Templates (CRITICAL — C2)

**Purpose:** Force pods to run as non-root user (UID 1001) instead of root  
**Impact:** Medium (requires pod restarts to apply)  
**Rollback:** Revert chart templates, pods restart as root

**Files to Update:**
- All `noctel-api-*/charts/templates/deployment.yaml` (~25 services)
- Any other services with `securityContext` in values but not rendered in templates

**Template Addition (in deployment.yaml spec):**
```yaml
spec:
  {{- with .Values.securityContext }}
  securityContext:
    runAsUser: {{ .runAsUser }}
    runAsGroup: {{ .runAsGroup }}
    fsGroup: {{ .fsGroup }}
    runAsNonRoot: {{ .runAsNonRoot }}
  {{- end }}
  containers:
  - name: ...
```

**Procedure:**
```bash
# 1. Identify all affected services
grep -r "securityContext:" manifests/noctel-*/environments/pdx1-prod-values.yaml | wc -l

# 2. Update template for ONE service, commit, test
# Example: noctel-api-account
# Edit: manifests/noctel-api-account/charts/templates/deployment.yaml
# Add securityContext block from template above

git add manifests/noctel-api-account/charts/templates/deployment.yaml
git commit -m "Add securityContext rendering to noctel-api-account deployment template"
git push

# 3. Verify pod runs as UID 1001
kubectl get pods -n prod -l app=noctel-api-account
kubectl exec -n prod <pod-name> -- id  # Should show uid=1001

# 4. Repeat for remaining 24 services
# Can batch by doing 5-10 at a time
git add manifests/noctel-api-*/charts/templates/deployment.yaml
git commit -m "Add securityContext rendering to noctel-api deployment templates (batch 2)"
git push
```

**Validation:**
- ✅ All pods run as UID 1001: `kubectl exec -n prod <pod> -- id | grep 1001`
- ✅ Pods still have all necessary permissions
- ✅ No startup failures due to file permissions

---

### 5. 📋 Add Health Probes to noctel-api-account (LOW — H4)

**Purpose:** Enable automatic pod restart if service becomes unhealthy  
**Impact:** Low (may cause brief unavailability if service unhealthy)  
**Rollback:** Remove probe from template

**Files to Update:**
- `noctel-api-account/charts/templates/deployment.yaml`

**Template Addition (in containers[0]):**
```yaml
containers:
- name: noctel-api-account
  livenessProbe:
    httpGet:
      path: /health
      port: 9110
    initialDelaySeconds: 30
    periodSeconds: 10
    failureThreshold: 3
  readinessProbe:
    httpGet:
      path: /health
      port: 9110
    initialDelaySeconds: 10
    periodSeconds: 5
    failureThreshold: 2
```

**Procedure:**
```bash
# 1. Verify /health endpoint exists on port 9110
kubectl port-forward -n prod svc/noctel-api-account 9110:9110
curl http://localhost:9110/health  # Should return 200 OK

# 2. Add probes to template
# Edit: manifests/noctel-api-account/charts/templates/deployment.yaml

git add manifests/noctel-api-account/charts/templates/deployment.yaml
git commit -m "Add readiness and liveness probes to noctel-api-account (port 9110 /health)"
git push

# 3. Verify pods remain Running
kubectl get pods -n prod -l app=noctel-api-account
```

**Validation:**
- ✅ Pods restart if /health endpoint fails (test by blocking port 9110 from pod)
- ✅ Pod becomes not-ready if health check fails (Kubernetes removes from LB)

---

### 6. 🚀 Add PodDisruptionBudgets (HIGH — H1)

**Purpose:** Ensure high availability during node maintenance (keep min replicas running)  
**Impact:** Low (prevents eviction, doesn't affect normal operation)  
**Rollback:** Delete PDB resources

**Files to Create:**
- `networking/pdx1/prod/pdb-rabbitmq.yaml`
- `networking/pdx1/prod/pdb-keydb.yaml`

**Template (RabbitMQ):**
```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: rabbitmq-pdb
  namespace: prod
spec:
  minAvailable: 2  # Keep at least 2 pods running during disruption
  selector:
    matchLabels:
      app.kubernetes.io/name: rabbitmq
```

**Template (KeyDB):**
```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: keydb-pdb
  namespace: prod
spec:
  minAvailable: 2  # Keep at least 2 pods running during disruption
  selector:
    matchLabels:
      app.kubernetes.io/name: keydb
```

**Procedure:**
```bash
# 1. Create PDB files
# 2. Commit
git add networking/pdx1/prod/pdb-*.yaml
git commit -m "Add PodDisruptionBudgets for RabbitMQ and KeyDB to maintain availability during node maintenance"
git push

# 3. Verify
kubectl get pdb -n prod
kubectl describe pdb rabbitmq-pdb -n prod
```

**Validation:**
- ✅ PDB exists: `kubectl get pdb -n prod`
- ✅ Status shows correct minAvailable: `kubectl describe pdb -n prod`
- ✅ Kubernetes respects budget during node drain (test with `kubectl drain <node>`)

---

### 7. 📊 Add Redis/KeyDB Monitoring Exporter (MEDIUM — Monitoring)

**Purpose:** Export KeyDB metrics for alerting (memory, replication, connections)  
**Impact:** Low (adds sidecar to KeyDB pods)  
**Rollback:** Remove exporter sidecar from KeyDB chart

**Files to Update:**
- `manifests/keydb/charts/templates/statefulset.yaml` — add redis_exporter sidecar

**Procedure:**
```bash
# 1. Add exporter sidecar to KeyDB StatefulSet
# Edit: manifests/keydb/charts/templates/statefulset.yaml

# In spec.template.spec.containers, add:
- name: redis-exporter
  image: prometheuscommunity/redis-exporter:latest
  ports:
  - containerPort: 9121
    name: metrics
  env:
  - name: REDIS_ADDR
    value: "localhost:6379"

# 2. Add port to Service for scraping
# Edit: manifests/keydb/charts/templates/service.yaml
ports:
- port: 6379
  name: keydb
- port: 9121
  name: metrics

# 3. Create ServiceMonitor for Prometheus
# Create: monitoring/servicemonitors/keydb.yaml

apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: keydb
  namespace: monitoring
spec:
  namespaceSelector:
    matchNames:
    - prod
  selector:
    matchLabels:
      app: keydb
  endpoints:
  - port: metrics
    interval: 30s

# 4. Commit
git add manifests/keydb/charts/templates/statefulset.yaml \
         manifests/keydb/charts/templates/service.yaml \
         monitoring/servicemonitors/keydb.yaml
git commit -m "Add redis_exporter sidecar to KeyDB and create ServiceMonitor for Prometheus metrics"
git push

# 5. Verify
kubectl get pods -n prod -l app=keydb  # Should show 2 containers per pod
kubectl port-forward -n prod svc/keydb 9121:9121
curl http://localhost:9121/metrics  # Should return Prometheus metrics
```

**Validation:**
- ✅ KeyDB pods have redis_exporter sidecar running
- ✅ Prometheus scrapes metrics from port 9121
- ✅ KeyDB alerts can now be created based on replication lag, memory usage, etc.

---

## Implementation Schedule

**Recommendation:** Execute one item per week during scheduled maintenance windows.

| Week | Item | Duration | Risk |
|------|------|----------|------|
| Week 1 | RabbitMQ Credential Rotation | 45 min | Medium |
| Week 2 | LimitRange (dev → qa → prod) | 30 min | Low |
| Week 3 | NetworkPolicy Default-Deny (dev → qa → prod) | 45 min | Medium |
| Week 4 | Security Contexts (batch 1-5 services) | 30 min | Medium |
| Week 5 | Security Contexts (batch 6-10 services) | 30 min | Medium |
| Week 6 | Security Contexts (batch 11-25 services) | 30 min | Medium |
| Week 7 | Health Probes (noctel-api-account) | 30 min | Low |
| Week 8 | PodDisruptionBudgets | 30 min | Low |
| Week 9 | KeyDB Monitoring Exporter | 45 min | Low |

---

## Rollback Procedure (All Items)

For any item, rollback is simple:

```bash
# 1. Identify the commit
git log --oneline | grep "<item name>"

# 2. Revert
git revert <commit-hash>
git push

# 3. ArgoCD auto-syncs to previous state within 3 minutes
# Or force sync via CLI/UI
```

---

## Success Criteria

✅ All 7 items complete when:
- RabbitMQ uses strong credentials (verified in pod env vars)
- LimitRange deployed to all 3 namespaces
- NetworkPolicy default-deny deployed to all 3 namespaces
- All noctel-api services run as UID 1001 (verified via `id` command)
- noctel-api-account has health probes (verified via pod describe)
- PodDisruptionBudgets protect RabbitMQ and KeyDB
- KeyDB metrics exported to Prometheus (verified in Prometheus targets)

**Completion Target:** 9 weeks from start (mid-July 2026)
