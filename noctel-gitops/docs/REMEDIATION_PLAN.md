# PDX1 Cluster Production Remediation Plan

**Date:** 2026-05-11  
**Based On:** PRODUCTION_AUDIT_2026_05.md  
**Status:** Ready for execution

---

## Overview

This document provides step-by-step remediation for all 17 issues identified in the production audit. Issues are grouped by severity and sequenced to minimize cluster impact and dependency conflicts.

**Total Changes:** 14 execution phases over ~30 files  
**Estimated Time:** 2-3 days with full testing  
**Risk Level:** Medium (changes to core ingress, networking, and storage — requires careful validation)

---

## Execution Sequence

### Phase 1: Rotate RabbitMQ Credentials (CRITICAL — C3)

**Issue:** Default credentials `admin`/`admin123` in `rabbitmq/environments/pdx1-prod-values.yaml`

**Steps:**

1. Generate strong new credentials:
   ```bash
   openssl rand -base64 32 | tr -d '=' | cut -c1-24
   ```
   Example: `K7xM2pQ9vL3nR5sT8wU1yZ4`

2. Update RabbitMQ values:
   ```yaml
   # rabbitmq/environments/pdx1-prod-values.yaml
   auth:
     username: admin
     password: K7xM2pQ9vL3nR5sT8wU1yZ4  # Use generated password
   ```

3. Update all services referencing RabbitMQ. Find all services with `RABBITMQ_URL`:
   ```bash
   grep -r "RABBITMQ_URL" --include="*.yaml" noctel-*
   ```
   Update each to use new credentials. Example for `noctel-worker-cleanup`:
   ```yaml
   # noctel-worker-cleanup/environments/pdx1-prod-values.yaml
   env:
     RABBITMQ_URL: amqp://admin:K7xM2pQ9vL3nR5sT8wU1yZ4@rabbitmq.prod.svc.cluster.local:5672/
   ```

4. Commit and push to trigger ArgoCD sync:
   ```bash
   git add rabbitmq/ noctel-worker-*/ noctel-notify-*/ noctel-api-*/
   git commit -m "Rotate RabbitMQ credentials from default admin/admin123 to secure random password"
   git push
   ```

5. **Verification:**
   - ArgoCD syncs RabbitMQ deployment
   - All worker/notify/API pods restart and connect successfully
   - No RabbitMQ connection errors in pod logs: `kubectl logs -n prod -l app=noctel-worker-cleanup | grep -i error`
   - Queue depth stays healthy (no message backlog accumulation)

---

### Phase 2: Fix Traefik Replicas (CRITICAL — C4)

**Issue:** Single Traefik instance is a single point of failure for all ingress.

**Steps:**

1. Update Traefik values:
   ```yaml
   # traefik/environments/pdx1-prod-values.yaml
   replicas: 2
   ```
   Verify the values key matches chart expectations (check `helm template traefik` output).

2. Commit:
   ```bash
   git add traefik/environments/pdx1-prod-values.yaml
   git commit -m "Increase Traefik replicas from 1 to 2 for HA"
   git push
   ```

3. **Verification:**
   - `kubectl get pods -n ingress -l app=traefik` — should show 2 pods Running
   - Both pods have different node assignments: `kubectl get pods -n ingress -l app=traefik -o wide`
   - DNS resolves and HTTPS works: `curl -I https://pdx1-prod-api.telnoc.com` returns 200
   - Kill one Traefik pod and verify traffic still flows (pod restarts, second pod handles requests)

---

### Phase 3: Remove Duplicate Egress Gateway Policy (HIGH — H2)

**Issue:** Two files define `prod-egress-gateway-policy` with conflicting configurations.

**Steps:**

1. Identify conflicting files:
   ```bash
   find . -name "*egress-gateway*" -type f
   # Results:
   # networking/prod-egress-gateway-policy.yaml (uses interface: bond0.679)
   # networking/pdx1/prod/prod-egress-gateway-policy.yaml (uses egressIP: 10.0.99.10)
   ```

2. Verify the `pdx1/prod/` version is the authoritative one by checking its spec and testing it works.

3. Delete the root-level duplicate:
   ```bash
   git rm networking/prod-egress-gateway-policy.yaml
   ```

4. Commit:
   ```bash
   git add .
   git commit -m "Remove duplicate root-level prod-egress-gateway-policy (kept pdx1/prod version)"
   git push
   ```

5. **Verification:**
   - ArgoCD removes the duplicate policy from cluster
   - Only one `prod-egress-gateway-policy` CiliumEgressGatewayPolicy exists: `kubectl get ceep -n prod`
   - Egress traffic from pods routes consistently (verify no intermittent firewall blocks for egress)

---

### Phase 4: Increase Cilium Operator Replicas (HIGH — H5)

**Issue:** Single Cilium operator pod is unavailable during restarts or node maintenance.

**Steps:**

1. Update Cilium values:
   ```yaml
   # networking/pdx1/cilium/cilium-live.yaml
   operator:
     replicas: 2
   ```

2. Commit:
   ```bash
   git add networking/pdx1/cilium/cilium-live.yaml
   git commit -m "Increase Cilium operator replicas from 1 to 2 for HA"
   git push
   ```

3. **Verification:**
   - `kubectl get pods -n cilium -l app.kubernetes.io/name=cilium-operator` — should show 2 pods Running
   - Network policies still enforce during operator pod restart
   - No lag in new policy application

---

### Phase 5: Add Resource Limits & Fix imagePullPolicy (CRITICAL C1 + HIGH H7)

**Issue:** ~30 noctel-api, noctel-notify, noctel-worker services have no resource limits or use `imagePullPolicy: Always`.

**Steps:**

1. For each service, update `environments/pdx1-prod-values.yaml`:

   **Template for noctel-api services:**
   ```yaml
   # noctel-api-account/environments/pdx1-prod-values.yaml
   replicaCount: 2
   
   image:
     tag: latest
     imagePullPolicy: IfNotPresent
   
   resources:
     requests:
       cpu: 100m
       memory: 256Mi
     limits:
       cpu: 1000m
       memory: 1Gi
   ```

   **Template for noctel-notify services:**
   ```yaml
   replicaCount: 2
   
   image:
     imagePullPolicy: IfNotPresent
   
   resources:
     requests:
       cpu: 50m
       memory: 128Mi
     limits:
       cpu: 500m
       memory: 512Mi
   ```

   **Template for noctel-worker services:**
   ```yaml
   replicaCount: 2
   
   image:
     imagePullPolicy: IfNotPresent
   
   resources:
     requests:
       cpu: 100m
       memory: 256Mi
     limits:
       cpu: 1000m
       memory: 1Gi
   ```

2. Verify all values files are updated (expect ~30 changes):
   ```bash
   grep -l "environments/pdx1-prod-values.yaml" noctel-api-*/... noctel-notify-*/... noctel-worker-*/...
   ```

3. Commit in bulk (this is a large but safe change):
   ```bash
   git add noctel-api-*/environments/pdx1-prod-values.yaml \
           noctel-notify-*/environments/pdx1-prod-values.yaml \
           noctel-worker-*/environments/pdx1-prod-values.yaml
   git commit -m "Add resource requests/limits and set imagePullPolicy: IfNotPresent across all prod services"
   git push
   ```

4. **Verification:**
   - ArgoCD syncs all services (watch progress)
   - `kubectl get pods -n prod -o jsonpath='{.items[*].spec.containers[*].resources}'` — confirms limits present
   - No pods in OOMKilled state: `kubectl get pods -n prod --field-selector=status.reason=OOMKilled`
   - Pod startup times are reasonable (image pull time decreases after first pull)
   - Confirm no ImagePullBackOff errors when registry is briefly unavailable

---

### Phase 6: Add PodDisruptionBudgets for RabbitMQ and KeyDB (HIGH — H1)

**Issue:** RabbitMQ and KeyDB can lose quorum during node maintenance if multiple replicas evict simultaneously.

**Steps:**

1. Create PDB for RabbitMQ:
   ```yaml
   # rabbitmq/charts/templates/poddisruptionbudget.yaml
   {{- if .Values.podDisruptionBudget.enabled }}
   apiVersion: policy/v1
   kind: PodDisruptionBudget
   metadata:
     name: rabbitmq
     namespace: {{ .Release.Namespace }}
   spec:
     minAvailable: 2
     selector:
       matchLabels:
         app: rabbitmq
   {{- end }}
   ```

2. Create PDB for KeyDB:
   ```yaml
   # keydb/charts/templates/poddisruptionbudget.yaml
   {{- if .Values.podDisruptionBudget.enabled }}
   apiVersion: policy/v1
   kind: PodDisruptionBudget
   metadata:
     name: keydb
     namespace: {{ .Release.Namespace }}
   spec:
     minAvailable: 2
     selector:
       matchLabels:
         app: keydb
   {{- end }}
   ```

3. Enable PDB in values:
   ```yaml
   # rabbitmq/environments/pdx1-prod-values.yaml
   podDisruptionBudget:
     enabled: true
   
   # keydb/environments/pdx1-prod-values.yaml
   podDisruptionBudget:
     enabled: true
   ```

4. Commit:
   ```bash
   git add rabbitmq/charts/templates/poddisruptionbudget.yaml \
           rabbitmq/environments/pdx1-prod-values.yaml \
           keydb/charts/templates/poddisruptionbudget.yaml \
           keydb/environments/pdx1-prod-values.yaml
   git commit -m "Add PodDisruptionBudgets for RabbitMQ and KeyDB (minAvailable: 2)"
   git push
   ```

5. **Verification:**
   - `kubectl get pdb -n prod` — should show both PDBs
   - Test node drain: `kubectl drain <node> --ignore-daemonsets` — eviction respects PDB (min 1 pod stays running)
   - After drain, pods reschedule and cluster remains healthy

---

### Phase 7: Add Liveness/Readiness Probes (HIGH — H3 + H4)

**Issue:** Traefik and noctel-api-account have no health probes; unhealthy pods stay in rotation.

**Steps:**

1. Add probes to Traefik deployment template:
   ```yaml
   # traefik/charts/templates/deployment.yaml
   spec:
     containers:
     - name: traefik
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

2. Add probes to noctel-api-account deployment template:
   ```yaml
   # noctel-api-account/charts/templates/deployment.yaml
   spec:
     containers:
     - name: noctel-api-account
       readinessProbe:
         httpGet:
           path: /health
           port: 9110
         initialDelaySeconds: 10
         periodSeconds: 5
       livenessProbe:
         httpGet:
           path: /health
           port: 9110
         initialDelaySeconds: 30
         periodSeconds: 10
   ```

3. Commit:
   ```bash
   git add traefik/charts/templates/deployment.yaml \
           noctel-api-account/charts/templates/deployment.yaml
   git commit -m "Add liveness/readiness probes to Traefik and noctel-api-account"
   git push
   ```

4. **Verification:**
   - `kubectl describe pod -n prod <traefik-pod>` — shows probe configuration
   - `kubectl describe pod -n prod <noctel-api-account-pod>` — shows probe configuration
   - Probes are reporting Healthy: `kubectl get pod -n prod -o wide | grep traefik`
   - Kill a pod's health endpoint and verify it gets restarted by kubelet

---

### Phase 8: Fix Alertmanager Slack Webhook (CRITICAL — C5)

**Issue:** Slack webhook is placeholder; critical alerts are silently dropped.

**Steps:**

1. Obtain real Slack webhook URL from your workspace:
   - Go to Slack app directory → "Alertmanager" or create incoming webhook
   - Note the URL: `https://hooks.slack.com/services/T.../B.../X...`

2. Update monitoring config:
   ```yaml
   # kube-prometheus-stack/environments/pdx1-monitoring-config.yaml
   prometheus:
     alertmanager:
       config:
         route:
           receiver: 'slack'
         receivers:
         - name: 'slack'
           slack_configs:
           - api_url: 'https://hooks.slack.com/services/T.../B.../X...'
             channel: '#pdx1-alerts'
             title: 'PDX1 Alert: {{ .GroupLabels.alertname }}'
             text: '{{ range .Alerts }}{{ .Annotations.message }}{{ end }}'
   ```

3. Commit:
   ```bash
   git add kube-prometheus-stack/environments/pdx1-monitoring-config.yaml
   git commit -m "Configure real Slack webhook for Alertmanager (pdx1 alerts)"
   git push
   ```

4. **Verification:**
   - ArgoCD syncs Alertmanager deployment
   - Test fire a dummy alert: `kubectl port-forward -n monitoring prometheus-0 9090:9090` and trigger test alert
   - Verify Slack message appears in #pdx1-alerts channel within 1-2 minutes
   - Monitor for actual alerts and confirm they reach Slack

---

### Phase 9: Fix TLS Secret Names in Ingresses (MEDIUM — M3)

**Issue:** `prod-lns-ingress` and `prod-s3-ingress` are missing `secretName` in TLS block; browser shows cert warnings.

**Steps:**

1. Update prod-lns-ingress:
   ```yaml
   # networking/pdx1/prod/prod-lns-ingress.yaml
   spec:
     tls:
     - hosts:
       - pdx1-prod-lns.telnoc.com
       secretName: tls-pdx1-prod-lns
     rules:
     - host: pdx1-prod-lns.telnoc.com
       http:
         paths:
         - path: /
           backend:
             serviceName: lns-service
             servicePort: 8080
   ```

2. Update prod-s3-ingress:
   ```yaml
   # networking/pdx1/prod/prod-s3-ingress.yaml
   spec:
     tls:
     - hosts:
       - pdx1-prod-s3.telnoc.com
       secretName: tls-pdx1-prod-s3
     rules:
     - host: pdx1-prod-s3.telnoc.com
       http:
         paths:
         - path: /
           backend:
             serviceName: seaweedfs-s3
             servicePort: 8333
   ```

3. Verify TLS secrets exist or are managed by cert-manager:
   ```bash
   kubectl get secret -n prod tls-pdx1-prod-lns tls-pdx1-prod-s3
   ```

4. Commit:
   ```bash
   git add networking/pdx1/prod/prod-lns-ingress.yaml \
           networking/pdx1/prod/prod-s3-ingress.yaml
   git commit -m "Add secretName to TLS blocks in LNS and S3 ingresses"
   git push
   ```

5. **Verification:**
   - `curl -I https://pdx1-prod-lns.telnoc.com` — returns 200 (no cert warning)
   - `curl -I https://pdx1-prod-s3.telnoc.com` — returns 200 (no cert warning)
   - Browser opens both URLs without cert mismatch warnings

---

### Phase 10: Migrate Monitoring to Replicated Storage (HIGH — H6)

**Issue:** Prometheus, Grafana, Alertmanager use non-replicated `local-path` storage; node failure = permanent data loss.

**Steps:**

1. Update storage class in monitoring config:
   ```yaml
   # kube-prometheus-stack/environments/pdx1-monitoring-config.yaml
   prometheus:
     storageSpec:
       volumeClaimTemplate:
         spec:
           storageClassName: longhorn
           accessModes: ["ReadWriteOnce"]
           resources:
             requests:
               storage: 50Gi
   
   grafana:
     persistence:
       storageClassName: longhorn
       size: 10Gi
   
   alertmanager:
     alertmanagerSpec:
       storage:
         volumeClaimTemplate:
           spec:
             storageClassName: longhorn
             accessModes: ["ReadWriteOnce"]
             resources:
               requests:
                 storage: 10Gi
   ```

2. Commit:
   ```bash
   git add kube-prometheus-stack/environments/pdx1-monitoring-config.yaml
   git commit -m "Migrate monitoring (Prometheus/Grafana/Alertmanager) to longhorn replicated storage"
   git push
   ```

3. **Verification After Sync:**
   - New PVCs are created with `storageClass: longhorn`: `kubectl get pvc -n monitoring`
   - Longhorn dashboard shows volumes are replicated: `kubectl port-forward -n longhorn svc/longhorn-frontend 8080:80`
   - Prometheus and Grafana maintain data during node failure (test by cordoning a node)
   - Dashboard and alert history persist after failover

---

### Phase 11: Audit and Fix Security Contexts (CRITICAL — C2)

**Issue:** `noctel-api-*` services define securityContext in values but chart templates don't render it; pods run as root.

**Steps:**

1. First, verify pods are actually running as root:
   ```bash
   kubectl get pods -n prod -l app=noctel-api-account -o jsonpath='{.items[0].spec.securityContext}'
   # Expected output: {} or null (broken)
   # Desired output: {"runAsUser":1001,"runAsGroup":1001,"fsGroup":1001,"runAsNonRoot":true}
   ```

2. For each affected service chart template, add securityContext rendering:
   ```yaml
   # noctel-api-account/charts/templates/deployment.yaml
   spec:
     {{- with .Values.securityContext }}
     securityContext:
       runAsUser: {{ .runAsUser }}
       runAsGroup: {{ .runAsGroup }}
       fsGroup: {{ .fsGroup }}
       runAsNonRoot: {{ .runAsNonRoot }}
     {{- end }}
     containers:
     - name: noctel-api-account
       ...
   ```

3. Repeat for all ~27 noctel-api-* services and any other services with securityContext defined but not rendered.

4. Commit (bulk change):
   ```bash
   git add noctel-api-*/charts/templates/deployment.yaml
   git commit -m "Render securityContext in deployment templates for all noctel-api services"
   git push
   ```

5. **Verification:**
   - After sync, verify pods run as UID 1001: `kubectl exec -n prod <pod-name> -- id`
   - Output should show: `uid=1001 gid=1001 groups=1001`
   - Pods should not have root-level permissions even if container image defaults to root

---

### Phase 12: Add Network Policies (MEDIUM — M1)

**Issue:** No ingress NetworkPolicy; any compromised pod can reach all others.

**Steps:**

1. Create default-deny ingress policy:
   ```yaml
   # networking/pdx1/prod/network-policy-default-deny.yaml
   apiVersion: cilium.io/v2
   kind: CiliumNetworkPolicy
   metadata:
     name: default-deny-ingress
     namespace: prod
   spec:
     endpointSelector: {}
     policyTypes:
     - Ingress
   ```

2. Create allow rules per service. Example for RabbitMQ (only workers/notifiers can access):
   ```yaml
   # networking/pdx1/prod/network-policy-rabbitmq.yaml
   apiVersion: cilium.io/v2
   kind: CiliumNetworkPolicy
   metadata:
     name: allow-rabbitmq
     namespace: prod
   spec:
     endpointSelector:
       matchLabels:
         app: rabbitmq
     policyTypes:
     - Ingress
     ingressRules:
     - fromEndpoints:
       - matchLabels:
           app-family: worker
       - matchLabels:
           app-family: notify
       toPorts:
       - ports:
         - port: "5672"
           protocol: TCP
   ```

3. Repeat for other critical services (KeyDB, Elasticsearch, database, etc.).

4. Commit:
   ```bash
   git add networking/pdx1/prod/network-policy-*.yaml
   git commit -m "Add CiliumNetworkPolicies: default-deny ingress with explicit allow rules per service"
   git push
   ```

5. **Verification:**
   - After sync, verify policies exist: `kubectl get cnp -n prod`
   - Test that pods can't reach services they shouldn't: `kubectl exec -n prod <pod> -- nc -zv <service-ip> 5672` should timeout
   - Allowed pods can still reach their services: test worker can reach RabbitMQ
   - No unintended service-to-service communication breaks

---

### Phase 13: Add HorizontalPodAutoscalers (MEDIUM — M2)

**Issue:** No auto-scaling under load; manual operator intervention required during spikes.

**Steps:**

1. Create HPA for high-traffic services. Start with `noctel-api-gateway` (highest load):
   ```yaml
   # noctel-api-gateway/environments/pdx1-prod-hpa.yaml
   apiVersion: autoscaling/v2
   kind: HorizontalPodAutoscaler
   metadata:
     name: noctel-api-gateway
     namespace: prod
   spec:
     scaleTargetRef:
       apiVersion: apps/v1
       kind: Deployment
       name: noctel-api-gateway
     minReplicas: 2
     maxReplicas: 8
     metrics:
     - type: Resource
       resource:
         name: cpu
         target:
           type: Utilization
           averageUtilization: 70
     - type: Resource
       resource:
         name: memory
         target:
           type: Utilization
           averageUtilization: 80
   ```

2. Repeat for other high-traffic services:
   - `noctel-api-account` (login, auth)
   - `noctel-api-messaging` (message throughput)
   - `noctel-api-realtime` (WebSocket connections)

3. Commit:
   ```bash
   git add noctel-api-gateway/environments/pdx1-prod-hpa.yaml \
           noctel-api-account/environments/pdx1-prod-hpa.yaml \
           noctel-api-messaging/environments/pdx1-prod-hpa.yaml \
           noctel-api-realtime/environments/pdx1-prod-hpa.yaml
   git commit -m "Add HorizontalPodAutoscalers for high-traffic noctel-api services"
   git push
   ```

4. **Verification:**
   - HPAs are created: `kubectl get hpa -n prod`
   - Generate load and verify pods scale up: `kubectl get pods -n prod -l app=noctel-api-gateway | wc -l` increases
   - After load drops, pods scale back down within 5 minutes
   - HPA status shows target utilization: `kubectl describe hpa noctel-api-gateway -n prod`

---

### Phase 14: Enable Hubble Metrics & Secure Grafana (MEDIUM — M4 + M5)

**Issue:** Hubble metrics disabled (no network flow visibility); Grafana admin password hardcoded.

**Steps:**

1. Enable Hubble in Cilium config:
   ```yaml
   # networking/pdx1/cilium/cilium-live.yaml
   hubble:
     metrics:
       dynamic:
         enabled: true
   ```

2. Move Grafana password to Secret instead of hardcoded values:
   ```yaml
   # kube-prometheus-stack/charts/templates/secret.yaml
   apiVersion: v1
   kind: Secret
   metadata:
     name: grafana-admin
     namespace: monitoring
   type: Opaque
   stringData:
     admin-password: {{ .Values.grafana.adminPassword | quote }}
   ```

   Then reference in values:
   ```yaml
   # kube-prometheus-stack/environments/pdx1-monitoring-config.yaml
   grafana:
     adminPassword: <move to kubectl secret>
     extraSecretMounts:
     - name: grafana-admin-secret
       secretName: grafana-admin
       mountPath: /etc/secrets/admin
   ```

3. Commit:
   ```bash
   git add networking/pdx1/cilium/cilium-live.yaml \
           kube-prometheus-stack/charts/templates/secret.yaml \
           kube-prometheus-stack/environments/pdx1-monitoring-config.yaml
   git commit -m "Enable Hubble metrics; move Grafana admin password to Kubernetes Secret"
   git push
   ```

4. **Verification:**
   - Hubble metrics are exposed: `kubectl port-forward -n cilium svc/hubble-metrics 6100:6100 &` and `curl localhost:6100/metrics`
   - Grafana dashboard shows network flows (new Hubble L7 metrics available)
   - Grafana admin password is no longer in git history: `git log --all -p -- '*monitoring-config*' | grep -i password` should not show plaintext
   - Grafana login still works with password from Secret

---

## Verification Checklist

After each phase, confirm:

- [ ] ArgoCD reports all apps Synced (no errors)
- [ ] No new CrashLoopBackOff or ImagePullBackOff pods
- [ ] `kubectl get nodes` shows all nodes Ready
- [ ] Existing ingress routes respond to curl/browser (spot-check 3+ endpoints)
- [ ] Pod logs show no new errors: `kubectl logs -n prod --since=5m | grep -i error | head -10`
- [ ] Cluster events look clean: `kubectl get events -n prod --sort-by='.lastTimestamp' | tail -20`

---

## Rollback Strategy

If any phase causes issues:

1. Identify the problematic commit:
   ```bash
   git log --oneline | head -5
   ```

2. Revert the commit:
   ```bash
   git revert <commit-hash>
   git push
   ```

3. Wait for ArgoCD to sync (usually <2 minutes)

4. Verify cluster returns to stable state

---

## Timeline & Resource Impact

| Phase | Time | Risk | Cluster Impact |
|-------|------|------|-----------------|
| 1-2 | 15 min | Low | RabbitMQ, Traefik pods restart (brief downtime) |
| 3-4 | 10 min | Low | Network policy update (no downtime) |
| 5 | 30 min | Medium | ~30 pod restarts (watch scaling) |
| 6 | 10 min | Low | PDB addition (no downtime) |
| 7 | 10 min | Low | Probe addition (no downtime) |
| 8 | 5 min | Low | Alertmanager config update (no downtime) |
| 9 | 5 min | Low | Ingress config update (no downtime) |
| 10 | 30 min | Medium | PVC migration (monitoring may be slow) |
| 11 | 20 min | Low | Pod restart (security context application) |
| 12 | 15 min | High | Network policy enforcement (test connectivity!) |
| 13 | 20 min | Low | HPA creation (no immediate scale) |
| 14 | 10 min | Low | Hubble/Grafana config (no downtime) |
| **Total** | **3 hours** | **Medium** | **All changes non-blocking if sequenced correctly** |

---

## Notes

- Execute phases in order. Phase dependencies:
  - Phase 5 (resource limits) must complete before Phase 13 (HPA — needs resource requests)
  - Phase 8 (alerts) stands alone but is critical for observability during later phases
  
- Test each phase thoroughly before moving to the next. Don't batch multiple phases.

- After all phases complete, re-run the audit (`docs/PRODUCTION_AUDIT_2026_05.md`) to confirm all 17 issues are resolved.

- Schedule remediation during a low-traffic window (off-peak hours) to minimize blast radius.

- Have cluster admin and at least one application owner available during execution for rapid troubleshooting.
