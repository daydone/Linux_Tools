# PDX1 Production Readiness Audit & Remediation

**Status:** In Progress (2026-06-01, 19:30 UTC)  
**Goal:** Systematic hardening of pdx1 K3s cluster to prevent production outages and data exposure

**Latest:** Phase 1 monitoring HA actively deploying (131 resources syncing). ArgoCD controller fixed. Phase 2 files created, ready to commit.

---

## Completed ✅

| Item | Description | Status | Date |
|------|-------------|--------|------|
| **C4** | Traefik replicas: 1 → 2 | ✅ Done | 2026-05-10 |
| **H2** | Remove duplicate CiliumEgressGatewayPolicies | ✅ Done | 2026-05-10 |
| **H5** | Cilium operator replicas: 1 → 2 | ✅ Done | 2026-05-11 |
| **H7** | imagePullPolicy: Always → IfNotPresent (18 noctel-api-* services) | ✅ Done | 2026-05-11 |
| **Phase 1** | Grafana HA (2 replicas), Alertmanager HA (3 replicas), Loki datasource, 4 dashboards, PrometheusRules, Slack webhook config | ✅ Committed | 2026-06-01 |
| **C5** | Alertmanager Slack webhook configured to read from Secret | ✅ Committed | 2026-06-01 |

---

## In Progress 🔄

| Item | Description | Status | Files | Target Deploy |
|------|-------------|--------|-------|---|
| **Phase 1 Deployment** | Grafana 2 replicas, Alertmanager 3 replicas, Loki datasource, 4 dashboards, PrometheusRules, Slack webhook | 🔄 Actively syncing (131 resources) | kube-prometheus-stack-pdx1 ArgoCD app | ~5-10 min to complete |
| **Phase 2** | LimitRange for prod/qa/dev, NetworkPolicy egress for qa/dev | ⏳ Files created, awaiting commit | `networking/limitrange-{prod,qa,dev}.yaml`, `argocd-applications/pdx1/{qa,dev}/network-policy.yaml` | After Phase 1 completes |
| **C2** | Security contexts not rendering in 25 noctel-api-* templates | ⏳ Pending | 25x `noctel-api-*/charts/templates/deployment.yaml` | After dev/qa validation |
| **H4** | noctel-api-account health probes on port 9110 /health | ⏳ Pending | `noctel-api-account/charts/templates/deployment.yaml` | After Phase 2 |

---

## Todo (Priority Order) 📋

### CRITICAL (Active Risk)

| Item | Issue | Fix | Files |
|------|-------|-----|-------|
| **C1** | No resource requests/limits on ~30 services | Add LimitRange (100m/128Mi default request, 500m/512Mi default limit) — non-disruptive, applies to new pods only | `networking/limitrange-{prod,qa,dev}.yaml` — Phase 2 (ready to commit) |
| **C3** | RabbitMQ default credentials (admin/admin123) | Rotate to random credentials, update all RABBITMQ_URL refs | `rabbitmq/environments/pdx1-prod-values.yaml`, both clusters — DEFERRED |
| **C2** | Security contexts defined but not rendered | Add `{{- with index .Values "service-name" "securityContext" }}` blocks to pod spec level | 25x `noctel-api-*/charts/templates/deployment.yaml` — IN PROGRESS |

### HIGH (Instability Under Load)

| Item | Issue | Fix | Files |
|------|-------|-----|-------|
| **H1** | No PodDisruptionBudgets for RabbitMQ/KeyDB (3 replicas each) | Add PDB `minAvailable: 2` for both | `rabbitmq/charts/templates/`, `keydb/charts/templates/` |
| **H4** | noctel-api-account no probes (health port 9110) | Add readiness + liveness probes on port 9110 `/health` | `noctel-api-account/charts/templates/deployment.yaml` — IN PROGRESS |
| **H3** | Traefik has no probes (currently disabled due to ACME startup issues) | Add readiness probe if ACME issue resolved | `traefik/charts/templates/deployment.yaml` |
| **H6** | Monitoring on non-replicated local-path storage | Grafana: disable persistence (2 replicas). Alertmanager: 3 replicas. Prometheus: still on local-path but HA TBD | Phase 1 (COMPLETED) — partial mitigation |

### MEDIUM (Full Hardening)

| Item | Issue | Fix | Files |
|------|-------|-----|-------|
| **M3** | prod-lns-ingress & prod-s3-ingress missing TLS secretName | Add secretName to both TLS blocks | `networking/pdx1/prod/prod-lns-ingress.yaml`, `prod-s3-ingress.yaml` |
| **M1** | No east-west NetworkPolicy (default-deny) | Add egress-only NetworkPolicy to all namespaces (allow DNS, VLAN, pod-to-pod, mgmt) — default-allow for now, no default-deny ingress | Phase 2 (in progress) — prod exists, qa/dev files created |
| **M2** | No HPA on any service | Add HPA for gateway, account, messaging, realtime (target 70% CPU, min 2/max 6) | New HPA manifests |
| **M4** | Hubble metrics disabled | Enable `hubble.metrics.dynamic.enabled: true` | `networking/pdx1/cilium/cilium-live.yaml` |
| **M5** | Grafana admin password hardcoded in plain text | Move to Kubernetes Secret reference | `kube-prometheus-stack/environments/pdx1-monitoring-config.yaml` |

---

## Issues Found 🚨

| Component | Issue | Severity | Action |
|-----------|-------|----------|--------|
| **Loki** | Gateway & Query-Frontend pods ImagePullBackOff (nginx:1.29.1-debian-12-r0 not accessible) | Medium | Investigate image registry connectivity |
| **Tempo** | 6 new pods ImagePullBackOff (compactor, distributor, ingester, metrics-gen, querier, query-frontend); old pods still running from 5 days ago | Medium | Investigate image registry connectivity |
| **ArgoCD application-controller** | ✅ FIXED: Pod creation failure due to conflicting env var config (both `value` and `valueFrom` set) | Resolved | Patched StatefulSet to remove conflicting `value` field |

---

## Notes

- All changes follow GitOps workflow: commit → ArgoCD sync
- Traefik PROD required multiple fixes: containerPorts (80/443), DNS env vars, health probe removal for ACME
- H7 verified in cluster: all 18 noctel-api-* pods now showing `imagePullPolicy: IfNotPresent`
- H3 (Traefik probes): Currently disabled to avoid blocking ACME certificate renewal on startup

**Phase 1 (Monitoring HA) — DEPLOYING (2026-06-01 19:30 UTC)**
- Commits: d77465c (monitoring config) + 2f359a0 (Chart.lock fix)
- Slack webhook Secret: ✅ Already exists in cluster
- Status: 131 resources actively syncing via ArgoCD
- ETA: ~5-10 minutes for full deployment

**Phase 2 (LimitRange + NetworkPolicy) — READY TO COMMIT**
- Files created, not yet committed
- Deploy approach: 1) commit, 2) wait for ArgoCD sync, 3) monitor for OOMKill/throttling (LimitRange defaults), 4) monitor for connectivity issues (NetworkPolicy)

**C2 & H4 — IN PLANNING**
- C2: Fix 25 templates' security context rendering
- H4: Add health probes to noctel-api-account
- Deploy to dev/qa first for validation before prod

**PVC Cleanup — Pending**
- Force-delete 2 stuck terminating PVCs in dev (filer-data-seaweedfs-filer-0, filer-data-seaweedfs-filer-2) during maintenance window

**C3 (RabbitMQ Credentials) — DEFERRED**
- Requires coordinated vault + gitops change across 43+ services
- Needs dedicated runbook and maintenance window coordination

---

## Verification Checklist

After each change:
- [ ] `kubectl get pods -n prod` — no new CrashLoopBackOff
- [ ] `kubectl describe pod -n prod <pod>` — verify resources/probes rendered
- [ ] ArgoCD UI — app status Synced + Healthy
- [ ] Traefik: `curl https://pdx1-prod-api.telnoc.com/health` → 200
- [ ] Cluster: no unusual events or warnings

---

## Related Issues

- **PDX2 ETCD:** Critically failing (disk saturation, SSD upgrade deadline passed)
- **PDX2 APIs:** Blocked on Redis connectivity
- **General:** ~20+ services with high restart counts or CrashLoopBackOff in dev/qa
