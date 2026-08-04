# PDX2 Deployment Status vs noctel-gitops Readiness

**Date:** December 12, 2025
**Purpose:** Track which deployments have complete configs in noctel-gitops repo
**Goal:** Ensure every pdx2 deployment can be replicated to pdx1/man1 via GitOps

---

## Legend

- ✅ **Complete** - ArgoCD app exists, Helm chart exists, values file configured
- 🟡 **Partial** - Some pieces exist but not complete
- ❌ **Missing** - Not configured in noctel-gitops
- 🔴 **Blocker** - Critical missing component

---

## Critical Blockers

| Issue | Status | Impact | Action Needed |
|-------|--------|--------|---------------|
| **No charts/ directory** | 🔴 | Can't deploy anything | Copy from k3s-config/helm/ |
| **Prod ArgoCD apps missing** | 🔴 | Can't deploy prod | Create prod-* applications |
| **pdx2-prod-config incomplete** | 🔴 | Prod config too small (83 lines) | Expand to match dev (513 lines) |

---

## PROD Namespace - pdx2-cluster

### Core Application Stack

| Component | Deployed | ArgoCD App | Helm Chart | Values Config | Status |
|-----------|----------|------------|------------|---------------|--------|
| **noctel-prod-api** | ✅ (3 replicas) | ❌ | ❌ | 🟡 Partial | ❌ **Not Ready** |
| **noctel-prod-ui** | ✅ (2 replicas) | ❌ | ❌ | 🟡 Partial | ❌ **Not Ready** |
| **noctel-prod-lns** | ✅ (2 replicas) | ❌ | ❌ | 🟡 Partial | ❌ **Not Ready** |
| **noctel-prod-ape** | ✅ (2 replicas) | ❌ | ❌ | 🟡 Partial | ❌ **Not Ready** |
| **noctel-prod-display** | ✅ (1 replica) | ❌ | ❌ | 🟡 Partial | ❌ **Not Ready** |
| **noctel-prod-migrate** | ✅ (2 replicas) | ❌ | ❌ | 🟡 Partial | ❌ **Not Ready** |

**Notes:**
- All deployed via Helm chart: `noctel-now-0.1.0` (revision 73)
- Chart exists in k3s-config: `/helm/noctel-now/`
- Values file exists: `k3s-config/helm/noctel-now/values-prod-pdx2.yaml`
- **Action:** Copy noctel-now chart to noctel-gitops, create ArgoCD apps

### ChirpStack Stack

| Component | Deployed | ArgoCD App | Helm Chart | Values Config | Status |
|-----------|----------|------------|------------|---------------|--------|
| **chirpstack-core** | ✅ (2 replicas) | ❌ | ❌ | 🟡 Partial | ❌ **Not Ready** |
| **chirpstack-gateway-bridge** | ✅ (1 replica) | ❌ | ❌ | 🟡 Partial | ❌ **Not Ready** |
| **chirpstack-mosquitto** | ✅ (2 replicas) | ❌ | ❌ | 🟡 Partial | ❌ **Not Ready** |

**Notes:**
- Included in noctel-now chart
- Configs in pdx2-prod-config.yaml incomplete

### Infrastructure

| Component | Deployed | ArgoCD App | Helm Chart | Values Config | Status |
|-----------|----------|------------|------------|---------------|--------|
| **traefik-prod** | ✅ (2 replicas) | ❌ | ❌ | ❌ | ❌ **Not Ready** |
| **redis-master** | ✅ (StatefulSet) | ❌ | ❌ | ❌ | ❌ **Not Ready** |
| **ha-rabbit-server** | ✅ (StatefulSet) | ❌ | ❌ | ❌ | ❌ **Not Ready** |
| **elasticsearch** | ✅ (StatefulSet) | ❌ | ❌ | ❌ | ❌ **Not Ready** |
| **seaweedfs-prod** | ✅ (2 replicas) | ❌ | ❌ | ❌ | ❌ **Not Ready** |
| **nt-mq-mailer** | ✅ (1 replica) | ❌ | ❌ | ❌ | ❌ **Not Ready** |
| **noctel-aps** | ✅ (1 replica) | ❌ | ❌ | ❌ | ❌ **Not Ready** |

**Notes:**
- Deployed via separate Helm releases
- Charts exist in k3s-config
- No ArgoCD apps defined
- No values in pdx2-prod-config.yaml

### Monitoring

| Component | Deployed | ArgoCD App | Helm Chart | Values Config | Status |
|-----------|----------|------------|------------|---------------|--------|
| **elasticsearch-exporter** | ✅ (1 replica) | ❌ | ❌ | ❌ | ❌ **Not Ready** |
| **redis-exporter** | ✅ (1 replica) | ❌ | ❌ | ❌ | ❌ **Not Ready** |

---

## QA Namespace - pdx2-cluster

### Core Application Stack

| Component | Deployed | ArgoCD App | Helm Chart | Values Config | Status |
|-----------|----------|------------|------------|---------------|--------|
| **noctel-api** | ✅ | ✅ qa-noctel-api | ❌ | ✅ | 🟡 **Partial** |
| **noctel-ui** | ✅ | ✅ qa-noctel-ui | ❌ | ✅ | 🟡 **Partial** |
| **noctel-lns** | ✅ | ✅ qa-noctel-lns | ❌ | ✅ | 🟡 **Partial** |
| **noctel-ape** | ✅ | ✅ qa-noctel-ape | ❌ | ✅ | 🟡 **Partial** |
| **noctel-display** | ✅ | ✅ qa-noctel-display | ❌ | ✅ | 🟡 **Partial** |
| **noctel-migrate** | ✅ | ✅ qa-noctel-migrate | ❌ | ✅ | 🟡 **Partial** |

**Notes:**
- ArgoCD apps exist but point to non-existent charts
- Values file `pdx2-qa-config.yaml` is comprehensive (570 lines)
- **Action:** Copy charts, test deployment

### ChirpStack Stack

| Component | Deployed | ArgoCD App | Helm Chart | Values Config | Status |
|-----------|----------|------------|------------|---------------|--------|
| **chirpstack-core-qa** | ✅ | ✅ qa-chirpstack-core | ❌ | ✅ | 🟡 **Partial** |
| **chirpstack-gateway-bridge-qa** | ✅ | ✅ qa-chirpstack-gateway-bridge | ❌ | ✅ | 🟡 **Partial** |
| **chirpstack-mosquitto-qa** | ✅ | ✅ qa-chirpstack-mosquitto | ❌ | ✅ | 🟡 **Partial** |

### Infrastructure

| Component | Deployed | ArgoCD App | Helm Chart | Values Config | Status |
|-----------|----------|------------|------------|---------------|--------|
| **traefik-qa** | ✅ | ✅ qa-traefik | ❌ | ✅ | 🟡 **Partial** |
| **redis-qa** | ✅ (StatefulSet) | ✅ qa-redis | ❌ | ✅ | 🟡 **Partial** |
| **ha-rabbit-server** | ✅ (StatefulSet) | ✅ qa-rabbitmq | ❌ | ✅ | 🟡 **Partial** |
| **elasticsearch** | ✅ (StatefulSet) | ✅ qa-elasticsearch | ❌ | ✅ | 🟡 **Partial** |
| **seaweedfs-qa** | ✅ | ✅ qa-seaweedfs | ❌ | ✅ | 🟡 **Partial** |
| **nt-mq-mailer** | ✅ | ✅ qa-nt-mq-mailer | ❌ | ✅ | 🟡 **Partial** |

**Summary:** QA has complete ArgoCD app definitions and values, just needs charts

---

## DEV Namespace - pdx2-cluster

### Core Application Stack

| Component | Deployed | ArgoCD App | Helm Chart | Values Config | Status |
|-----------|----------|------------|------------|---------------|--------|
| **noctel-api** | ✅ | ✅ dev-noctel-api | ❌ | ✅ | 🟡 **Partial** |
| **noctel-ui** | ✅ | ✅ dev-noctel-ui | ❌ | ✅ | 🟡 **Partial** |
| **noctel-lns** | ✅ (CrashLoop!) | ✅ dev-noctel-lns | ❌ | ✅ | 🟡 **Partial** |
| **noctel-ape** | ✅ (Error!) | ✅ dev-noctel-ape | ❌ | ✅ | 🟡 **Partial** |
| **noctel-display** | ✅ | ✅ dev-noctel-display | ❌ | ✅ | 🟡 **Partial** |
| **noctel-migrate** | ✅ | ✅ dev-noctel-migrate | ❌ | ✅ | 🟡 **Partial** |

**Notes:**
- ArgoCD apps exist but point to non-existent charts
- Values file `pdx2-dev-config.yaml` is comprehensive (513 lines) ✅
- noctel-lns and noctel-ape have issues (need investigation)
- **Action:** Copy charts, fix crashing apps

### ChirpStack Stack

| Component | Deployed | ArgoCD App | Helm Chart | Values Config | Status |
|-----------|----------|------------|------------|---------------|--------|
| **chirpstack-core** | ✅ | ✅ dev-chirpstack-core | ❌ | ✅ | 🟡 **Partial** |
| **chirpstack-gateway-bridge** | ✅ | ✅ dev-chirpstack-gateway-bridge | ❌ | ✅ | 🟡 **Partial** |
| **chirpstack-mosquitto** | ✅ | ✅ dev-chirpstack-mosquitto | ❌ | ✅ | 🟡 **Partial** |

### Infrastructure

| Component | Deployed | ArgoCD App | Helm Chart | Values Config | Status |
|-----------|----------|------------|------------|---------------|--------|
| **traefik** | ✅ (0/0 replicas) | ✅ dev-traefik | ❌ | ✅ | 🟡 **Partial** |
| **redis-dev** | ✅ (StatefulSet) | ✅ dev-redis | ❌ | ✅ | 🟡 **Partial** |
| **ha-rabbit-server** | ✅ (StatefulSet) | ✅ dev-rabbitmq | ❌ | ✅ | 🟡 **Partial** |
| **elasticsearch** | ✅ (StatefulSet) | ✅ dev-elasticsearch | ❌ | ✅ | 🟡 **Partial** |
| **seaweedfs** | ✅ | ✅ dev-seaweedfs | ❌ | ✅ | 🟡 **Partial** |
| **nt-mq-mailer** | ✅ | ✅ dev-nt-mq-mailer | ❌ | ✅ | 🟡 **Partial** |

**Summary:** DEV has complete ArgoCD app definitions and values, just needs charts

---

## Summary by Environment

### PROD
- **Deployments:** 15 components running
- **ArgoCD Apps:** 1 (just prod-application)
- **Values File:** Incomplete (83 lines)
- **Charts:** None
- **Overall Status:** ❌ **0% Ready**

### QA
- **Deployments:** 13 components running
- **ArgoCD Apps:** 17 defined
- **Values File:** Complete (570 lines)
- **Charts:** None
- **Overall Status:** 🟡 **50% Ready** (needs charts)

### DEV
- **Deployments:** 12 components running
- **ArgoCD Apps:** 17 defined
- **Values File:** Complete (513 lines)
- **Charts:** None
- **Overall Status:** 🟡 **50% Ready** (needs charts)

---

## What Exists in k3s-config (Source of Truth)

### Helm Charts Available
```
k3s-config/helm/
├── noctel-now/                    # Main app bundle (ALL noctel + chirpstack)
│   ├── values-prod-pdx2.yaml     # 17KB - Complete prod config
│   ├── values-qa-pdx2.yaml       # 15KB - Complete qa config
│   ├── values-dev-pdx2.yaml      # 15KB - Complete dev config
│   └── templates/                # All service templates
├── infrastructure/
│   └── traefik/                  # Traefik chart
├── seaweedfs/                    # SeaweedFS chart
├── nt-mq-mailer/                 # Mailer chart
└── [Redis via Bitnami]
```

### Currently Deployed (Helm Releases)
```bash
helm list -n prod
# noctel-prod (noctel-now-0.1.0) - revision 73
# redis-master (redis-22.0.0)
# seaweedfs-prod (seaweedfs-0.1.0)
# traefik-prod (traefik-37.0.0)
# nt-mq-mailer (nt-mq-mailer-0.1.0)
# noctel-aps (noctel-aps-2.11.19)
```

---

## Action Plan

### Phase 1: Copy Charts (HIGH PRIORITY)
```bash
# Copy from k3s-config to noctel-gitops
cp -r k3s-config/helm/noctel-now noctel-gitops/charts/
cp -r k3s-config/helm/infrastructure noctel-gitops/charts/
cp -r k3s-config/helm/seaweedfs noctel-gitops/charts/
cp -r k3s-config/helm/nt-mq-mailer noctel-gitops/charts/
# Add Bitnami redis as dependency
```

**Estimated Time:** 1 hour
**Blocker Resolution:** Unblocks ALL environments

### Phase 2: Complete pdx2-prod-config.yaml (HIGH PRIORITY)
```bash
# Extract current prod values
helm get values noctel-prod -n prod > prod-current-values.yaml

# Merge into pdx2-prod-config.yaml
# Expand from 83 lines to ~500+ lines to match dev/qa
```

**Estimated Time:** 2 hours
**Blocker Resolution:** Enables prod deployment

### Phase 3: Create Prod ArgoCD Applications (HIGH PRIORITY)
```bash
# Create matching dev/qa structure:
argocd-applications/
├── prod-noctel-api.yaml
├── prod-noctel-ui.yaml
├── prod-noctel-lns.yaml
├── prod-noctel-ape.yaml
├── prod-noctel-display.yaml
├── prod-noctel-migrate.yaml
├── prod-chirpstack-core.yaml
├── prod-chirpstack-gateway-bridge.yaml
├── prod-chirpstack-mosquitto.yaml
├── prod-traefik.yaml
├── prod-redis.yaml
├── prod-rabbitmq.yaml
├── prod-elasticsearch.yaml
├── prod-seaweedfs.yaml
├── prod-nt-mq-mailer.yaml
└── prod-noctel-aps.yaml
```

**Estimated Time:** 1 hour (copy/modify from dev/qa)
**Blocker Resolution:** Enables prod GitOps deployment

### Phase 4: Test Deploy to pdx1 (VALIDATION)
1. Create pdx1 environment configs (copy pdx2, adjust IPs/domains)
2. Bootstrap pdx1 cluster (Ansible)
3. Install ArgoCD on pdx1
4. Deploy dev namespace
5. Deploy qa namespace
6. Deploy prod namespace
7. Verify all services match pdx2

**Estimated Time:** 4-8 hours (depends on pdx1 state)
**Validation:** Proves GitOps works end-to-end

---

## Current Gaps Summary

| Gap | Impact | Effort | Priority |
|-----|--------|--------|----------|
| No charts/ directory | 🔴 Blocks everything | 1 hr | P0 |
| pdx2-prod-config incomplete | 🔴 Can't deploy prod | 2 hrs | P0 |
| No prod ArgoCD apps | 🔴 Can't deploy prod | 1 hr | P0 |
| No pdx1 configs | 🟡 Can't deploy pdx1 | 2 hrs | P1 |
| No Ansible bootstrap | 🟡 Manual cluster setup | 4 hrs | P1 |
| Dev apps crashing | 🟡 Dev unstable | 2 hrs | P2 |

**Total to unblock:** ~4 hours of focused work
**Total for full solution:** ~12-16 hours

---

## Next Steps

1. ✅ Copy noctel-now chart from k3s-config → noctel-gitops
2. ✅ Copy infrastructure charts
3. ✅ Expand pdx2-prod-config.yaml
4. ✅ Create prod ArgoCD applications
5. ⏭️ Create pdx1 environment configs
6. ⏭️ Test deploy on pdx1

**Ready to proceed?** Should I start copying the charts?
