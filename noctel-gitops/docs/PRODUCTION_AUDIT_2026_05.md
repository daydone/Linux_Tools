# PDX1 Cluster Production Readiness Audit — May 2026

**Date:** 2026-05-11  
**Auditor:** Claude Code  
**Status:** 17 issues identified (5 Critical, 7 High, 5 Medium)

---

## Executive Summary

The pdx1 K3s cluster is actively serving production traffic but has significant hardening gaps that create active risk of:
- **Cascading failures** (single Traefik instance, no resource limits)
- **Data loss** (monitoring on non-replicated storage)
- **Security exposure** (plaintext RabbitMQ credentials, pods running as root, no network policies)
- **Silent failures** (broken alerting, no observability)

All issues are remediable through gitops changes. See [REMEDIATION_PLAN.md](./REMEDIATION_PLAN.md) for step-by-step fixes.

---

## CRITICAL ISSUES (Active Risk of Outage or Data Exposure)

### C1: No Resource Requests/Limits on ~30 Application Pods

**Status:** Confirmed in all `noctel-api-*`, `noctel-notify-*`, `noctel-worker-*` services.

**Details:**
- All pod deployments have no CPU/memory requests or limits defined in their `pdx1-prod-values.yaml` files
- The chart templates render nothing if `resources:` key is absent (no defaults are applied)
- Affected files: ~30 service environments (e.g., `noctel-api-account/environments/pdx1-prod-values.yaml`)

**Risks:**
- **OOM kills:** Any pod can consume unlimited memory; node hits OOM, kubelet evicts pods
- **Noisy neighbor:** One resource-hungry pod starves others on same node
- **Scheduler can't bin-pack:** Without requests, the scheduler can't make intelligent placement decisions
- **Cascading failure:** Pod evictions trigger restarts, which trigger more evictions

**Examples of pods without limits:**
- All `noctel-api-*` services (account, actions, billing, cnam, gateway, messaging, realtime, etc.)
- All `noctel-notify-*` workers (email-in/out, sms-in/out, slack, webhook, etc.)
- All `noctel-worker-*` services (cleanup, fax, file, indexer)
- `noctel-desk`, `noctel-display`

**Fix Location:** `noctel-api-*/environments/pdx1-prod-values.yaml` and similar for notify/worker services

---

### C2: Security Contexts Defined in Values but Not Rendered in Templates

**Status:** Confirmed in all `noctel-api-*` services.

**Details:**
- `charts/values.yaml` for each `noctel-api-*` service defines:
  ```yaml
  securityContext:
    runAsNonRoot: true
    runAsUser: 1001
    runAsGroup: 1001
    fsGroup: 1001
  ```
- The `charts/templates/deployment.yaml` has **no template block** to render this (`{{- with .Values.securityContext }}`)
- Result: Pods run with whatever UID the container image defaults to (often root)

**Verification:**
```bash
kubectl get pod -n prod -l app=noctel-api-account -o jsonpath='{.items[0].spec.securityContext}'
# Expected: {runAsUser: 1001, ...}
# Actual: {} or null
```

**Risks:**
- Pods run as root despite the intent to run as non-root
- Compromised pod has full container-level privileges
- Violates principle of least privilege

**Services Affected:** All `noctel-api-*` services (at least 27)

**Fix Location:** Each service's `charts/templates/deployment.yaml`

---

### C3: RabbitMQ Password is Plaintext Default (`admin`/`admin123`)

**Status:** Confirmed in `rabbitmq/environments/pdx1-prod-values.yaml`.

**Details:**
```yaml
# rabbitmq/environments/pdx1-prod-values.yaml
auth:
  username: admin
  password: admin123
```

**Risks:**
- Any pod in the prod namespace can connect to RabbitMQ with these credentials
- Exposed to any container image vulnerability or pod breakout
- Default credentials are a known attack vector in CVE databases

**Affected Services:**
- All `noctel-worker-*` services connect via `RABBITMQ_URL` env var
- All `noctel-notify-*` services that enqueue messages
- Any service that publishes background jobs

**Fix Location:** `rabbitmq/environments/pdx1-prod-values.yaml`

---

### C4: Single Traefik Instance (SPOF for All Prod Ingress)

**Status:** Confirmed in `traefik/environments/pdx1-prod-values.yaml`.

**Details:**
```yaml
# traefik/environments/pdx1-prod-values.yaml
traefik:
  replicas: 1
```

**Risks:**
- One pod crash = all ingress routes (`pdx1-prod-api.telnoc.com`, `pdx1-prod-lns.telnoc.com`, `pdx1-prod-s3.telnoc.com`, etc.) become unreachable
- No high availability for ingress layer
- During rolling updates or node drains, ingress is temporarily down

**Additional Issue:** Potential values key mismatch. The prod-values sets `traefik.replicas` but the chart template may use `.Values.replicaCount`. Verify with `helm template`.

**Symptom:** DNS resolves to Traefik's LB IP (10.0.99.151) but connection refused.

**Fix Location:** `traefik/environments/pdx1-prod-values.yaml`

---

### C5: Alertmanager Slack Webhook is a Placeholder

**Status:** Confirmed in monitoring config.

**Details:**
Slack webhook URL is set to: `https://hooks.slack.com/services/TODO/TODO/TODO`

**Risks:**
- Alertmanager sends critical alerts to this invalid endpoint
- Alerts are silently dropped (no delivery, no error)
- Cluster has zero working alerts despite having Prometheus + Alertmanager
- On-call engineer never notified of production incidents

**Examples of alerts that go nowhere:**
- Node disk full
- Pod CrashLoopBackOff
- High CPU/memory usage
- API latency spike
- Database connection failures

**Symptom:** Prometheus rule fires, Alertmanager receives it, but no Slack message appears.

**Fix Location:** `kube-prometheus-stack/environments/pdx1-monitoring-config.yaml`

---

## HIGH-PRIORITY ISSUES (Can Cause Instability Under Load or During Maintenance)

### H1: No PodDisruptionBudgets for RabbitMQ or KeyDB

**Status:** Confirmed. Elasticsearch has a PDB; RabbitMQ and KeyDB do not.

**Details:**
- RabbitMQ runs 3 replicas in prod
- KeyDB (Redis) runs 3 replicas in prod
- During `kubectl drain` (node maintenance), Kubernetes can evict 2+ replicas simultaneously
- Without a PDB, quorum is lost

**Example Scenario:**
1. Operator runs `kubectl drain pdx1-kworker0` for OS updates
2. Kubernetes evicts RabbitMQ pod on that node
3. No PDB = eviction proceeds immediately
4. RabbitMQ cluster loses a member; message queue can still function
5. **But if 2 pods are on same node and both evict,** or if one hasn't restarted yet, quorum is lost
6. All message-based operations fail (workers can't dequeue jobs)

**Risks:**
- Service outage during scheduled maintenance
- Data loss if quorum is lost before persistence catches up

**Fix Location:** `rabbitmq/charts/templates/`, `keydb/charts/templates/`

---

### H2: Two Conflicting CiliumEgressGatewayPolicies with the Same Name

**Status:** Confirmed.

**Details:**
Two files define `prod-egress-gateway-policy`:
1. `networking/prod-egress-gateway-policy.yaml` (root level)
   - Uses `interface: bond0.679` (prod VLAN)
2. `networking/pdx1/prod/prod-egress-gateway-policy.yaml`
   - Uses `egressIP: 10.0.99.10`

**Risks:**
- When both are applied to the cluster, the last one applied wins (overwrites the first)
- Depends on ArgoCD apply order — unpredictable which policy is active
- Egress traffic routing becomes non-deterministic
- Firewalls/security groups expecting egress from specific IPs/VLANs might block unexpected traffic

**Symptom:** Some outbound traffic mysteriously fails depending on recent ArgoCD syncs.

**Fix Location:** Delete `networking/prod-egress-gateway-policy.yaml` (keep the one in `pdx1/prod/`)

---

### H3: Traefik Has No Liveness/Readiness Probes

**Status:** Confirmed. Traefik chart template has no probe definition.

**Details:**
- Traefik pod crashes or deadlocks
- Kubernetes sees pod still running (no process exited)
- Pod remains in rotation indefinitely, taking traffic but not responding
- Requests timeout

**Comparison:** Most other services have HTTP GET probes on their health port (e.g., `/health`, `/metrics`)

**Risks:**
- Silent ingress failure during Traefik crashes
- Manual intervention required to remove unresponsive pod

**Suggested Probe:**
```yaml
readinessProbe:
  httpGet:
    path: /ping
    port: 9000
  initialDelaySeconds: 10
  periodSeconds: 5
livenessProbe:
  httpGet:
    path: /ping
    port: 9000
  initialDelaySeconds: 30
  periodSeconds: 10
```

**Fix Location:** `traefik/charts/templates/deployment.yaml` or `traefik/environments/pdx1-prod-values.yaml`

---

### H4: `noctel-api-account` Has No Liveness/Readiness Probes

**Status:** Confirmed. Pod has health port 9110 exposed but no probe defined.

**Details:**
- Health port is configured in the chart (`port 9110`)
- But `deployment.yaml` template has no `livenessProbe` or `readinessProbe` block
- Unhealthy pods stay in rotation and receive traffic

**Symptoms:** Failed login attempts, intermittent 5xx errors on `/api/v1/accounts/...` endpoints

**Fix Location:** `noctel-api-account/charts/templates/deployment.yaml`

---

### H5: Cilium Operator Replicas = 1

**Status:** Confirmed in `networking/pdx1/cilium/cilium-live.yaml`.

**Details:**
```yaml
operator:
  replicas: 1
```

**Risks:**
- During operator pod restart or node drain, the operator is unavailable
- Network policies are not enforced (existing policies stay, but new policies aren't processed)
- Transient network policy violations during operator downtime

**Symptom:** Network policy changes don't take effect until operator comes back up.

**Fix Location:** `networking/pdx1/cilium/cilium-live.yaml`

---

### H6: Monitoring Data on Non-Replicated `local-path` Storage

**Status:** Confirmed.

**Details:**
Three monitoring components use `local-path` storage class (node-local, non-replicated):
- Prometheus: 50Gi PVC
- Grafana: 10Gi PVC
- Alertmanager: 10Gi PVC

`local-path` stores data on the node's `/var/lib/rancher/k3s/storage/` directory. If the node fails:
- PVC is bound to that node
- Data is inaccessible from other nodes
- **Data is permanently lost** (no replicas)

**Risks:**
- Months of Prometheus metrics lost on node failure
- Grafana dashboards/config reset to defaults
- Alert history is gone
- No way to correlate past incidents

**Comparison:** All other stateful services use `longhorn` (replicated storage class).

**Fix Location:** `kube-prometheus-stack/environments/pdx1-monitoring-config.yaml` — change `storageClass: local-path` to `storageClass: longhorn`

---

### H7: `imagePullPolicy: Always` on All `noctel-api` Services in Prod

**Status:** Confirmed across all ~27 `noctel-api-*` services.

**Details:**
Every pod restart attempts to pull the image from the registry, even if a cached image exists on the node. Example:
```yaml
# noctel-api-account/charts/templates/deployment.yaml
image: someregistry.io/noctel-api-account:{{ .Values.image.tag }}
imagePullPolicy: Always
```

**Risks:**
- **Registry outage = no pod restarts:** If the image registry is down, pods can't restart even if they crash
- **Increased startup latency:** Every pod startup waits for image pull
- **Extra registry load:** Unnecessary pulls increase bandwidth and registry load
- **Cascading failure:** During incident, registry is already stressed; constant pulls make it worse

**Better Practice:** `IfNotPresent` — use cached image if it exists, only pull if missing. For prod deployments with explicit image tags (not `latest`), this is safe and faster.

**Fix Location:** All `noctel-api-*/environments/pdx1-prod-values.yaml` (~27 files)

---

## MEDIUM-PRIORITY ISSUES (Full Hardening)

### M1: No Ingress NetworkPolicy (East-West Traffic Unrestricted)

**Status:** Confirmed. Only two CiliumNetworkPolicies exist (both for egress).

**Details:**
- NetworkPolicy `allow-prod-vlan-egress` has no `Ingress` policyType
- No ingress policies exist for the prod namespace
- **Result:** Any pod can reach any other pod in prod without restriction

**Risks:**
- Lateral movement if one pod is compromised
- No application-level isolation
- Database pods can be accessed by any pod
- Enables data exfiltration from a single compromised pod

**Example:** If `noctel-api-account` pod is compromised, attacker can directly connect to RabbitMQ, KeyDB, or Elasticsearch.

**Current Protection:** Only network boundary (VLAN 679 isolation), not application isolation.

**Fix Location:** `networking/pdx1/prod/` — add NetworkPolicy or CiliumNetworkPolicy files

---

### M2: No HorizontalPodAutoscaler (No Auto-Scaling Under Load)

**Status:** Confirmed. Zero HPA objects exist for any service.

**Details:**
- All replica counts are static (defined in values)
- Load spike = increase latency and CPU until manual scale-up
- No auto-recovery when load increases

**Services that should have HPA:**
- `noctel-api-gateway` (highest traffic, public-facing)
- `noctel-api-account` (login requests, high concurrency)
- `noctel-api-messaging` (message throughput)
- `noctel-api-realtime` (WebSocket connections)

**Suggested Setup:**
- Min replicas: 2 (for availability)
- Max replicas: 6-10 (for cost bounds)
- Target CPU utilization: 70%

**Risks:**
- Manual operator intervention needed during load spikes
- Slow reaction time (operator must notice, make decision, apply change)

**Fix Location:** New HPA manifests in service directories

---

### M3: `prod-lns-ingress` and `prod-s3-ingress` Missing TLS `secretName`

**Status:** Confirmed.

**Details:**
Both ingress resources are missing the `secretName` in the TLS block:
```yaml
# networking/pdx1/prod/prod-lns-ingress.yaml
tls:
  - hosts:
      - pdx1-prod-lns.telnoc.com
    # Missing: secretName: tls-pdx1-prod-lns
```

**Risks:**
- TLS termination falls back to Traefik's default certificate
- Browser shows "certificate mismatch" warning
- Clients may refuse connection or show security warnings
- Not a functional failure, but UX degradation

**Fix Location:** `networking/pdx1/prod/prod-lns-ingress.yaml`, `networking/pdx1/prod/prod-s3-ingress.yaml`

---

### M4: Hubble Metrics Disabled

**Status:** Confirmed in `networking/pdx1/cilium/cilium-live.yaml`:
```yaml
hubble:
  metrics:
    dynamic:
      enabled: false
```

**Risks:**
- No network flow visibility
- No L7 metrics (HTTP, DNS)
- Limited observability for network issues
- Can't answer "which pods are communicating?"

**Fix Location:** `networking/pdx1/cilium/cilium-live.yaml`

---

### M5: Grafana Admin Password Hardcoded in Plain Text

**Status:** Confirmed in monitoring config.

**Details:**
Grafana admin password is stored directly in `pdx1-monitoring-config.yaml` as a plain-text value.

**Risks:**
- Anyone with repo access can read the password
- Password persists in git history
- Difficult to rotate (requires PR + commit)

**Better Practice:** Store in Kubernetes Secret, reference via secretRef.

**Fix Location:** `kube-prometheus-stack/environments/pdx1-monitoring-config.yaml`

---

## Summary Table

| Priority | Count | Blocks Production | Examples |
|----------|-------|-------------------|----------|
| Critical | 5 | Yes | No resource limits, single Traefik, no alerts, hardcoded passwords |
| High | 7 | Conditional | Missing PDBs, missing probes, Cilium operator × 1, ephemeral monitoring |
| Medium | 5 | No | No HPA, weak network policy, TLS cert names |

---

## Remediation

See [REMEDIATION_PLAN.md](./REMEDIATION_PLAN.md) for step-by-step fixes, execution order, and verification steps.

---

## Notes for Future Audits

This audit was performed May 11, 2026. Periodic re-audits are recommended:
- After major cluster version upgrades
- After adding new services (check for resource limits, probes, security context)
- Semi-annually for full re-audit
- After any production incident (post-mortem should reference this audit)
